# Running the install script

[← How to use me](../../HOW-TO-USE-ME.md) · Step-by-step internals: [The install script](../learn/03-install-script-walkthrough.md)

[`install_clustercontrol_kubeadm-cc-helm-dev.sh`](install_clustercontrol_kubeadm-cc-helm-dev.sh)
turns **one fresh Ubuntu 24.04 machine** into a single-node Kubernetes cluster and installs
ClusterControl on it with this repository's Helm chart. It doesn't care where the machine runs: a
cloud VM (AWS, GCP, DigitalOcean, Hetzner…), a private-cloud VM (OpenStack, Proxmox, VMware…),
bare metal, or a local VM.

This page covers how to run it. [Page 3 of the learning guide](../learn/03-install-script-walkthrough.md)
explains what each step does and why.

> **Tested on:** Ubuntu 24.04 LTS, on a KVM/libvirt VM built with Vagrant (`pupnode100` in the
> author's lab). Other places to run it differ only in networking and firewalls, which this page
> covers.
>
> **Ubuntu only, for now.** The script uses `apt`/`dpkg`, Ubuntu's `containerd` package and the
> `pkgs.k8s.io` Debian repository. It stops on anything other than Ubuntu 24.04. RHEL-family
> support (RHEL, Rocky, AlmaLinux, Oracle Linux) may come later; open an issue if you need it.

---

## 1. Prepare the machine

| | Minimum | Why |
|-|---------|-----|
| OS | Ubuntu 24.04 LTS, fresh install | see above |
| CPU / RAM | 4 vCPU / 8 GiB | cmon, MySQL InnoDB Cluster, VictoriaMetrics and NGINX Gateway Fabric all on one node |
| Root disk | **40 GB** | container images alone take several GB. Cloud defaults are often 8–20 GB, so raise it when you create the VM |
| Access | `root`, or a user with `sudo` | the script installs packages and changes kernel settings |
| Outbound | HTTPS to the internet | apt repos, `pkgs.k8s.io`, GitHub, `ghcr.io`, Docker Hub, `europe-docker.pkg.dev` |
| Inbound | TCP **443** (and 80) from wherever you will browse from | the ClusterControl UI |

Example sizes (check current names and prices with your provider):

| Provider | Image | Size that fits |
|----------|-------|----------------|
| AWS EC2 | Ubuntu Server 24.04 LTS | 4 vCPU / 8–16 GiB (e.g. `c6i.xlarge`, `m6i.xlarge`), gp3 root volume 40 GB+ |
| Google Cloud | `ubuntu-2404-lts` | `e2-standard-4`, boot disk 40 GB+ |
| DigitalOcean | Ubuntu 24.04 (LTS) x64 | 4 vCPU / 8 GB droplet |
| Hetzner Cloud | `ubuntu-24.04` | CPX31 or larger |
| Private cloud / bare metal | Ubuntu 24.04 server | as in the first table |
| Local | e.g. `multipass launch 24.04 --cpus 4 --memory 8G --disk 40G` | as in the first table |

**Use a dedicated machine.** The script turns swap off, loads kernel modules, changes sysctls and
installs a kubelet. Don't run it on your workstation or on a server that does other work.

## 2. Get the script

```bash
git clone https://github.com/severalnines/cc-helm-charts-nginx-gw-dev.git
cd cc-helm-charts-nginx-gw-dev
```

Or fetch just the one file:

```bash
curl -fsSLO https://raw.githubusercontent.com/severalnines/cc-helm-charts-nginx-gw-dev/main/docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh
```

Read it before you run it as root. It is long, but every section is commented.

## 3. Decide two things: the name and the address

### The key settings

`CC_FQDN`, `PRIVATE_IP`, `NODE_CIDR` and `LB_IP` decide how the node is named and addressed. Pass them as
environment variables (`sudo env CC_FQDN=… bash install_clustercontrol_kubeadm-cc-helm-dev.sh`).

| Setting | What it is | Do you need to set it? | Default | Reference lab | Example elsewhere |
|---------|-----------|------------------------|---------|---------------|-------------------|
| `CC_FQDN` | The hostname people type in the browser to reach ClusterControl. The Gateway only answers for this name, and the TLS certificate is issued for it | **Yes, in practice.** Pick a name, then point it at the node with a DNS A record or a hosts-file entry on each client. It requires to match your hostname with `CC_FQDN`, else won't work | the node's short hostname. | `pupnode100` | `cc.example.com` |
| `PRIVATE_IP` | The node's own IP address, on one of its network interfaces. Kubernetes, the pod network and MetalLB bind to it | **Usually no.** The script uses the address of the default route. Set it only if the machine has several NICs and you want a different one | detected | `192.168.40.100` | `10.0.1.23` (a cloud VM's private IP) |
| `NODE_CIDR` | The subnet addresses are carved from: MetalLB's pool is hosts `LB_POOL_FIRST`–`LB_POOL_LAST` (240–242) of it, and in lab mode the node is host `<index>` of it | **When the default clashes or you want the address on your LAN.** Set it to a subnet that is unused on your network (cloud VPC) or to the node's own subnet (flat LAN). Change this, never the script | `192.168.40.0/24` | `192.168.40.0/24` | `10.20.0.0/24` → `LB_IP=10.20.0.240` |
| `LB_IP` | A spare address MetalLB gives ClusterControl's front door (its LoadBalancer Service). It is the cluster's entry point for the UI, so no `kubectl port-forward` or NodePort is needed. Clients on the **same LAN/L2 network** can browse to it directly. It is a private address, though, and on a cloud VPC only the node can reach it — there you browse to the node's (public) IP, which the socat bridge forwards to `LB_IP` | **Only if the default clashes.** It must be unused on your network. Easiest: set `NODE_CIDR` to a subnet you control and the pool follows (hosts 240–242 of it) | first address of the pool: `192.168.40.240` (from `NODE_CIDR=192.168.40.0/24`) | `192.168.40.240` | `NODE_CIDR=10.20.0.0/24` → `10.20.0.240` |

Usually you set `CC_FQDN`, plus `NODE_CIDR` when `192.168.40.0/24` is used on your network or you
want ClusterControl's address on your own LAN. The sections below explain the name and the
LoadBalancer address in more detail.

### The name: `CC_FQDN`

The Gateway only answers for one hostname, and browsers must send that name in the TLS handshake
(SNI). A bare IP in the URL gets a TLS error instead of a page
([why](../learn/01-concepts.md#8-gateway-api-and-nginx-gateway-fabric)). Pick the name people will
type, for example `cc.example.com`. Then either:

* create a DNS **A record** for it pointing at the machine's public (or LAN) IP, or
* add it to the hosts file of each machine you browse from: `203.0.113.10 cc.example.com`.

If you don't set `CC_FQDN`, it defaults to the machine's short hostname.

### The LoadBalancer address: `LB_POOL` / `LB_IP`

kubeadm has no load balancer, so the script installs MetalLB and gives ClusterControl's front door
an address from `LB_POOL`, pinned to `LB_IP`.

**What `LB_IP` is for.** It is the `EXTERNAL-IP` of the gateway's LoadBalancer Service, the way into
ClusterControl from outside Kubernetes. Because of it you never need `kubectl port-forward` or a
NodePort to reach the UI. It is **not** a public internet address by itself: MetalLB only announces
it on the node's local network (ARP). So:

* on a **flat LAN** it is the address to browse to;
* on a **cloud VPC** it is reachable only from the node, and you browse to the node's IP (public or
  private) instead. The script's socat bridge passes the node's ports 80/443 on to `LB_IP`.

How you reach it depends on your network:

| Your network | Can other machines reach `LB_IP`? | What to set | Browse to |
|--------------|-----------------------------------|-------------|-----------|
| **Public cloud VPC** (AWS, GCP, DO, Hetzner, most private clouds with SDN) | No. The provider drops traffic for addresses it did not assign | any addresses **not used** anywhere in your VPC. The default (hosts 240–242 of `NODE_CIDR=192.168.40.0/24`) is fine unless your VPC uses that subnet | the node's own IP, port 443. The script's socat bridge forwards it to `LB_IP` |
| **Flat LAN / bare metal / KVM bridge** (the reference lab) | Yes. MetalLB answers ARP on the LAN | `NODE_CIDR` = the node's subnet; `LB_POOL_FIRST`/`LB_POOL_LAST` = free host numbers **outside the DHCP range** | `LB_IP` directly, or the node IP |

Either way the script always runs the socat bridge (`cc-bridge-443` and `cc-bridge-80`), so
**the node's own address on port 443 always works**. That is the simplest thing to point DNS at.

## 4. Run it

The run takes 15–45 minutes, mostly image pulls. Use `tmux` or `screen` so a dropped SSH session
doesn't kill it, and keep a log:

```bash
sudo env CC_FQDN=cc.example.com \
  bash docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh 2>&1 | tee ~/cc-install.log
```

The script must run as **root**. `sudo env VAR=… bash script` is the reliable way to pass settings
through `sudo`. From a root shell (`sudo -i`), `export VAR=…` and then `bash script` works too.
Don't `source` the script: it would run inside your own shell, and its `set -e`/`exit` would close
that shell. And don't `export` as a normal user and then run plain `sudo bash`, because `sudo` drops
exported variables.

### Examples

```bash
# AWS / GCP / DigitalOcean / Hetzner: defaults are fine, just name it
$ sudo env CC_FQDN=cc.example.com bash install_clustercontrol_kubeadm-cc-helm-dev.sh

# The VPC already uses 192.168.40.0/24: carve the MetalLB pool from an unused subnet. 
$ sudo env CC_FQDN=cc.example.com NODE_CIDR=172.31.255.0/24 \
$ bash install_clustercontrol_kubeadm-cc-helm-dev.sh          # pool 172.31.255.240-242

# Bare metal on 10.0.0.0/24, DHCP hands out .100-.199 and .240+ is taken: pick other free hosts
sudo env CC_FQDN=cc.lan NODE_CIDR=10.0.0.0/24 LB_POOL_FIRST=210 LB_POOL_LAST=212 \
  bash install_clustercontrol_kubeadm-cc-helm-dev.sh          # pool 10.0.0.210-212

# Addresses that don't follow a pattern: give the pool outright
sudo env CC_FQDN=cc.example.com LB_POOL=172.31.255.240-172.31.255.241 \
  bash install_clustercontrol_kubeadm-cc-helm-dev.sh

# Machine with two NICs: say which address Kubernetes should use
# script has method to determine which your IP sits and what network device
# id uses
sudo env CC_FQDN=cc.example.com PRIVATE_IP=10.10.0.5 bash install_clustercontrol_kubeadm-cc-helm-dev.sh

# Give ClusterControl an SSH key for the database hosts it will manage
sudo env CC_FQDN=cc.example.com CC_SSH_KEY=/home/ubuntu/.ssh/cc_db_key \
  bash install_clustercontrol_kubeadm-cc-helm-dev.sh

# The reference lab: Vagrant passes an index (see "Lab mode" below)
install_clustercontrol_kubeadm-cc-helm-dev.sh 100
```

### Settings

Every setting is an environment variable with a default. Set only what you need.

**Identity and access**

| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_FQDN` | short hostname | the name users browse to; Gateway hostname and TLS certificate name |
| `PRIVATE_IP` | address of the default route | the address Kubernetes, flannel and MetalLB bind to. Must exist on a local interface |
| `NODE_NAME` | short hostname, lowercased | the Kubernetes node name |
| `KUBE_USER` | the user who ran `sudo` | also gets a `~/.kube/config` (`root` always does). Have not tested with non-root user, please give it a try |
| `CC_SSH_KEY` | `~KUBE_USER/.ssh/id_rsa` | private key put into Secret `my-ssh-keys` and mounted into cmon. Skipped if missing |
| `CC_SSH_SECRET` | `my-ssh-keys` | name of that Secret |

**Load balancer**

| Variable | Default | Meaning |
|----------|---------|---------|
| `NODE_CIDR` | `192.168.40.0/24` | subnet the pool (and, in lab mode, the node address) is carved from. Change this, not the script, to use another network |
| `LB_POOL_FIRST` / `LB_POOL_LAST` | `240` / `242` | host numbers within `NODE_CIDR` that form the pool |
| `LB_POOL` | hosts 240–242 of `NODE_CIDR` (`192.168.40.240-192.168.40.242`) | addresses MetalLB may hand out. Setting it overrides the three above |
| `LB_IP` | first address of `LB_POOL` | the one pinned to ClusterControl, and what the socat bridge forwards to |
| `METALLB_VERSION` | `v0.14.9` | |

**Chart**

| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_CHART_REF` | `s9s-ngf/clustercontrol` | repo chart, or a local path such as `charts/clustercontrol` |
| `CC_CHART_VERSION` | *(latest published)* | pin a chart version, e.g. `0.1.2` |
| `CC_RELEASE` | `clustercontrol` | Helm release name |
| `CC_BACKEND_TLS` | `1` | gateway → cmon TLS. Leave on, or `/` returns 400 |
| `NGF_VERSION` | `2.6.8` | NGINX Gateway Fabric version for the Gateway API CRDs |
| `CC_NGF_IMAGE_SOURCE` | `auto` | `auto` / `mirror` / `ghcr`: where NGF images come from |

**Waiting**

| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_READY_TIMEOUT` | `2700` | seconds to wait for all pods (45 min) |
| `CC_IMAGE_GRACE` | `300` | give up after this long in `ImagePullBackOff` |

**Maintainers only** (copying images into the Severalnines registry; users can ignore these):
`CC_MIRROR_TO_GAR` (`auto`/`1`/`0`), `CC_GAR_TOKEN`, `CC_MIRROR_SCRIPT`.

**Escape hatch:** `CC_ALLOW_UNTESTED_OS=1` lets the script run on an apt-based OS other than
Ubuntu 24.04. You are on your own there.

Fixed in the script, so edit it to change them: `K8S_MINOR` (`v1.33`), `POD_CIDR` (`10.244.0.0/16`),
namespace `clustercontrol`.

## 5. Open the firewall

Allow inbound **TCP 443** (and **80**, which only redirects to HTTPS) from the addresses you will
browse from:

| Provider | Where |
|----------|-------|
| AWS | the instance's Security Group, inbound rules |
| Google Cloud | VPC firewall rule targeting the VM (network tag) |
| DigitalOcean | Cloud Firewall attached to the droplet |
| Hetzner | Cloud Firewall attached to the server |
| Private cloud | security group or perimeter firewall |
| On the host | `sudo ufw allow 443/tcp` if UFW is enabled (it is off on most cloud images) |

Do **not** open 6443 (Kubernetes API) to the internet. Use an SSH tunnel instead (see step 7).

## 6. When it finishes

The script checks itself before it prints the summary:

```text
==> verifying from inside the guest
   cc.example.com @ 192.168.40.240   -> 200
   cc.example.com @ 127.0.0.1        -> 200
   cc.example.com @ 10.0.1.23        -> 200
```

All three 200 means the cluster, MetalLB, the Gateway and the socat bridge all work. Then browse to
`https://<CC_FQDN>/`, accept the self-signed certificate, and **create the admin user** (there is no
preset password).

The browser warning comes from the chart's self-signed certificate. For a trusted certificate,
install cert-manager and set `cmon.gateway.ssl.clusterIssuer`
([Inside the chart](../learn/04-inside-the-chart.md#valuesyaml--the-inputs)).

## 7. Use kubectl and Helm

On the node, `root` and `KUBE_USER` are already set up:

```bash
kubectl get nodes -o wide
kubectl -n clustercontrol get pods -o wide
helm -n clustercontrol list
```

From your laptop, through an SSH tunnel (i.e. should be able to reach your Kubernetes VM environment):

```bash
scp <user>@<node>:.kube/config ~/.kube/cc.conf         # or: sudo cat /etc/kubernetes/admin.conf
sed -i.bak 's#server: https://.*:6443#server: https://127.0.0.1:6443#' ~/.kube/cc.conf
ssh -N -L 6443:127.0.0.1:6443 <user>@<node> &           # keep running
KUBECONFIG=~/.kube/cc.conf kubectl get nodes
```

`127.0.0.1` is in the API server's certificate, so the tunnel is trusted.

## 8. Re-run, upgrade, remove

* **Re-run** any time: every step checks whether it is already done. A release that is already
  `deployed` is left alone; a `failed` one is uninstalled and installed again.
* **Change values or upgrade the chart:** see [Day-2 operations](../learn/05-day-2-operations.md).
  The script doesn't upgrade an existing release.
* **Remove everything:** delete the VM. That is the clean option. To keep the machine:

  ```bash
  sudo systemctl disable --now cc-bridge-443 cc-bridge-80
  sudo rm /etc/systemd/system/cc-bridge-{443,80}.service
  sudo kubeadm reset -f
  sudo rm -rf /etc/cni/net.d /opt/local-path-provisioner ~/.kube /root/.kube
  ```

## Lab mode (Vagrant)

With an index as its first argument, the script uses the reference lab's conventions:
`PRIVATE_IP` = host `<index>` of `NODE_CIDR` (`192.168.40.100` for index 100 with the default
`NODE_CIDR`), `NODE_NAME=CC_FQDN=pupnode<index>`, kubeconfig for `vagrant`. A lab on another subnet
only needs `NODE_CIDR`, e.g. `NODE_CIDR=10.20.0.0/24` → node `10.20.0.100`, pool `10.20.0.240-242`.
That is how the author's `Vagrantfile` calls it:

```ruby
node.vm.provision :shell,
    path: "./install_clustercontrol_kubeadm-cc-helm-dev.sh",
    args: ["100"],
    env: { "CC_MIRROR_TO_GAR" => ENV.fetch("CC_MIRROR_TO_GAR", ""), … }
```

Any variable above still overrides the lab defaults.
[The reference lab](../learn/02-the-lab-vm.md) describes that setup in full.

## If it fails

The script prints `!!` lines and dumps pod state, events and conditions before it exits. Fix the
cause and run it again. [Troubleshooting](../learn/06-troubleshooting.md) maps symptoms to causes.
The usual suspects outside the lab:

* **Disk full**: the cloud default root disk was not raised to 40 GB.
* **Browser gets a TLS error**: you used an IP in the URL, or the name doesn't match `CC_FQDN`.
* **Times out from your laptop, works on the node**: the cloud firewall doesn't allow 443.
* **`ERROR: could not work out this node's address`**: no default route; set `PRIVATE_IP`.
