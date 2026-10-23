# 3. The install script, step by step

[← The reference lab](02-the-lab-vm.md) · Next: [Inside the chart →](04-inside-the-chart.md)

[`docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh`](../scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh)
runs as root on one Ubuntu 24.04 machine and takes it from "fresh Ubuntu" to "ClusterControl
answering on `https://<CC_FQDN>/`". [How to run it](../scripts/README.md) covers the options and
environments; this page explains what it does.

Read this page with the script open beside it. For every phase you get: **what** it does, **why**
it is needed, and a **check** you can run afterwards on the node to see the result for yourself.
Checks use the shell variables from [Concepts](01-concepts.md) (`CC_FQDN`, `NODE_IP`, `LB_IP`), and
example output shows the reference-lab values (`pupnode100`, `192.168.40.100`, `192.168.40.240`).

```text
  0  settings, OS check, node identity, NIC discovery
  1  host prep ─ swap off, kernel modules, sysctls, /etc/hosts
  2  packages ─ containerd, kubelet, kubeadm, kubectl (pinned)
  3  containerd config ─ systemd cgroups, pause image
  4  control plane ─ kubeadm init, kubeconfig
  5  CNI ─ flannel pinned to the node's NIC
  6  untaint & wait for Ready
  7  storage ─ local-path as default StorageClass
  8  MetalLB ─ pool LB_POOL (from NODE_CIDR), L2 on the node's NIC
  9  helm + chart repo + chart version + Gateway API CRDs
 10  (maintainers) seed the GAR image mirror
 11  namespace, ssh-key Secret, helm install
 12  wait for pods (hand-rolled, not helm --wait)
 13  backend TLS ─ build CA bundle, helm upgrade
 14  pin the LoadBalancer IP, socat bridges
 15  self-test & summary
```

Every line starting with `==>` in the output marks one of these steps; `!!` marks a problem.

---

## 0. Settings and NIC discovery

**OS check.** The script reads `/etc/os-release` and stops unless it is Ubuntu 24.04 — the only
tested system. Everything after uses `apt`/`dpkg`. (`CC_ALLOW_UNTESTED_OS=1` overrides it for other
apt-based systems, at your own risk. RHEL-family support may come later.)

**Settings.** The top of the script is a block of `VAR="${VAR:-default}"` lines. Each can be
overridden from the environment (`sudo env VAR=value bash …`; in the reference lab, through the
Vagrantfile's `env:` block). The full list is in [Running the install script](../scripts/README.md#settings);
the ones you are most likely to touch:

| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_FQDN` | short hostname | the name users browse to — Gateway hostname and TLS certificate name |
| `PRIVATE_IP` | address of the default route | the address Kubernetes binds to |
| `NODE_CIDR` | `192.168.40.0/24` | subnet the MetalLB pool (and, in lab mode, the node address) is carved from |
| `LB_POOL` / `LB_IP` | hosts 240–242 of `NODE_CIDR` / first of the pool | MetalLB pool and the address pinned to ClusterControl |
| `CC_CHART_REF` / `CC_CHART_VERSION` | `s9s-ngf/clustercontrol` / *latest* | which chart to install |
| `CC_SSH_KEY` | `~/.ssh/id_rsa` of the sudo user | key ClusterControl uses to reach database hosts |
| `NGF_VERSION` | `2.6.8` | NGINX Gateway Fabric version (for CRDs and the mirror check) |
| `CC_BACKEND_TLS` | `1` | re-encrypt gateway → cmon-master (needed; see step 13) |
| `CC_READY_TIMEOUT` | `2700` | seconds to wait for pods (45 min) |
| `K8S_MINOR` | `v1.33` | Kubernetes minor version; picks the apt repo. Not overridable — edit the script |

**Node identity.** Two modes:

* **Default** (no argument): `PRIVATE_IP` is the source address of the default route
  (`ip route get 1.1.1.1`), `NODE_NAME` the short hostname, `CC_FQDN` the node name unless set.
* **Lab mode** (an index argument, e.g. `… 100`, as the Vagrantfile does): `PRIVATE_IP` = host 100
  of `NODE_CIDR` (`192.168.40.100` by default),
  `NODE_NAME=CC_FQDN=pupnode100`.

Then it finds which interface holds `PRIVATE_IP` (`FLANNEL_IFACE`) and stops if none does. That one
interface name is reused for kubeadm, the kubelet, flannel and MetalLB.

**Check:** the first lines of output — `==> private network is on ens5 (10.0.1.23)`
(reference lab: `eth1 (192.168.40.100)`).

## 1. Host prep

| Action | Why |
|--------|-----|
| `swapoff -a`, comment swap out of `/etc/fstab` | the kubelet refuses to start with swap on |
| load `overlay`, `br_netfilter` (and persist in `/etc/modules-load.d/k8s.conf`) | container filesystems; let iptables see bridged pod traffic |
| `net.bridge.bridge-nf-call-iptables=1`, `ip_forward=1` | without them no CNI can pass traffic |
| add `PRIVATE_IP CC_FQDN` to `/etc/hosts` | the node must resolve the ClusterControl hostname to itself |

**Check:** `swapon --show` (empty), `lsmod | grep br_netfilter`, `sysctl net.ipv4.ip_forward`.

## 2. Packages

Installs `containerd` from Ubuntu, adds the official `pkgs.k8s.io` repo for `K8S_MINOR`, installs
`kubelet kubeadm kubectl`, and **holds** them (`apt-mark hold`). Kubernetes must be upgraded one
minor version at a time with `kubeadm upgrade`; an unattended `apt upgrade` skipping a version would
break the cluster.

kubeadm has no "latest" channel: if `K8S_MINOR` names a version that is not published, `apt-get
update` fails with a 404.

**Check:** `kubeadm version -o short`, `apt-mark showhold`.

## 3. containerd configuration

Ubuntu's shipped `/etc/containerd/config.toml` is a stub. The script generates the full default,
switches `SystemdCgroup = true` (to match the kubelet), and sets the `sandbox_image` (the "pause"
container every pod starts with) to the one this kubeadm expects. It only does this once — the
`grep` for `SystemdCgroup = true` is the idempotency guard.

**Check:** `grep -n 'SystemdCgroup\|sandbox_image' /etc/containerd/config.toml`.

## 4. Control plane: `kubeadm init`

Writes `/tmp/kubeadm-config.yaml` and runs `kubeadm init --config` with it — but only if
`/etc/kubernetes/admin.conf` does not exist yet:

```yaml
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.0.1.23          # PRIVATE_IP: API server on the chosen NIC
nodeRegistration:
  name: ip-10-0-1-23                   # NODE_NAME
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs: [{name: node-ip, value: 10.0.1.23}]
---
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16             # must equal flannel's
apiServer:
  certSANs: [NODE_NAME, CC_FQDN, 127.0.0.1, localhost]   # 127.0.0.1: kubectl over an SSH tunnel is trusted
  extraArgs: [{name: event-ttl, value: 24h}]     # keep events a day, for troubleshooting
```

`kubeadm init` pulls the control-plane images, creates certificates under `/etc/kubernetes/pki`,
writes static-pod manifests to `/etc/kubernetes/manifests` (the kubelet runs those directly — that
is how the API server starts before there is an API server), and bootstraps etcd.

The script then copies `admin.conf` to `~/.kube/config` of `KUBE_USER` (the user who ran `sudo`;
`vagrant` in the reference lab), exports `KUBECONFIG` in that user's and root's `.bashrc`, and waits
for `/readyz`.

**Check:** `ls /etc/kubernetes/manifests`, `kubectl get --raw /readyz`, `kubectl get nodes -o wide`
(INTERNAL-IP must be `PRIVATE_IP`).

## 5. CNI: flannel

Downloads the latest `kube-flannel.yml`, inserts `--iface=<FLANNEL_IFACE>` after `--kube-subnet-mgr`,
replaces the pod CIDR, and applies it. Skipped if the `kube-flannel-ds` DaemonSet already exists.

**Check:** `kubectl -n kube-flannel get pods`, `kubectl -n kube-flannel logs ds/kube-flannel-ds | grep -i 'using interface'`.

## 6. Untaint and wait for Ready

Removes `node-role.kubernetes.io/control-plane` from the node so ordinary pods may run on it, then
`kubectl wait --for=condition=Ready node --all`.

**Check:** `kubectl get nodes` → `Ready`; `kubectl -n kube-system get pods` → CoreDNS `Running`.

## 7. Storage: local-path

Applies local-path-provisioner `v0.0.31`, waits for its rollout, then **patches** the `local-path`
StorageClass with `storageclass.kubernetes.io/is-default-class: "true"` (the upstream manifest does
not). The chart's PVCs name no StorageClass, so without a default they — and cmon — stay `Pending`.

**Check:** `kubectl get sc` shows `local-path (default)`.

## 8. MetalLB

1. Applies the `metallb-native.yaml` manifest (once).
2. Waits for the controller *and* its webhook to be serving — the pool in step 4 is rejected until
   then.
3. **Removes** `node.kubernetes.io/exclude-from-external-load-balancers` from the node, otherwise
   MetalLB assigns the IP but never announces it ([Concepts §7](01-concepts.md#7-services-loadbalancers-and-metallb)).
4. Applies an `IPAddressPool` (`lab-pool`, `LB_POOL`) and an `L2Advertisement` restricted to
   `FLANNEL_IFACE`, so it never answers ARP on any other network. On a cloud VPC nothing outside the
   node will see those ARP replies — step 14's bridge is what makes ClusterControl reachable there.

**Check:** `kubectl -n metallb-system get pods,ipaddresspool,l2advertisement`,
`kubectl get nodes --show-labels | tr ',' '\n' | grep exclude` (no output).

## 9. Helm, the chart repo, and Gateway API CRDs

* Installs Helm 3 with the upstream `get-helm-3` script if it is missing.
* `helm repo add s9s-ngf https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/` and
  `helm repo update` — this is where `s9s-ngf/clustercontrol` comes from. If `CC_CHART_VERSION`
  is empty, it is set to the newest published version (`helm show chart … --devel`) so the install
  and the later upgrade use the same one. The repository is GitHub
  Pages, filled by [.github/workflows/release.yaml](../../.github/workflows/release.yaml) every time
  a `Chart.yaml` version changes on `main`.
* Applies the **experimental-channel** Gateway API CRDs from NGF's repo at tag `v${NGF_VERSION}`
  (`kubectl kustomize … | kubectl apply --server-side`). The chart cannot ship them: they are
  cluster-wide, and Helm never upgrades CRDs anyway. Experimental is required because the
  chart uses `TCPRoute` for kuber-proxy's gRPC port.

**Check:** `helm repo list`, `helm search repo s9s-ngf --devel --versions`,
`kubectl get crd | grep gateway.networking.k8s.io`.

## 10. (Maintainers) seed the image mirror — `cc_mirror_to_gar`

This is a **maintainer** convenience; a learner can ignore it. With `CC_MIRROR_TO_GAR=auto` (the
default) it first asks GAR whether `nginx-gateway-fabric:${NGF_VERSION}` is already mirrored
(`cc_gar_has_image`, an anonymous request for the image manifest; HTTP 200 means present). If it is, nothing happens. If
it is not, and a token is available, it installs `crane` and `yq` v4, logs in, and runs
[scripts/mirror-to-gar.sh](../../scripts/mirror-to-gar.sh). Any failure in `auto` mode only prints a
warning — the install continues from `ghcr.io`.

`CC_MIRROR_TO_GAR=0` skips it entirely; `=1` makes failure fatal.

> `CC_GAR_TOKEN` defaults to empty. Without a token (exported by you, or in the reference lab
> minted by the Vagrantfile from `gcloud`), `auto` simply skips seeding.

## 11. Namespace, SSH key, and `helm install`

* Creates namespace `clustercontrol`. Not just tidiness: the bundled MySQL operator refuses to run in
  `default`.
* Creates Secret `my-ssh-keys` from `CC_SSH_KEY` (default `~/.ssh/id_rsa` of the sudo user) — the key ClusterControl would use
  to SSH into the database VMs it manages — and, when that Secret exists, passes
  `--set cmon.sshKeysSecretName=my-ssh-keys` so the chart mounts it at `/root/.ssh-keys-user/key1`.
  (Override the name with `CC_SSH_SECRET`.)
* Looks at the existing release: `deployed` → skip; any other state (`failed`, `pending-install`…) →
  `helm uninstall` and start over.
* Chooses NGF image repositories according to `CC_NGF_IMAGE_SOURCE` (`auto` falls back to `ghcr.io`
  if the mirror lacks the tag; both the control-plane *and* data-plane image must be overridden
  together).
* Runs, in effect:

```bash
helm install clustercontrol s9s-ngf/clustercontrol \
  --namespace clustercontrol \
  --devel \
  --version <CC_CHART_VERSION> \
  --set fqdn=<CC_FQDN> \
  --set cmon.sshKeysSecretName=my-ssh-keys \
  [--set nginx-gateway-fabric.nginxGateway.image.repository=…  \
   --set nginx-gateway-fabric.nginx.image.repository=…]       \
  --timeout 15m
```

Reading that command as a learner:

| Flag | Meaning |
|------|---------|
| `clustercontrol` | the **release** name; also the prefix of many object names |
| `s9s-ngf/clustercontrol` | `<repo alias>/<chart name>` |
| `--devel` | allow pre-release chart versions (e.g. `0.1.2-rc1`) |
| `--version …` | pin the chart version (step 9 resolved it), so install and upgrade agree |
| `--set fqdn=…` | the single most important value: Gateway hostname, TLS cert name |
| `--set cmon.sshKeysSecretName=…` | mount your SSH key Secret into cmon (only added if the Secret exists) |
| `--timeout 15m` | applies to the chart's install hooks (NGF's cert-generator Job) |
| *no* `--wait` | deliberate — see step 12 |

On failure it calls `cc_dump_state` (pods, workloads, last 30 events, conditions of unready pods)
and exits.

**Check:** `helm -n clustercontrol list`, `helm -n clustercontrol get values clustercontrol`.

## 12. Waiting for pods — `cc_wait_for_pods`

`helm install --wait` treats a `LoadBalancer` Service as not ready until it has an external IP. The
script installs without `--wait` and polls instead, the same way you would by eye with
`kubectl -n clustercontrol get pods`:

* a pod is "up" when STATUS is `Running` and READY is `n/n` (completed Jobs also pass);
* pods whose names start with `clustercontrol-` and `cmon-master` **must exist** — the MySQL
  operator creates some of them *after* Helm returns, so "all present pods are ready" can be briefly,
  wrongly true;
* all of that must hold for **3 polls in a row** (10 s apart);
* if any pod is stuck in `ImagePullBackOff`/`ErrImagePull` for 5 minutes, give up early — it will
  not fix itself;
* otherwise give up after 45 minutes. It logs only when the picture changes.

**Check:** `kubectl -n clustercontrol get pods -w` while it runs.

## 13. Backend TLS — `cc_enable_backend_tls`

cmon's API (`9501`) and ccmgr, the UI server (`19051`), only speak **TLS**. If the gateway sends
them plain HTTP, `/` returns *400 Client sent an HTTP request to an HTTPS server*. The Gateway API
way to make the gateway use TLS towards a backend is a **BackendTLSPolicy**, and it *always*
verifies the backend's certificate — there is no "skip verify". So the gateway needs a CA bundle
that trusts both certificates:

1. **ccmgr's** certificate is issued by the chart (Secret `clustercontrol-ccmgr-tls`) — read it from
   there.
2. **cmon's** certificate is generated by cmon itself at startup, so it can only be read off the
   live port: `openssl s_client -connect <cmon-master ClusterIP>:9501`.
3. Concatenate both into ConfigMap `cmon-backend-ca`, key `ca.crt` (name mandated by the spec).
4. `helm upgrade --reuse-values --no-hooks --set cmon.gateway.backendTLS.enabled=true
   --set cmon.gateway.backendTLS.caCertificateRef=cmon-backend-ca`.

`--no-hooks` dodges an NGF quirk: its cert-generator RBAC is a `pre-install`-only hook, so an
upgrade's cert-generator Job would hang without a ServiceAccount. If the upgrade fails, the
ConfigMap is deleted so the next provision retries. The existence of the ConfigMap is the
idempotency marker — to refresh after cmon-master is recreated:

```bash
kubectl -n clustercontrol delete cm cmon-backend-ca
sudo bash install_clustercontrol_kubeadm-cc-helm-dev.sh   # same settings as before (lab: vagrant provision)
```

**Check:** `kubectl -n clustercontrol get backendtlspolicy`, `helm -n clustercontrol history clustercontrol`
(revision 2 is this upgrade).

## 14. Pin the address, bridge the ports

* Finds the data-plane Service `clustercontrol-gateway-nginx` (or, if renamed, the only
  `LoadBalancer` in the namespace) and annotates it
  `metallb.universe.tf/loadBalancerIPs=<LB_IP>`, so the address survives uninstall/reinstall.
* Installs `socat` and two systemd units, `cc-bridge-443` and `cc-bridge-80`, each running
  `socat TCP4-LISTEN:<port>,bind=0.0.0.0,fork,reuseaddr TCP4:<LB_IP>:<port>`.
  This is what makes **the node's own address** (private, public, or `127.0.0.1`) serve
  ClusterControl. On a cloud VPC it is the *only* way in, because `LB_IP` is not routable outside
  the node. In the reference lab it is also what Vagrant's forwarded ports connect to
  ([details](02-the-lab-vm.md#forwarded-ports)).

**Check:** `kubectl -n clustercontrol get svc clustercontrol-gateway-nginx -o wide`,
`systemctl status cc-bridge-443`, `ss -ltnp | grep -E ':(80|443) '`.

## 15. Self-test and summary

Probes `https://<CC_FQDN>/` three ways, always **by name** with `curl --resolve` (a bare IP sends
no SNI and fails the TLS handshake):

```text
   pupnode100 @ 192.168.40.240   -> 200     MetalLB + Service + Gateway work      (@ LB_IP)
   pupnode100 @ 127.0.0.1        -> 200     socat bridge works on loopback
   pupnode100 @ 192.168.40.100   -> 200     socat bridge on the node address works (@ PRIVATE_IP)
```

If the first fails, the problem is MetalLB/Service/Gateway. If only the last two fail, it is the
bridge. Then the banner prints how to reach the UI.

---

## Try it

1. Re-run the script (reference lab: `vagrant provision pupnode100`) and match each `==> …already…, skipping` line to the guard
   that produced it.
2. `kubectl -n clustercontrol delete cm cmon-backend-ca`, then
   `curl -k --resolve "$CC_FQDN:443:$LB_IP" "https://$CC_FQDN/"` and
   `kubectl -n clustercontrol describe backendtlspolicy` — what changed, and what do the policy's
   conditions say? Re-provision and watch step 13 put it back.
3. Explain, in one sentence each, why removing any one of these would break the install:
   the `exclude-from-external-load-balancers` label removal, the `--iface` flannel patch, the
   default-StorageClass patch, the experimental Gateway API channel.

[← The reference lab](02-the-lab-vm.md) · Next: [Inside the chart →](04-inside-the-chart.md)
