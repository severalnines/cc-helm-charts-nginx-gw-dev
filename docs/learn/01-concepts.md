# 1. Concepts

[← How to use me](../../HOW-TO-USE-ME.md) · Next: [The reference lab →](02-the-lab-vm.md)

This page builds the vocabulary for everything else. Each section explains one idea, then shows
where it lives on your node so you can look at the real thing. Every command on this page runs on
the node where the [install script](../scripts/README.md) ran:

```bash
ssh <user>@<your-node>          # reference lab: vagrant ssh pupnode100

# set once per shell: your values (reference-lab values in the comments)
CC_FQDN=cc.example.com          # pupnode100      - the name you browse to
NODE_IP=10.0.1.23               # 192.168.40.100  - PRIVATE_IP, the node's address
LB_IP=192.168.40.240            # 192.168.40.240  - ClusterControl's entry point (MetalLB address)
```

---

## 1. Containers and containerd

A **container image** is a packaged filesystem plus a start command (for example
`severalnines/cmon:2.4.0-20548`). A **container** is a running instance of an image, isolated from
the rest of the machine by Linux kernel features (namespaces and cgroups).

**containerd** is the program that pulls images and starts containers. Docker uses it under the
hood; Kubernetes talks to it directly through the *Container Runtime Interface* (CRI).

On your node:

```bash
systemctl status containerd
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps   # containers Kubernetes started
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock images
```

> **cgroup driver.** Both containerd and the kubelet manage cgroups (CPU/memory limits). They must
> agree on *how* — the script sets `SystemdCgroup = true` in `/etc/containerd/config.toml` so both
> use systemd. If they disagree, pods start and then die in confusing ways.

## 2. Kubernetes in one paragraph

Kubernetes is a **desired-state engine**. You hand it YAML describing what you want ("three copies
of this container, with this disk, reachable on this port"); controllers continuously compare that
with reality and act to close the gap. You never "start a container" — you declare an object and
something else makes it true.

The parts, all present on our single node:

| Component | What it does | On your node |
|-----------|--------------|-----------------|
| **kube-apiserver** | the only front door; stores objects in etcd | `kubectl -n kube-system get pod -l component=kube-apiserver` |
| **etcd** | the database holding every object | `…-l component=etcd` |
| **controller-manager / scheduler** | reconcile objects; pick a node for each pod | `…-l component=kube-scheduler` |
| **kubelet** | agent on each node; asks containerd to run the pods assigned to it | `systemctl status kubelet` |
| **kube-proxy** | programs iptables so Service IPs reach pods | `kubectl -n kube-system get ds kube-proxy` |
| **CoreDNS** | in-cluster DNS (`cmon-master.clustercontrol.svc`) | `kubectl -n kube-system get deploy coredns` |

`kubectl` is the command-line client for the API server. Its credentials are in a *kubeconfig*
file — `/etc/kubernetes/admin.conf` for root, `~/.kube/config` for the user who ran the
script with `sudo` (`vagrant` in the reference lab).

## 3. The objects you will meet

| Object | Think of it as | ClusterControl example |
|--------|---------------|------------------------|
| **Namespace** | a folder for objects | `clustercontrol`, `metallb-system`, `kube-flannel` |
| **Pod** | one or more containers that share a network address and volumes | `cmon-master-0` holds cmon, ccmgr, cmon-sd, the exporter, cmon-ssh and kuber-proxy |
| **Deployment** | "keep N identical pods running" (stateless) | the NGF controller, the MySQL operator |
| **StatefulSet** | like a Deployment, but pods have stable names and their own disks | `cmon-master` (→ `cmon-master-0`) |
| **DaemonSet** | "one pod on every node" | flannel, kube-proxy, MetalLB speaker |
| **Job** | run to completion once | NGF's cert-generator |
| **Service** | a stable virtual IP + DNS name in front of a set of pods | `cmon-master` (ports 9501, 19051, 9511, 50051 …) |
| **Secret / ConfigMap** | configuration, mounted as files or env vars | `cmon-cnf`, `cmon-credentials`, `config-js` |
| **PersistentVolumeClaim (PVC)** | "I need N GiB of disk" | `cmon-var-lib-cmon`, `cmon-ccmgr-volume` |
| **CustomResourceDefinition (CRD)** | teaches the API server a new object type | `Gateway`, `HTTPRoute`, `IPAddressPool`, `InnoDBCluster` |
| **Operator** | a controller that manages a CRD | the MySQL operator turns an `InnoDBCluster` into MySQL pods |

```bash
kubectl api-resources | less          # every object type this cluster knows
kubectl -n clustercontrol get all
kubectl explain statefulset.spec      # built-in documentation for any field
```

## 4. kubeadm — building a cluster by hand

There are many ways to get a Kubernetes cluster. Managed clouds (EKS, GKE, AKS) hand you one;
**k3s** is a single binary that bundles everything; **kubeadm** is the upstream, "some assembly
required" tool. It bootstraps the control plane and nothing else — no network, no storage, no load
balancer.

The install script uses kubeadm *on purpose*: every gap it leaves is a concept you have to install and
therefore understand. The script's header says it directly — everything between "HOST PREP" and
"STORAGE" is work k3s would have done for you implicitly.

```text
  what you install           what it gives you              script section
  ────────────────           ─────────────────              ──────────────
  containerd                 runs containers                PACKAGES
  kubeadm/kubelet/kubectl    control plane + node agent     CONTROL PLANE
  flannel                    pod-to-pod network             CNI
  local-path-provisioner     disks for PVCs                 STORAGE
  MetalLB                    external IPs for Services      METALLB
  helm                       package manager                helm
  Gateway API CRDs           routing vocabulary             helm (CRD step)
```

The control-plane configuration kubeadm used is still on disk:

```bash
cat /tmp/kubeadm-config.yaml        # exists until the VM reboots (/tmp)
kubectl -n kube-system get cm kubeadm-config -o yaml   # the permanent copy
```

**Taints.** kubeadm marks control-plane nodes "do not schedule ordinary pods here". On a one-node
cluster that means *nothing* would ever run, so the script removes the taint:

```bash
kubectl describe nodes | grep -i taint     # Taints: <none>
```

## 5. Pod networking (CNI) and flannel

Every pod gets its own IP address, and every pod must be able to reach every other pod. Kubernetes
does not implement that itself; it calls a **CNI plugin**. Until one is installed the node stays
`NotReady` and CoreDNS sits in `Pending`.

**flannel** is the simplest CNI: it gives each node a slice of the pod range (`10.244.0.0/16`) and
tunnels traffic between nodes. The pod range must match in two places — kubeadm's `podSubnet` and
flannel's ConfigMap.

```bash
kubectl -n kube-flannel get ds,pods
kubectl get pods -A -o wide          # note the 10.244.x.x pod IPs
ip -br addr show flannel.1 cni0
```

> **Which network card?** Many machines have more than one NIC: a public and a private interface on
> a cloud VM, or in the reference lab `eth0` (vagrant-libvirt's management NAT) and `eth1`
> (`192.168.40.100`). Left alone, the API server, the kubelet and flannel would each pick the NIC with
> the default route — not always the one you want. The script pins all three to the interface
> holding `PRIVATE_IP`. Miss any one and you get a cluster that *looks* healthy but is unreachable.

## 6. Storage: PVCs, StorageClasses, local-path

A pod asks for disk with a **PersistentVolumeClaim**. A **StorageClass** describes *how* such
disks are made, and a **provisioner** watches for claims and creates matching **PersistentVolumes**.
If no StorageClass is marked *default*, a claim that names none sits in `Pending` forever — and so
does the pod that needs it.

kubeadm ships no provisioner. The script installs Rancher's **local-path-provisioner** (the same one
k3s bundles), which simply makes a directory on the node's disk, and marks it default.

```bash
kubectl get storageclass               # local-path (default)
kubectl -n clustercontrol get pvc      # all Bound
ls /opt/local-path-provisioner/        # the actual directories
```

Local-path disks live on one node and vanish with it — fine for learning, not for production.

## 7. Services, LoadBalancers and MetalLB

Pods come and go and change IP. A **Service** gives a stable address in front of them:

| Type | Reachable from | Address comes from |
|------|----------------|--------------------|
| `ClusterIP` | inside the cluster only | the Service CIDR (`10.96.0.0/12`) |
| `NodePort` | `<any node IP>:30000-32767` | a port opened on every node |
| `LoadBalancer` | outside, on its own IP | **an external implementation** — a cloud LB, or MetalLB |

`kube-proxy` makes these work by writing iptables rules; no process "listens" on a Service IP.

On kubeadm nothing fills in a LoadBalancer's external IP, so `kubectl get svc` would show
`EXTERNAL-IP <pending>` forever. **MetalLB** is the missing piece. In **L2 mode** it hands out an
address from a pool you own (`LB_POOL`, by default hosts 240–242 of `NODE_CIDR`) and its *speaker* answers ARP for that address on the node's
NIC, so anything on the same LAN can reach it.

For ClusterControl that address is `LB_IP`: the `EXTERNAL-IP` of the gateway's Service and the way
into the UI from outside the cluster. That is why you never need `kubectl port-forward` or a NodePort
here.

> **On a cloud VPC** (AWS, GCP, DigitalOcean, Hetzner…) the provider's network ignores ARP for
> addresses it did not assign, so `LB_IP` is reachable **only from the node itself**. That is enough:
> the script's socat bridge listens on the node's own ports 80/443 and forwards to `LB_IP`, so you
> browse to the node's address. On a flat LAN or bare metal (like the reference lab), `LB_IP` works
> from the whole subnet too.

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl -n clustercontrol get svc clustercontrol-gateway-nginx    # EXTERNAL-IP = $LB_IP
```

> **The trap that cost a day.** kubeadm labels control-plane nodes
> `node.kubernetes.io/exclude-from-external-load-balancers`, and MetalLB honours it. On a one-node
> cluster that means *no* node may announce: the Service still shows `LB_IP`, but nobody
> answers ARP for it, and nothing is logged. The script removes that label.

## 8. Gateway API and NGINX Gateway Fabric

Getting HTTP traffic from outside to the right Service used to be the job of an **Ingress**
resource plus an ingress controller (Ingress-NGINX). Ingress-NGINX is being retired, and its
successor model is the **Gateway API**, which splits the job by role:

```text
  GatewayClass  "nginx"                  which implementation (installed by the NGF chart)
       │
  Gateway       clustercontrol-gateway   listeners: :80 HTTP, :443 HTTPS, :50051 TCP
       │                                 for hostname CC_FQDN, TLS cert from Secret cmon-cert
       ├── HTTPRoute  …-http-redirect    :80 → 301 to https
       ├── HTTPRoute  …-ccmgr-route      /           → cmon-master:19051 (the UI)
       ├── HTTPRoute  …-cmon-route       /cmon/…     → cmon-master:9501  (cmon API)
       ├── HTTPRoute  …-cmon-ssh-route   /cmon-ssh/… → cmon-master:9511  (web SSH)
       └── TCPRoute   …-kuber-proxy-grpc-route :50051 → cmon-master:50051
  BackendTLSPolicy  re-encrypt gateway → cmon-master:19051/9501, verifying a CA
```

These kinds are **CRDs**, not built into Kubernetes, so they must be installed before the chart —
the script installs the *experimental* channel because `TCPRoute` only exists there.

**NGINX Gateway Fabric (NGF)** implements them. It has two halves:

* a **control plane** (`clustercontrol-nginx-gateway-fabric` Deployment) that watches Gateway API
  objects and writes nginx configuration;
* a **data plane** — an nginx pod plus a `LoadBalancer` Service that NGF creates *per Gateway*,
  named `<gateway>-<class>` → `clustercontrol-gateway-nginx`. This is the Service MetalLB gives
  `LB_IP`.

```bash
kubectl get gatewayclass
kubectl -n clustercontrol get gateway,httproute,tcproute,backendtlspolicy
kubectl -n clustercontrol describe gateway clustercontrol-gateway     # look at Listeners / Conditions
```

> **Why a bare IP fails.** Every listener is scoped to `hostname: <CC_FQDN>`. A TLS client sends
> the hostname it is connecting to as **SNI**. `https://<any IP>/` sends no SNI, nginx has no
> matching server, and answers TLS alert 112 (`unrecognized_name`) — curl exits 35 before any HTTP
> status exists. Always use the name: an `/etc/hosts` entry, or
> `curl -k --resolve "$CC_FQDN:443:$LB_IP" "https://$CC_FQDN/"`.

## 9. Helm

Installing ClusterControl by hand would mean applying dozens of YAML files in the right order,
with the hostname, passwords and image tags filled in consistently. **Helm** is the package manager
that does that.

| Helm word | Meaning | Here |
|-----------|---------|------|
| **chart** | a package: templates + default values + metadata | [charts/clustercontrol](../../charts/clustercontrol) |
| **values** | the inputs; defaults in `values.yaml`, overridden with `--set` or `-f` | `--set fqdn=cc.example.com` |
| **template** | Kubernetes YAML with `{{ .Values.… }}` placeholders | `templates/gateway.yaml` |
| **dependency / subchart** | another chart pulled in and installed with yours | mysql-operator, mysql-innodbcluster, victoria-metrics-single, nginx-gateway-fabric |
| **repository** | a web server with an `index.yaml` listing chart versions | `s9s-ngf` → `https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/` |
| **release** | one installed copy of a chart, with a name and a revision history | `clustercontrol` in namespace `clustercontrol` |
| **hook** | a resource Helm runs at a lifecycle point (pre-install, post-upgrade…) | NGF's cert-generator Job |

```text
  values.yaml ─┐
  --set …    ──┼─▶  helm renders templates  ─▶  plain YAML  ─▶  kubectl-style apply  ─▶  release rev N
  templates/ ──┘                                                       (stored as a Secret in the namespace)
```

```bash
helm -n clustercontrol list
helm -n clustercontrol history clustercontrol
helm -n clustercontrol get values clustercontrol         # only what you overrode
helm -n clustercontrol get values clustercontrol --all   # everything, defaults included
helm -n clustercontrol get manifest clustercontrol | less # the YAML Helm actually applied
```

Helm installs things; it does not keep them healthy. After `helm install` returns, Kubernetes
controllers and operators are still creating pods — which is why the script does its own waiting.

## 10. Where the images come from (GAR mirror)

Upstream projects occasionally delete old chart versions and image tags, which breaks installs
that pin them. Severalnines therefore copies third-party charts and images into **Google Artifact
Registry** (`europe-docker.pkg.dev/severalnines-public/clustercontrol/…`) with
[scripts/mirror-to-gar.sh](../../scripts/mirror-to-gar.sh). `Chart.yaml` points three of the four
dependencies at that mirror; `values.yaml` points the MySQL and VictoriaMetrics images there too.
NGF currently defaults to `ghcr.io` (the mirror line is commented out in `values.yaml`). Pulling from
the mirror needs no credentials; pushing to it does.

---

## Try it

1. `kubectl get pods -A -o wide` — sort the pods into "control plane", "networking", "storage",
   "load balancing" and "ClusterControl". Which namespace is each in?
2. `kubectl -n clustercontrol get pod cmon-master-0 -o jsonpath='{.spec.containers[*].name}'` —
   list the containers in the ClusterControl pod. Why do they share one pod?
3. `kubectl -n clustercontrol get svc` — find the one `LoadBalancer`. Which object created it?
   (Hint: it is not in `helm -n clustercontrol get manifest clustercontrol` — so who made it?
   Check `kubectl -n clustercontrol get svc clustercontrol-gateway-nginx --show-labels`.)
4. `curl -kv "https://$LB_IP/"` and then
   `curl -kv --resolve "$CC_FQDN:443:$LB_IP" "https://$CC_FQDN/"` — compare the TLS handshake.

[← How to use me](../../HOW-TO-USE-ME.md) · Next: [The reference lab →](02-the-lab-vm.md)
