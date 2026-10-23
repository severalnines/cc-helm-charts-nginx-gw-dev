# How to use me

![Helm: v3](https://img.shields.io/static/v1?label=Helm&message=v3&color=informational&logo=helm)

> **Unofficial, and meant for learning.** The supported ClusterControl charts live at
> [severalnines/helm-charts](https://github.com/severalnines/helm-charts). This repository is a
> development chart that swaps Ingress-NGINX for [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric)
> (Gateway API) — and, just as importantly, a sandbox for learning how ClusterControl actually runs on
> Kubernetes.

[README.md](README.md) tells you *what to type*. This guide and the pages under [docs/learn/](docs/learn/)
tell you *what happens when you type it*, and why each piece is there.

---

## Who this is for

You have been asked to deploy ClusterControl with Helm, and words like *kubeadm*, *CNI*,
*StorageClass*, *LoadBalancer*, *Gateway* or *helm release* are new or fuzzy. You learn best by
building something real, breaking it, and looking inside.

You do **not** need prior Kubernetes experience. You do need:

* a Linux environment: one Ubuntu 24.04 machine you can throw away. It can be a cloud VM (AWS, GCP,
  DigitalOcean, Hetzner…), a private-cloud VM, bare metal, or a local VM. During this development, I
  use a Linux KVM host with Vagrant and the `vagrant-libvirt` plugin (the reference lab described
  below);
* comfort with a shell, `ssh`, and reading a bash script.

## Prepping your target environment

This has been performed on a single node with Ubuntu 24.04 VM installed. I provision it using `Vagrantfile` with external invocation to provision the vm node with `install_clustercontrol_kubeadm-cc-helm-dev.sh`. One `vagrant up` takes a blank VM all the way to
a working ClusterControl UI.

**Vagrant is not required.** The same script lives in this repository as
[docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh](docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh),
and you can run it directly on any Ubuntu 24.04 machine. [docs/scripts/README.md](docs/scripts/README.md)
covers sizing, networking, firewalls and settings for each kind of environment.

| | |
|-|-|
| **Tested and working** | Ubuntu 24.04 LTS, single node, 4 vCPU / 8 GiB / 40 GB. Verified on the author's KVM + Vagrant lab |
| **Should work the same** | any Ubuntu 24.04 VM or server with those resources: cloud, private cloud, bare metal, local. Only the networking differs ([how](docs/scripts/README.md#3-decide-two-things-the-name-and-the-address)) |
| **Not supported yet** | non-Ubuntu systems. The script uses `apt`/`dpkg` and stops on anything else. RHEL-family support (RHEL, Rocky, AlmaLinux, Oracle Linux) may come later if there is interest; please open an issue |

What you end up with, wherever it runs:

```text
 your Ubuntu 24.04 machine   ≥4 vCPU · ≥8 GiB · ≥40 GB · PRIVATE_IP
 ├── containerd              runs containers
 ├── kubeadm / kubelet       turns the machine into a 1-node Kubernetes cluster (v1.33)
 ├── flannel                 pod network (10.244.0.0/16)
 ├── local-path-provisioner  disks for pods (default StorageClass)
 ├── MetalLB                 hands out LB_IP (from a pool in NODE_CIDR) to the LoadBalancer Service
 ├── Gateway API CRDs        the vocabulary NGINX Gateway Fabric speaks
 ├── helm release "clustercontrol"  (this repository's chart, namespace clustercontrol)
 │   ├── NGINX Gateway Fabric       front door: TLS, routing  (https://CC_FQDN)
 │   ├── cmon-master-0              cmon, ccmgr (UI), cmon-sd, exporter, cmon-ssh, kuber-proxy
 │   ├── MySQL operator + InnoDB    the cmon database
 │   └── VictoriaMetrics            metrics for the dashboards
 └── socat cc-bridge-80/443  makes the node's own :80/:443 reach LB_IP
```

`CC_FQDN`, `PRIVATE_IP`, `NODE_CIDR` and `LB_IP` are settings of the install script. What they mean
and what you need to set: [Running the install script → The key settings](docs/scripts/README.md#the-key-settings).

**`NODE_CIDR` is how you move off the reference lab's network.** It defaults to `192.168.40.0/24`
(the lab's subnet). The MetalLB address (`LB_IP`) is carved from it, and so is the node's own address
in lab mode. If `192.168.40.0/24` is already used on your network, or you want the address on your
own LAN, set `NODE_CIDR` to a subnet of yours (for example `NODE_CIDR=10.20.0.0/24` gives
`LB_IP=10.20.0.240`). Never edit `192.168.40` into or out of the script itself.

**`LB_IP` is ClusterControl's front door.** It is the external address of the gateway's
LoadBalancer Service, so you reach the UI without `kubectl port-forward` or NodePorts. On a flat LAN
(like the reference lab) you browse to `LB_IP` directly. It is a private address, though: on a cloud
VPC only the node can reach it, so you browse to the node's (public) IP and the socat bridge passes the
traffic on to `LB_IP`. [Details](docs/scripts/README.md#the-loadbalancer-address-lb_pool--lb_ip).

The examples in these pages use the reference-lab values (`pupnode100`, `192.168.40.100`,
`NODE_CIDR=192.168.40.0/24`, `192.168.40.240`); swap in your own.

Why a single node? Because every layer Kubernetes normally hides is then on one box you can `ssh`
into, and the install script installs each layer by hand — so you can read exactly what each one is.

## Quick start

Once your Ubuntu 24.04 machine is ready (cloud, private cloud, bare metal or local VM: see
[docs/scripts/README.md](docs/scripts/README.md) to raise the root disk to 40 GB, open TCP 443 and
pick a name), log in and get the script:

```bash
git clone https://github.com/severalnines/cc-helm-charts-nginx-gw-dev.git
cd cc-helm-charts-nginx-gw-dev
```

The script **must run as root**: it installs packages, turns swap off, changes kernel settings, runs
`kubeadm init` and creates systemd services. Run it with `bash`, passing your settings as
environment variables. `CC_FQDN` is the one you normally set; add `NODE_CIDR` only if
`192.168.40.0/24` is already used on your network ([what these mean](docs/scripts/README.md#the-key-settings)).

As a user with `sudo`:

```bash
sudo env CC_FQDN=cc.example.com bash docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh 2>&1 | tee ~/cc-install.log
```

Or from a root shell (`sudo -i`, or logging in as root as on Hetzner/DigitalOcean):

```bash
export CC_FQDN=cc.example.com
# export NODE_CIDR=10.20.0.0/24       # only if 192.168.40.0/24 is in use on your network
bash /path/to/cc-helm-charts-nginx-gw-dev/docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh 2>&1 | tee /root/cc-install.log
```

Two things that do **not** work:

* `source install_clustercontrol_kubeadm-cc-helm-dev.sh`. It runs inside your current shell, and the
  script's `set -e`/`exit` would close that shell. Always start it with `bash`.
* `export CC_FQDN=…` as a normal user followed by plain `sudo bash …`. `sudo` drops exported variables,
  so pass them with `sudo env CC_FQDN=… bash …` as shown above.

Use `tmux` or `screen` so a dropped SSH session does not stop it. The first run takes 15–45 minutes
(most of it is image pulls). Re-running is safe: the script is idempotent, so after a failure fix the
cause and run the same command again.

The author's tested setup runs this same script from a Vagrant provisioner; that is described in
[The reference lab](docs/learn/02-the-lab-vm.md) and is not needed to use the script.

When it finishes, the script prints a summary banner. Point the name (`CC_FQDN`) at the machine,
using DNS or a hosts-file entry on the machine you browse from:

```bash
echo '203.0.113.10 cc.example.com' | sudo tee -a /etc/hosts      # your node's address and name
```

then open `https://cc.example.com/` (accept the self-signed certificate) and create the admin user.
The **name matters**, not just the address —
[Concepts → Gateway API](docs/learn/01-concepts.md#8-gateway-api-and-nginx-gateway-fabric) explains
why a bare IP gets a TLS error instead of a page.

Look around on the node:

```bash
kubectl get nodes -o wide
kubectl -n clustercontrol get pods -o wide
helm -n clustercontrol list
```

## The learning path

Read in order the first time; afterwards each page stands alone.

| # | Page | You will learn |
|---|------|----------------|
| — | [Running the install script](docs/scripts/README.md) | how to run the script on your own machine: sizing, name, LoadBalancer address, firewall, settings |
| 1 | [Concepts](docs/learn/01-concepts.md) | containers, Kubernetes objects, kubeadm, CNI, storage, Services and LoadBalancers, Helm, Gateway API — each with a command to see it on your node |
| 2 | [The reference lab (Vagrant)](docs/learn/02-the-lab-vm.md) | *optional:* how the author's `Vagrantfile` builds the tested VM, and what each part means for other environments |
| 3 | [The install script, step by step](docs/learn/03-install-script-walkthrough.md) | every phase of `install_clustercontrol_kubeadm-cc-helm-dev.sh`, why it exists, and the command that proves it worked |
| 4 | [Inside the chart](docs/learn/04-inside-the-chart.md) | `Chart.yaml`, `values.yaml`, the templates, the dependencies, and how one HTTPS request travels from your browser to cmon |
| 5 | [Day-2 operations](docs/learn/05-day-2-operations.md) | inspect, upgrade, roll back, reinstall and tear down — with `helm` and `kubectl` |
| 6 | [Troubleshooting](docs/learn/06-troubleshooting.md) | symptom → cause → fix for every failure the script already knows about |

Each page ends with a short **Try it** section. Do them — the point is to break things on purpose
on a machine you can rebuild in half an hour.

## What lives in this repository

```text
.
├── README.md                    short install notes; points here for the learning guide
├── HOW-TO-USE-ME.md             you are here
├── docs/
│   ├── learn/                   the learning guide (pages 1–6)
│   └── scripts/
│       ├── README.md                                  how to run the install script anywhere
│       └── install_clustercontrol_kubeadm-cc-helm-dev.sh  bare Ubuntu 24.04 → Kubernetes → ClusterControl
├── charts/clustercontrol/       the Helm chart (published as s9s-ngf/clustercontrol)
│   ├── Chart.yaml               chart name, version, and its four dependency charts
│   ├── values.yaml              every knob you can turn with --set / -f
│   ├── templates/               Kubernetes YAML with Go-template placeholders
│   └── files/ssh-keys/          example keys baked into the "ssh-keys" Secret
├── scripts/
│   ├── install-clustercontrol.sh   install/upgrade on an EXISTING cluster (CRDs, RBAC, helm, backend TLS)
│   └── mirror-to-gar.sh            maintainer tool: copy third-party charts/images to GAR
└── .github/workflows/release.yaml  publishes the chart to the GitHub Pages helm repo
```

Which way to install depends on what you already have:

| You have… | Use | Docs |
|-----------|-----|------|
| a fresh Ubuntu 24.04 machine, anywhere | [docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh](docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh) (builds the cluster *and* installs the chart) | [docs/scripts/README.md](docs/scripts/README.md) |
| a KVM host with Vagrant | the same script, called by the `Vagrantfile` | [The reference lab](docs/learn/02-the-lab-vm.md) |
| an existing Kubernetes cluster (EKS, GKE, AKS, k3s, …) | [scripts/install-clustercontrol.sh](scripts/install-clustercontrol.sh) | [README.md](README.md), [chart README](charts/clustercontrol/README.md) |

The node script and `install-clustercontrol.sh` do the same Kubernetes-side work (Gateway API CRDs,
`helm install`, `fqdn`, backend CA bundle and backend TLS); the node script additionally builds the
cluster underneath.

## Known gaps in the install script

Reading the script against the chart turned up a few things worth knowing before you rely on them.
They are explained in context in the pages above; this is the short list of what is still open.
(Already fixed: the hard-coded GAR token default, the admin-password banner, the unused
`my-ssh-keys` Secret, and the leftover `ingress-nginx` flags.)

1. **`CC_NGF_IMAGE_SOURCE=mirror` does not force the mirror any more.** `values.yaml` now defaults
   the NGINX Gateway Fabric images to `ghcr.io`, and the `mirror` branch adds no `--set`, so it pulls
   from `ghcr.io` too. `auto` and `ghcr` behave as described.
2. **Only ports 80 and 443 are bridged to the node's own address.** kuber-proxy's gRPC port 50051 is
   reachable only at `LB_IP:50051`. That works on a flat LAN, but not from outside a cloud VPC. (In the
   reference lab this is also why the Vagrantfile's `50051 → 50100` forwarded port reaches nothing.)
3. **Ubuntu 24.04 only.** See [Prepping your target environment](#prepping-your-target-environment).
