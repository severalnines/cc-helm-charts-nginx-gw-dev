# 2. The reference lab (Vagrant)

[← Concepts](01-concepts.md) · Next: [The install script →](03-install-script-walkthrough.md)

> **Optional.** You don't need Vagrant. This page describes the environment the docs were
> **tested** on, so you can compare it with yours. To install anywhere else, follow
> [Running the install script](../scripts/README.md).

The tested environment is `pupnode100`: one entry in the author's `Vagrantfile`, which defines
`pupnode1` … `pupnode253` on a KVM host using the `vagrant-libvirt` provider. This page reads the
parts of that file that apply when `i == 100`, in the order Vagrant uses them.

### What each lab piece means for your environment

| In the reference lab | Elsewhere (cloud VM, private cloud, bare metal, local VM) |
|----------------------|-----------------------------------------------------------|
| box `cloud-image/ubuntu-24.04` | any Ubuntu 24.04 LTS image |
| 4 vCPU / 8 GiB / 40 GB, set in the Vagrantfile | the instance size and root disk you pick (40 GB+) |
| `192.168.40.100` on `eth1`, passed in as index `100` | `PRIVATE_IP` — detected from the default route, or set it |
| hostname `pupnode100` = `CC_FQDN` | set `CC_FQDN` to the name you browse to; add DNS or a hosts entry |
| MetalLB `192.168.40.240-242`, reachable from the whole `/24` | `NODE_CIDR` (+ `LB_POOL_FIRST`/`LAST`) or `LB_POOL`/`LB_IP` — on a cloud VPC reachable only from the node; browse via the node's address |
| Vagrant forwarded ports 80→4100, 443→41000 | none needed; open TCP 443/80 in your firewall or security group |
| Vagrant shell provisioner runs the script as root | you run `sudo env … bash install_clustercontrol_kubeadm-cc-helm-dev.sh` |
| `env:` block passes `CC_*` variables | `sudo env CC_…=… bash …` |
| `vagrant` user gets `~/.kube/config` | the user who ran `sudo` does |
| `vagrant provision pupnode100` to re-run | run the script again |
| `vagrant destroy` to start over | delete the VM / reinstall the OS |

---

## How Vagrant builds a VM, in one picture

```text
 vagrant up pupnode100
   │
   ├─ 1. download/clone the box  cloud-image/ubuntu-24.04 @ 20260323.0.0
   ├─ 2. create the libvirt domain (CPU, RAM, disk, NICs)
   ├─ 3. boot, wait for SSH, set hostname, configure 192.168.40.100 on eth1
   ├─ 4. mount the synced folder  /samsung_ssd/puppet  →  /vagrant  (virtiofs)
   ├─ 5. set up forwarded ports   (ssh tunnels)
   └─ 6. run provisioners, in order:
         a. global shell     grow the root disk to 40 GB
         b. shell            install_clustercontrol_kubeadm-cc-helm-dev.sh 100   ← the whole cluster
         c. shell            fix_repo_ubuntu-debian_packages.sh
         d. ansible_local    puppet.yml (or $PFILE)
```

`vagrant provision pupnode100` repeats step 6 only, on a VM that already exists. That is why the
install script is written to be **idempotent**: every step checks whether it is already done.

## The definition, explained

### Box and sizing

```ruby
node.vm.box         = "cloud-image/ubuntu-24.04"
node.vm.box_version = "20260323.0.0"

node.vm.provider "libvirt" do |lv|
  DEFAULT_LIBVIRT.call(lv)
  lv.memory = 8192               # 8 GiB
  lv.cpus = 4
  lv.machine_virtual_size = 40   # 20G default is too small for the CC chart
end
```

* The box is pinned to a version so a rebuild today gives the same OS as a rebuild next month.
* `DEFAULT_LIBVIRT` is shared by every VM: storage pool `samsung_ssd`, `virtio` NIC and disk,
  `host-passthrough` CPU, and **shared `memfd` memory** — required by the virtiofs synced folder.
* 8 GiB / 4 vCPU is the comfortable minimum for ClusterControl, MySQL InnoDB Cluster,
  VictoriaMetrics and NGF on one node. `pupnode101` runs the same script with 12 GiB / 6 vCPU.
* 40 GB because the images alone take several GB and the default 20 GB fills up. The global shell
  provisioner (`growpart`, `pvresize`, `lvextend`, `resize2fs`) grows the filesystem into the bigger
  disk on first boot.

### Network

```ruby
node.vm.network "private_network", ip: "192.168.40.100"   # i.e. 192.168.40.#{i}
```

The VM gets two NICs:

| NIC | Network | Address | Used for |
|-----|---------|---------|----------|
| `eth0` | vagrant-libvirt management NAT | DHCP | `vagrant ssh`, forwarded ports, internet |
| `eth1` | lab network `192.168.40.0/24` | `192.168.40.100` | Kubernetes, ClusterControl, the database VMs it manages |

Interface names can differ by box (`ens5`/`ens6` instead of `eth0`/`eth1`); the script never assumes
a name — it looks up whichever interface holds `192.168.40.100`.

The install script receives `100` as its first argument (lab mode) and derives the node's identity
from it and from `NODE_CIDR`, which defaults to this lab's subnet:

```bash
INDEX=${1:-}                        # 100
NODE_CIDR="${NODE_CIDR:-192.168.40.0/24}"
PRIVATE_IP=<host INDEX of NODE_CIDR>     # 192.168.40.100
NODE_NAME="pupnode${INDEX}"              # pupnode100
CC_FQDN="${CC_FQDN:-${NODE_NAME}}"       # pupnode100 — also the ClusterControl hostname
LB_POOL=<hosts 240-242 of NODE_CIDR>     # 192.168.40.240-192.168.40.242
```

A lab on another subnet needs only `NODE_CIDR`. Add it to the Vagrantfile's `env:` block, e.g.
`"NODE_CIDR" => "10.20.0.0/24"` together with `private_network ip: "10.20.0.#{i}"`.

`vagrant-hostmanager` (`manage_guest = true`) writes every pupnode's name into each guest's
`/etc/hosts`, so ClusterControl can reach other lab VMs by name.

> **Reserved addresses.** MetalLB hands out hosts 240–242 of `NODE_CIDR` (`192.168.40.240-242`) on the same `/24`. The loop in the
> Vagrantfile goes up to 253, so **never boot `pupnode240`, `pupnode241` or `pupnode242`** — they
> would collide with ClusterControl's LoadBalancer address.

### Forwarded ports

```ruby
if i == 100
  node.vm.network "forwarded_port", guest: 80,    host: 4100    # CC
  node.vm.network "forwarded_port", guest: 443,   host: 41000   # CC TLS/SSL
  node.vm.network "forwarded_port", guest: 6443,  host: 61000   # Kubernetes API server
  node.vm.network "forwarded_port", guest: 31155, host: 51000   # CC-OpsC Kuber-Proxy
  node.vm.network "forwarded_port", guest: 50051, host: 50100   # CC-OpsC Kuber-Proxy
end
```

With vagrant-libvirt a forwarded port is an **SSH tunnel that ends inside the guest and connects
to the guest's own `127.0.0.1:<guest port>`**. That detail drives a whole section of the install
script:

* ClusterControl's real address is the MetalLB IP `192.168.40.240`, which exists only in
  kube-proxy's iptables rules — nothing listens on the guest's `127.0.0.1:443`.
* So the script runs two small `socat` services (`cc-bridge-443`, `cc-bridge-80`) that listen on the
  node's `0.0.0.0:443/:80` and forward to `192.168.40.240`. Now the tunnel has something to connect to.
* Only 80 and 443 are bridged. `50051 → 50100` and `31155 → 51000` currently lead nowhere; use
  `192.168.40.240:50051` for kuber-proxy's gRPC port.
* `6443 → 61000` works because the API server *does* listen on all node addresses, and kubeadm put
  `127.0.0.1` in its certificate (`certSANs`).

The comment on the 6443 line in the Vagrantfile still says "k3s API server"; it is the kubeadm API
server now.

### Provisioners and the environment they receive

```ruby
node.vm.provision :shell,
    path: "./install_clustercontrol_kubeadm-cc-helm-dev.sh",
    args: ["100"],
    env: {
      "CC_GAR_TOKEN"        => CC_GAR_TOKEN,
      "CC_MIRROR_TO_GAR"    => ENV.fetch("CC_MIRROR_TO_GAR", ""),
      "CC_NGF_IMAGE_SOURCE" => ENV.fetch("CC_NGF_IMAGE_SOURCE", ""),
      "NGF_VERSION"         => ENV.fetch("NGF_VERSION", ""),
    }
node.vm.provision :shell, path: "./fix_repo_ubuntu-debian_packages.sh"
```

* `path:` is relative to the Vagrantfile. Vagrant uploads the script into the guest and runs it as
  **root**.
* `env:` is how settings cross from your KVM host shell into the script. Export a variable on the
  host and it reaches the script on the next `up`/`provision`:

  ```bash
  CC_NGF_IMAGE_SOURCE=ghcr vagrant provision pupnode100
  ```

  Unset host variables arrive as empty strings, and the script defaults every one of them with
  `${VAR:-default}`, so "not set" and "empty" mean the same thing.
* `CC_GAR_TOKEN` is computed at the top of the Vagrantfile: your exported `CC_GAR_TOKEN` if any;
  otherwise, only for `up`/`provision`/`reload` and only if `CC_MIRROR_TO_GAR` is not `0`, a token
  minted from the host's `gcloud auth print-access-token`; otherwise empty. It is only needed to
  **push** to the image mirror — installing never needs it.
* On `pupnode100` the package-repo fix runs **after** the install script; on `pupnode101` it runs
  before. If the install fails early on `apt-get`, that ordering is the first thing to check.
* Every pupnode also ends with an `ansible_local` run of `puppet.yml` (or `$PFILE`). It is not part
  of the Kubernetes install.

## Reaching ClusterControl

The Gateway only answers for the hostname `pupnode100`, so every option below sends that name.

| From | How | URL |
|------|-----|-----|
| the KVM host, or any machine on `192.168.40.0/24` | `echo '192.168.40.240 pupnode100' \| sudo tee -a /etc/hosts` | `https://pupnode100/` |
| the KVM host, through Vagrant's tunnel | `curl -k --resolve pupnode100:41000:127.0.0.1 https://pupnode100:41000/` | `https://pupnode100:41000/` |
| a laptop that can SSH to the KVM host | `ssh -L 8443:192.168.40.240:443 <kvm-host>`, and `127.0.0.1 pupnode100` in the laptop's hosts file | `https://pupnode100:8443/` |
| inside the VM | `curl -k --resolve pupnode100:443:192.168.40.240 https://pupnode100/` | — |

Prefer HTTPS URLs directly: the port-80 listener redirects to `https://pupnode100/` on port 443,
which drops any non-standard port you came in on.

## Using kubectl from the KVM host

```bash
vagrant ssh pupnode100 -c 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/pupnode100.conf
sed -i 's#server: https://.*:6443#server: https://127.0.0.1:61000#' ~/.kube/pupnode100.conf
KUBECONFIG=~/.kube/pupnode100.conf kubectl get nodes
```

`admin.conf` is cluster-admin. Keep it on the lab host.

## Lifecycle commands

```bash
vagrant up pupnode100           # create + provision (first time) / boot (afterwards)
vagrant provision pupnode100    # re-run the provisioners on a running VM
vagrant ssh pupnode100          # shell as the vagrant user (kubectl works, KUBECONFIG is set)
vagrant halt pupnode100         # shut down; cluster comes back on the next up
vagrant destroy -f pupnode100   # delete the VM and its disk — start over from nothing
```

---

## Try it

1. Inside the VM, run `ip -br addr` and find `eth0`, `eth1`, `flannel.1` and `cni0`. Which one owns
   `192.168.40.100`?
2. `systemctl cat cc-bridge-443` — read the socat unit. Stop it (`sudo systemctl stop cc-bridge-443`)
   and try the Vagrant-tunnel URL from the KVM host. Start it again.
3. On the host, `CC_MIRROR_TO_GAR=0 vagrant provision pupnode100` and watch the output: which steps
   say "already…, skipping"?

[← Concepts](01-concepts.md) · Next: [The install script →](03-install-script-walkthrough.md)
