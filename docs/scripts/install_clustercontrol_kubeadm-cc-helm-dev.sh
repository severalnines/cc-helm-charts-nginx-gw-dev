#!/bin/bash
#
# Single-node Kubernetes running ClusterControl via helm.
#
#   Ubuntu 24.04 host -> containerd -> kubeadm -> flannel -> local-path
#                     -> metallb -> helm -> s9s-ngf/clustercontrol
#
# This is the upstream-Kubernetes (kubeadm) equivalent of the k3s script.
# Everything between "HOST PREP" and "STORAGE" is work that k3s did for you
# implicitly; the ClusterControl half at the bottom is essentially unchanged.
#
# Runs as root on any Ubuntu 24.04 machine -- a cloud VM (AWS, GCP, DigitalOcean,
# Hetzner...), a private-cloud VM, bare metal, or a Vagrant guest. Idempotent:
# safe to re-run. See docs/scripts/README.md.
#
#   Anywhere:  sudo CC_FQDN=cc.example.com bash install_clustercontrol_kubeadm-cc-helm-dev.sh
#   Lab mode:  install_clustercontrol_kubeadm-cc-helm-dev.sh 100
#              (Vagrant provisioner; derives <NODE_CIDR host 100> / pupnode100 from the index)
#
# Addresses are not tied to 192.168.40.x: set NODE_CIDR (and, if needed,
# LB_POOL_FIRST/LB_POOL_LAST) for your own network, e.g.
#   sudo env NODE_CIDR=10.20.0.0/24 CC_FQDN=cc.example.com bash install_clustercontrol_kubeadm-cc-helm-dev.sh
#
set -euo pipefail
INDEX=${1:-}
CC_NAMESPACE="clustercontrol"

# Only Ubuntu 24.04 is tested: everything below uses apt/dpkg and Ubuntu's
# containerd package. RHEL-family support may come later.
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
    if [ "${CC_ALLOW_UNTESTED_OS:-0}" != "1" ]; then
        echo "ERROR: tested on Ubuntu 24.04 only (found ${PRETTY_NAME:-unknown})." >&2
        echo "       Set CC_ALLOW_UNTESTED_OS=1 to try anyway (apt-based systems only)." >&2
        exit 1
    fi
    echo "!! untested OS ${PRETTY_NAME:-unknown}, continuing because CC_ALLOW_UNTESTED_OS=1" >&2
fi

# Subnet the addresses below are carved from. In lab mode the node is host
# <index> of it; MetalLB's pool is hosts LB_POOL_FIRST..LB_POOL_LAST of it.
# The default is the reference lab's network -- change it to match yours.
NODE_CIDR="${NODE_CIDR:-192.168.40.0/24}"
LB_POOL_FIRST="${LB_POOL_FIRST:-240}"
LB_POOL_LAST="${LB_POOL_LAST:-242}"

cc_ip2int() { # a.b.c.d -> integer
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}
cc_int2ip() { # integer -> a.b.c.d
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}
cc_cidr_host() { # cidr n -- the n-th host address of cidr, or fail if n is outside it
    local net="${1%/*}" bits="${1#*/}" n="$2" size base
    case "$bits" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bits" -ge 1 ] && [ "$bits" -le 30 ] || return 1
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    size=$(( 1 << (32 - bits) ))
    [ "$n" -ge 1 ] && [ "$n" -le $(( size - 2 )) ] || return 1
    base=$(( $(cc_ip2int "$net") & ~(size - 1) & 0xFFFFFFFF ))
    cc_int2ip $(( base + n ))
}
# Fail early and clearly on a malformed NODE_CIDR rather than deep inside
# cc_cidr_host with a message about some other setting.
if ! printf '%s' "$NODE_CIDR" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([1-9]|[12][0-9]|30)$'; then
    echo "ERROR: NODE_CIDR='$NODE_CIDR' is not an IPv4 CIDR such as 192.168.40.0/24 (prefix 1-30)" >&2
    exit 1
fi

cc_cidr_host_or_die() { # cidr n what
    cc_cidr_host "$1" "$2" || {
        echo "ERROR: $3: host $2 does not fit in NODE_CIDR=$1" >&2
        exit 1
    }
}

# Identity of this node. With an index argument the lab defaults apply
# (host <index> of NODE_CIDR, pupnode<index>); without one, the address
# holding the default route and the short hostname are used. Any of them can
# be set explicitly. CC_FQDN is the name users will browse to -- set it.
if [ -n "$INDEX" ]; then
    [ -n "${PRIVATE_IP:-}" ] || PRIVATE_IP="$(cc_cidr_host_or_die "$NODE_CIDR" "$INDEX" "lab index")"
    NODE_NAME="${NODE_NAME:-pupnode${INDEX}}"
else
    PRIVATE_IP="${PRIVATE_IP:-$(ip -o -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' || true)}"
    NODE_NAME="${NODE_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
fi
CC_FQDN="${CC_FQDN:-${NODE_NAME}}"
if [ -z "$PRIVATE_IP" ]; then
    echo "ERROR: could not work out this node's address; set PRIVATE_IP" >&2
    exit 1
fi

# Non-root user who gets a kubeconfig in ~/.kube/config: the user who ran
# sudo, else vagrant (the Vagrant provisioner runs as root without sudo).
KUBE_USER="${KUBE_USER:-${SUDO_USER:-vagrant}}"

# kubeadm has no "latest" channel -- the apt repo is per-minor-version, so you
# must name one explicitly. Check https://kubernetes.io/releases/ and pick a
# supported minor before running this; an unpublished value here fails at
# `apt-get update` with a 404.
K8S_MINOR="v1.33"

# Flannel's default. If you change it, change it in both places (kubeadm init
# and the flannel ConfigMap) or pods get addresses the control plane rejects.
POD_CIDR="10.244.0.0/16"

LOCAL_PATH_VERSION="v0.0.31"

# MetalLB. kubeadm has no cloud controller, so nothing ever fills in
# .status.loadBalancer.ingress and every LoadBalancer Service sits at
# <pending> forever. MetalLB in L2 mode is the missing piece: it hands out
# addresses from a pool you own and ARPs for them on the lab NIC.
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"

# Addresses MetalLB may hand out: hosts LB_POOL_FIRST..LB_POOL_LAST of
# NODE_CIDR, unless LB_POOL is given outright. Off the lab, pick addresses
# that are unused on your network (see docs/scripts/README.md); on a cloud VPC
# they are only reachable from the node itself, which is what the socat bridge
# below relies on. In the lab they live on the SAME subnet as the nodes, so
# they must be addresses no pupnode will ever take -- hosts 240-242 mean
# pupnode240, pupnode241 and pupnode242 are reserved and must never be booted. They must
# also sit outside the DHCP range of that network (lab check:
# virsh net-dumpxml vagrant-libvirt).
if [ -z "${LB_POOL:-}" ]; then
    LB_POOL_START="$(cc_cidr_host_or_die "$NODE_CIDR" "$LB_POOL_FIRST" "LB_POOL_FIRST")"
    LB_POOL_END="$(cc_cidr_host_or_die "$NODE_CIDR" "$LB_POOL_LAST" "LB_POOL_LAST")"
    LB_POOL="${LB_POOL_START}-${LB_POOL_END}"
fi

# The address the ClusterControl entry point gets pinned to, so it survives
# helm uninstall/reinstall and can be hardcoded in the socat bridge below.
# Defaults to the first address of the pool.
LB_IP="${LB_IP:-${LB_POOL%%-*}}"

# Service that fronts the UI. With the Gateway API chart this is the NGF data
# plane Service, which NGF names after the Gateway. Older charts called it
# cmon-master-public, older still exposed ingress-nginx. If the name is wrong
# the pinning step below falls back to "the one LoadBalancer in the namespace"
# rather than silently doing nothing, which is how ${LB_IP} ended up correct
# by luck rather than by design.
LB_SVC="${LB_SVC:-clustercontrol-gateway-nginx}"

CC_RELEASE="${CC_RELEASE:-clustercontrol}"
CC_CHART_REF="${CC_CHART_REF:-s9s-ngf/clustercontrol}"
# Empty = latest published chart, resolved once after `helm repo update`.
CC_CHART_VERSION="${CC_CHART_VERSION:-}"

# Backend TLS from the gateway to cmon-master. NOT optional in practice:
# ccmgr (19051) and cmon (9501) are TLS-only listeners, so with this off the
# gateway proxies plain HTTP to them and "/" returns
#   400 Client sent an HTTP request to an HTTPS server.
# It cannot be a plain --set at install time, because Gateway API's
# BackendTLSPolicy always verifies the backend certificate (no skip-verify),
# and cmon generates its 9501 certificate at runtime -- so the CA bundle can
# only be built once the pods are up. See cc_enable_backend_tls().
CC_BACKEND_TLS="${CC_BACKEND_TLS:-1}"
CC_BACKEND_CA_CM="${CC_BACKEND_CA_CM:-cmon-backend-ca}"

# Readiness polling for the ClusterControl release. We do NOT use `helm
# --wait` -- see the long comment above the install below. These control the
# hand-rolled wait instead.
CC_READY_TIMEOUT=${CC_READY_TIMEOUT:-2700}   # give up after 45m
CC_READY_INTERVAL=${CC_READY_INTERVAL:-10}   # seconds between polls
CC_READY_STABLE=${CC_READY_STABLE:-3}        # consecutive all-green polls required
CC_IMAGE_GRACE=${CC_IMAGE_GRACE:-300}        # seconds of image-pull errors before giving up

# Pods the operators create *after* helm returns, so "everything is ready" is
# not accidentally true in the gap before they exist. Matched as name prefixes.
# e.g. clustercontrol- matches clustercontrol-0, the MySQL pod. It also matches the gateway, 
#   router and other clustercontrol-* pods,
#   then cmon-master matches cmon-master-0
CC_REQUIRED_PODS=${CC_REQUIRED_PODS:-"clustercontrol- cmon-master"}

# ---------------------------------------------------------------------------
# Third-party image mirror (Google Artifact Registry)
#
# The chart's values.yaml points NGINX Gateway Fabric at our GAR mirror rather
# than ghcr.io, because upstreams keep pruning artifacts we depend on. The
# catch: when the chart bumps NGF faster than scripts/mirror-to-gar.sh is run,
# the mirrored tag simply does not exist, and the install dies 15 minutes later
# in the cert-generator pre-install hook with an ImagePullBackOff whose error
# message says nothing about the mirror. cc_gar_has_image() below turns that
# into an up-front decision.
# ---------------------------------------------------------------------------
GAR_HOST="europe-docker.pkg.dev"
GAR_MIRROR="${GAR_HOST}/severalnines-public/clustercontrol/mirror"
NGF_VERSION="${NGF_VERSION:-2.6.8}"
NGF_MIRROR_REPO="${GAR_MIRROR}/nginx/nginx-gateway-fabric"
NGF_UPSTREAM_REPO="ghcr.io/nginx/nginx-gateway-fabric"

# auto   -- use the mirror if it has NGF_VERSION, else fall back to ghcr.io
# mirror -- always use the mirror (fail loudly if it is not seeded)
# ghcr   -- always bypass the mirror
CC_NGF_IMAGE_SOURCE="${CC_NGF_IMAGE_SOURCE:-auto}"

# Seeding the mirror before installing:
#   auto -- (default) only when the tag is actually missing AND credentials
#           are available. Never fatal: no credentials on this box just means
#           the install uses ghcr.io instead, which is what a lab wants.
#   1    -- always seed, and fail the provision if it cannot.
#   0    -- never seed.
# Credentials reach us from the host through the Vagrantfile's env: block, so
# `vpup 100` with CC_GAR_TOKEN exported (or gcloud logged in on the host)
# seeds the mirror as part of an ordinary provision, with nothing to remember.
CC_MIRROR_TO_GAR="${CC_MIRROR_TO_GAR:-auto}"
# Found next to this script when run from a checkout (docs/scripts/ -> scripts/),
# else at the lab's synced-folder path (Vagrant uploads the script to /tmp).
CC_MIRROR_SCRIPT_REPO="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/../../scripts/mirror-to-gar.sh"
if [ -f "$CC_MIRROR_SCRIPT_REPO" ]; then
    CC_MIRROR_SCRIPT="${CC_MIRROR_SCRIPT:-$CC_MIRROR_SCRIPT_REPO}"
else
    CC_MIRROR_SCRIPT="${CC_MIRROR_SCRIPT:-/vagrant/non-ansible-files/s9s-cbase/cc-helm-charts-nginx-gw-dev/scripts/mirror-to-gar.sh}"
fi
CC_GAR_TOKEN="${CC_GAR_TOKEN:-}"

export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG=/etc/kubernetes/admin.conf

# ---------------------------------------------------------------------------
# Find the interface holding the private_network address. vagrant-libvirt puts
# its management NAT net on eth0 and private_network on eth1. k3s had
# --flannel-iface for this; with kubeadm you have to fix it in three separate
# places: the API server advertise address, the kubelet's --node-ip, and
# flannel's --iface. Miss any one and you get a cluster that appears healthy
# but is unreachable from the lab network, or pod networking that silently
# routes over the wrong NIC.
# ---------------------------------------------------------------------------
FLANNEL_IFACE=$(ip -o -4 addr show | awk -v ip="$PRIVATE_IP" '$4 ~ ip"/" {print $2}')
if [ -z "$FLANNEL_IFACE" ]; then
    echo "ERROR: could not find interface holding $PRIVATE_IP" >&2
    ip -o -4 addr show >&2
    exit 1
fi
echo "==> private network is on ${FLANNEL_IFACE} (${PRIVATE_IP})"

# ---------------------------------------------------------------------------
# HOST PREP
#
# kubelet refuses to start with swap enabled (unless you explicitly opt into
# the still-beta swap support), and the bridge/forwarding sysctls are required
# for any CNI to pass traffic. k3s bundles all of this into its installer.
# ---------------------------------------------------------------------------
echo "==> preparing host"

swapoff -a
sed -i.bak '/[[:space:]]swap[[:space:]]/ s/^\(.*\)$/#\1/g' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# The node must be able to resolve its own name, and ClusterControl's ingress
# host is the same name.
grep -q "${PRIVATE_IP}[[:space:]]\+${CC_FQDN}" /etc/hosts || \
    echo "${PRIVATE_IP} ${CC_FQDN}" >> /etc/hosts

# ---------------------------------------------------------------------------
# PACKAGES: container runtime + kubeadm/kubelet/kubectl
#
# k3s ships its own containerd inside a single binary. Here the runtime is a
# separate component you install, configure, and keep in sync yourself.
# ---------------------------------------------------------------------------
echo "==> installing containerd and kubernetes packages"

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
# Unattended upgrades skipping a minor version will break the cluster. Pin
# them; upgrades are a deliberate `kubeadm upgrade` operation.
apt-mark hold kubelet kubeadm kubectl >/dev/null

# ---------------------------------------------------------------------------
# containerd: the cgroup driver must match the kubelet's (systemd), or the
# kubelet starts, runs for a while, and then pods die in confusing ways.
# Ubuntu's shipped config.toml is a stub, so generate the real default first.
# ---------------------------------------------------------------------------
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
    echo "==> configuring containerd for the systemd cgroup driver"
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    # Keep the pause image aligned with what this kubeadm expects, otherwise
    # containerd pulls its own and you get an orphaned sandbox image warning.
    PAUSE_IMAGE=$(kubeadm config images list 2>/dev/null | grep -m1 pause || true)
    if [ -n "$PAUSE_IMAGE" ]; then
        sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|" \
            /etc/containerd/config.toml
    fi
    systemctl restart containerd
fi
systemctl enable containerd >/dev/null

# ---------------------------------------------------------------------------
# Pin the kubelet to the lab NIC before init, so the Node object registers
# with the right InternalIP.
# ---------------------------------------------------------------------------
echo "KUBELET_EXTRA_ARGS=--node-ip=${PRIVATE_IP}" > /etc/default/kubelet

# ---------------------------------------------------------------------------
# CONTROL PLANE
#
# The extra cert SANs matter if you forward 6443 to the host and want to use
# kubectl from outside the guest -- the API server certificate is only valid
# for the names listed at init time, and regenerating it later is a chore.
# ---------------------------------------------------------------------------
if [ ! -f /etc/kubernetes/admin.conf ]; then
    echo "==> pre-pulling control plane images"
    kubeadm config images pull

    echo "==> running kubeadm init"
    # kubeadm init \
    #     --apiserver-advertise-address="${PRIVATE_IP}" \
    #     --apiserver-cert-extra-sans="${CC_FQDN},127.0.0.1,localhost" \
    #     --pod-network-cidr="${POD_CIDR}" \
    #     --node-name="${CC_FQDN}" \
    #     --cri-socket=unix:///run/containerd/containerd.sock
    # The ClusterControl name too, when it differs from the node name, so
    # kubectl can use it to reach the API server.
    API_FQDN_SAN=""
    [ "$CC_FQDN" = "$NODE_NAME" ] || API_FQDN_SAN="    - ${CC_FQDN}
"
    cat <<eof > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${PRIVATE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${PRIVATE_IP}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16
apiServer:
  certSANs:
    - ${NODE_NAME}
${API_FQDN_SAN}    - 127.0.0.1
    - localhost
  extraArgs:
    - name: event-ttl
      value: 24h
eof
    kubeadm init --config /tmp/kubeadm-config.yaml

else
    echo "==> control plane already initialised, skipping kubeadm init"
fi

# Kubeconfig for root and for ${KUBE_USER}, if that user exists.
if [ "$KUBE_USER" != "root" ] && id "$KUBE_USER" >/dev/null 2>&1; then
    KUBE_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
    install -d -o "$KUBE_USER" -g "$(id -gn "$KUBE_USER")" "${KUBE_HOME}/.kube"
    cp /etc/kubernetes/admin.conf "${KUBE_HOME}/.kube/config"
    chown "$KUBE_USER":"$(id -gn "$KUBE_USER")" "${KUBE_HOME}/.kube/config"
    chmod 600 "${KUBE_HOME}/.kube/config"
    grep -q 'KUBECONFIG' "${KUBE_HOME}/.bashrc" 2>/dev/null || \
        echo 'export KUBECONFIG=$HOME/.kube/config' >> "${KUBE_HOME}/.bashrc"
fi
grep -q 'KUBECONFIG' /root/.bashrc || \
    echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> /root/.bashrc

echo "==> waiting for the API server to answer"
timeout 180 bash -c 'until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done'

# ---------------------------------------------------------------------------
# CNI
#
# Without this the node stays NotReady forever and CoreDNS sits in Pending.
# The manifest is patched to pin flannel to the lab NIC -- by default it picks
# the interface holding the default route, which here is the libvirt
# management NAT, and pod-to-pod traffic then goes nowhere useful.
# ---------------------------------------------------------------------------
if ! kubectl -n kube-flannel get daemonset kube-flannel-ds >/dev/null 2>&1; then
    echo "==> installing flannel on ${FLANNEL_IFACE}"
    curl -fsSL -o /tmp/kube-flannel.yml \
        https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    sed -i "s|^\( *\)- --kube-subnet-mgr|\1- --kube-subnet-mgr\n\1- --iface=${FLANNEL_IFACE}|" \
        /tmp/kube-flannel.yml
    sed -i "s|10.244.0.0/16|${POD_CIDR}|g" /tmp/kube-flannel.yml
    kubectl apply -f /tmp/kube-flannel.yml
fi

# ---------------------------------------------------------------------------
# Single-node clusters must drop the control-plane taint or nothing schedules.
# k3s does not apply this taint at all on a server node.
# ---------------------------------------------------------------------------
echo "==> removing control-plane taint"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo "==> waiting for node to become Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

# ---------------------------------------------------------------------------
# STORAGE
#
# The ClusterControl chart's PVCs need a *default* StorageClass. kubeadm ships
# no provisioner whatsoever, so pods would sit in Pending indefinitely. This
# installs the same local-path provisioner k3s bundles, then marks it default,
# which the upstream manifest does not do.
# ---------------------------------------------------------------------------
if ! kubectl get storageclass local-path >/dev/null 2>&1; then
    echo "==> installing local-path provisioner"
    kubectl apply -f \
        "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
    kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
fi
kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
    >/dev/null

# ---------------------------------------------------------------------------
# Readiness helpers
#
# `helm install --wait` cannot be used for this chart on kubeadm. Helm's
# readiness check treats a Service of type LoadBalancer as not-ready until
# .status.loadBalancer.ingress is populated, and kubeadm ships no
# LoadBalancer implementation (that is the same fact the NodePort lookup at
# the bottom of this script relies on). So EXTERNAL-IP stays <pending>, helm
# keeps waiting on a condition nothing in the cluster will ever satisfy, and
# the install sits there until --timeout expires and then reports failure --
# even though every pod went Running/Ready minutes in.
#
# So: install without --wait, then poll pods ourselves, which is exactly what
# you would do by eye with `kubectl -n clustercontrol get pods -o wide`: a pod
# counts as up when STATUS is Running and its READY column reads n/n.
# ---------------------------------------------------------------------------

# Prints one "name ready status" line per pod that is not up yet; prints
# nothing when they all are. Succeeded/Completed pods (install jobs) pass.
cc_pods_not_ready() {
    printf '%s\n' "$1" | awk '
        NF == 0 { next }
        {
            split($2, r, "/")
            if ($3 == "Succeeded" || $3 == "Completed") next
            if ($3 == "Running" && r[2] != 0 && r[1] == r[2]) next
            print $1 " " $2 " " $3
        }'
}

# Pods stuck fetching an image are never going to recover on their own; no
# point burning the full timeout on them.
cc_pods_image_stuck() {
    printf '%s\n' "$1" | awk '
        $3 ~ /ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError/ \
            { print $1 " " $3 }'
}

# Every prefix in CC_REQUIRED_PODS must match at least one pod.
cc_missing_required() {
    local prefix missing=""
    for prefix in $CC_REQUIRED_PODS; do
        printf '%s\n' "$1" | grep -q "^${prefix}" || missing="${missing}${prefix}* "
    done
    printf '%s' "$missing"
}

# Block until every pod in the namespace is up and the required ones exist,
# and stay that way for CC_READY_STABLE polls in a row (the stability window
# keeps us from declaring victory in the gap before the mysql-operator has
# created cmon-master-0). Returns 1 on timeout or a stuck image pull.
cc_wait_for_pods() {
    local ns="$1"
    local started=$SECONDS
    local deadline=$((started + CC_READY_TIMEOUT))
    local stable=0 image_bad_since=0
    local snapshot pending missing stuck reason last_reason=""

    echo "==> waiting for pods in ${ns} to become ready (timeout ${CC_READY_TIMEOUT}s)"
    while [ "$SECONDS" -lt "$deadline" ]; do
        snapshot=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null || true)
        missing=$(cc_missing_required "$snapshot")
        pending=$(cc_pods_not_ready "$snapshot")

        if [ -z "$missing" ] && [ -z "$pending" ]; then
            stable=$((stable + 1))
            if [ "$stable" -ge "$CC_READY_STABLE" ]; then
                echo "==> all pods in ${ns} are Running and ready"
                kubectl -n "$ns" get pods -o wide
                return 0
            fi
        else
            stable=0
        fi

        # Bail out early on image pulls that have been failing for a while.
        stuck=$(cc_pods_image_stuck "$snapshot")
        if [ -n "$stuck" ]; then
            [ "$image_bad_since" -eq 0 ] && image_bad_since=$SECONDS
            if [ $((SECONDS - image_bad_since)) -ge "$CC_IMAGE_GRACE" ]; then
                echo "!! images have been failing to pull for ${CC_IMAGE_GRACE}s:" >&2
                printf '%s\n' "$stuck" >&2
                return 1
            fi
        else
            image_bad_since=0
        fi

        # Only log when something actually changed -- this loop can run for
        # the better part of an hour on a cold image cache.
        reason="${missing:+waiting for }${missing}${pending:+not ready: }$(printf '%s' "$pending" | tr '\n' ';')"
        if [ "$reason" != "$last_reason" ]; then
            echo "    [$((SECONDS - started))s] ${reason:-all ready, confirming...}"
            last_reason="$reason"
        fi

        sleep "$CC_READY_INTERVAL"
    done

    echo "!! timed out after $((SECONDS - started))s waiting for pods in ${ns}" >&2
    return 1
}

# Everything we know at the moment things went wrong.
# Gateway -> cmon-master TLS. Builds the CA bundle both backends' self-signed
# certificates need, then turns the chart's BackendTLSPolicy on.
#
# Idempotent via the ConfigMap: cmon regenerates its 9501 certificate whenever
# cmon-master is recreated, so refreshing the bundle is
#   kubectl -n <ns> delete cm <cm> && vagrant provision <node>
cc_enable_backend_tls() {
    [ "$CC_BACKEND_TLS" = "1" ] || return 0

    if kubectl -n "${CC_NAMESPACE}" get configmap "${CC_BACKEND_CA_CM}" >/dev/null 2>&1; then
        echo "==> backend TLS already configured (configmap ${CC_BACKEND_CA_CM})"
        return 0
    fi

    echo "==> building the gateway -> cmon-master CA bundle"
    local tmp cmon_ip
    tmp="$(mktemp -d)"

    # ccmgr's certificate is issued by the chart, so it can be read from its
    # Secret. Its stock cert carries no CN and no SAN and could never be
    # verified -- the chart replaces it, which is what makes this work at all.
    if ! kubectl -n "${CC_NAMESPACE}" get secret "${CC_RELEASE}-ccmgr-tls" \
            -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "${tmp}/ccmgr.crt" ||
       [ ! -s "${tmp}/ccmgr.crt" ]; then
        echo "!! could not read secret ${CC_RELEASE}-ccmgr-tls -- skipping backend TLS" >&2
        rm -rf "${tmp}"; return 0
    fi

    # cmon's 9501 certificate only exists at runtime, so read it off the live
    # listener. The node can dial a ClusterIP directly (kube-proxy programmed
    # it), which avoids needing a port-forward inside a provisioning script.
    cmon_ip="$(kubectl -n "${CC_NAMESPACE}" get svc cmon-master -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    if [ -z "$cmon_ip" ]; then
        echo "!! service cmon-master not found -- skipping backend TLS" >&2
        rm -rf "${tmp}"; return 0
    fi
    openssl s_client -connect "${cmon_ip}:9501" -showcerts </dev/null 2>/dev/null \
        | openssl x509 -outform PEM > "${tmp}/cmon.crt" || true
    if [ ! -s "${tmp}/cmon.crt" ]; then
        echo "!! could not read cmon's certificate from ${cmon_ip}:9501 -- skipping backend TLS" >&2
        rm -rf "${tmp}"; return 0
    fi

    # The key MUST be ca.crt: the Gateway API spec mandates that name.
    cat "${tmp}/cmon.crt" "${tmp}/ccmgr.crt" > "${tmp}/ca-bundle.crt"
    kubectl -n "${CC_NAMESPACE}" create configmap "${CC_BACKEND_CA_CM}" \
        --from-file=ca.crt="${tmp}/ca-bundle.crt"
    rm -rf "${tmp}"

    # --no-hooks: NGF tags its cert-generator RBAC helm.sh/hook: pre-install
    # only, so on an upgrade the pre-upgrade Job it creates has no
    # ServiceAccount and hangs until the timeout. The webhook certs already
    # exist from the install, so there is nothing for that hook to do here.
    # The parent chart's only other hook is a test.
    echo "==> enabling backend TLS"
    if ! helm upgrade "${CC_RELEASE}" "${CC_CHART_REF}" \
            --namespace "${CC_NAMESPACE}" \
            --devel \
            --version "${CC_CHART_VERSION}" \
            --reuse-values \
            --no-hooks \
            --timeout 10m \
            --set cmon.gateway.backendTLS.enabled=true \
            --set cmon.gateway.backendTLS.caCertificateRef="${CC_BACKEND_CA_CM}"; then
        echo "!! enabling backend TLS failed; removing ${CC_BACKEND_CA_CM} so a re-run retries" >&2
        kubectl -n "${CC_NAMESPACE}" delete configmap "${CC_BACKEND_CA_CM}" --ignore-not-found
        return 1
    fi
}

cc_gar_has_image() { # repo tag -- 0 if the manifest is in the registry
    local repo="$1" tag="$2" host path http
    host="${repo%%/*}"
    path="${repo#*/}"
    http=$(curl -L -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
        "https://${host}/v2/${path}/manifests/${tag}" 2>/dev/null || echo 000)
    [ "$http" = "200" ]
}

cc_mirror_give_up() { # reason -- fatal only when seeding was demanded
    echo "!! $1" >&2
    if [ "$CC_MIRROR_TO_GAR" = "1" ]; then
        exit 1
    fi
    echo "   continuing without seeding; NGF images will come from ghcr.io" >&2
}

# Run the maintainer mirror script (charts/clustercontrol -> GAR). Everything
# it needs that Ubuntu does not ship is installed here rather than assumed.
cc_mirror_to_gar() {
    local arch token
    case "$CC_MIRROR_TO_GAR" in
        0) return 0 ;;
        1) ;;
        auto)
            # Nothing to do if the mirror already has what this install needs.
            cc_gar_has_image "${NGF_MIRROR_REPO}" "${NGF_VERSION}" && return 0
            echo "==> ${NGF_MIRROR_REPO}:${NGF_VERSION} missing from the mirror, trying to seed it"
            ;;
        *) echo "!! unknown CC_MIRROR_TO_GAR='${CC_MIRROR_TO_GAR}' (auto|1|0)" >&2; exit 1 ;;
    esac

    if [ ! -f "$CC_MIRROR_SCRIPT" ]; then
        cc_mirror_give_up "${CC_MIRROR_SCRIPT} does not exist"; return 0
    fi

    # The token comes from the host (Vagrantfile env: block) so that nothing
    # here depends on gcloud being installed in the guest. Tokens last ~1h,
    # ample for a delta mirror. Pushing needs Artifact Registry Writer on
    # severalnines-public/clustercontrol; a read-only account fails at the
    # first COPY, not at login.
    token="${CC_GAR_TOKEN}"
    if [ -z "$token" ] && command -v gcloud >/dev/null 2>&1; then
        token=$(gcloud auth print-access-token 2>/dev/null || true)
    fi
    if [ -z "$token" ]; then
        cc_mirror_give_up "no GAR credentials (CC_GAR_TOKEN empty, no usable gcloud)"; return 0
    fi

    case "$(uname -m)" in
        x86_64)  arch=x86_64 ;;
        aarch64) arch=arm64 ;;
        *) cc_mirror_give_up "no crane/yq build known for $(uname -m)"; return 0 ;;
    esac

    if ! command -v crane >/dev/null 2>&1 && ! command -v skopeo >/dev/null 2>&1; then
        echo "==> installing crane"
        if ! curl -fsSL "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${arch}.tar.gz" \
                | tar -xz -C /usr/local/bin crane; then
            cc_mirror_give_up "could not install crane"; return 0
        fi
    fi

    # MUST be mikefarah v4. Ubuntu's `yq` package is a python jq wrapper with
    # an incompatible CLI: the mirror script's expressions then match nothing
    # and it reports success having mirrored no images at all.
    if ! yq --version 2>/dev/null | grep -q 'mikefarah.*v4'; then
        echo "==> installing yq v4"
        if ! curl -fsSL -o /usr/local/bin/yq \
                "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch/x86_64/amd64}"; then
            cc_mirror_give_up "could not install yq v4"; return 0
        fi
        chmod +x /usr/local/bin/yq
    fi

    echo "==> logging in to ${GAR_HOST}"
    if ! printf '%s' "$token" | crane auth login "${GAR_HOST}" -u oauth2accesstoken --password-stdin ||
       ! printf '%s' "$token" | helm registry login "${GAR_HOST}" -u oauth2accesstoken --password-stdin; then
        token=""
        cc_mirror_give_up "could not authenticate to ${GAR_HOST}"; return 0
    fi
    token=""

    echo "==> mirroring chart dependencies and images to GAR"
    if ! bash "$CC_MIRROR_SCRIPT"; then
        cc_mirror_give_up "mirror script failed"; return 0
    fi
}

cc_dump_state() {
    local ns="$1"
    echo "---- pods ----" >&2
    kubectl -n "$ns" get pods -o wide >&2 || true
    echo "---- workloads ----" >&2
    kubectl -n "$ns" get deploy,sts,ds,job >&2 || true
    echo "---- events (last 30) ----" >&2
    kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -30 >&2 || true
    echo "---- logs from pods that are not ready ----" >&2
    local pod
    for pod in $(cc_pods_not_ready "$(kubectl -n "$ns" get pods --no-headers 2>/dev/null || true)" \
                 | awk '{print $1}'); do
        echo "-- describe ${pod} (conditions/events) --" >&2
        kubectl -n "$ns" describe pod "$pod" 2>/dev/null | sed -n '/^Conditions:/,$p' | tail -25 >&2 || true
    done
}

# ---------------------------------------------------------------------------
# METALLB -- the LoadBalancer implementation kubeadm does not ship
#
# k3s gave you klipper-lb for free, which is why this step has no equivalent
# in the k3s script. Without it `kubectl get svc` shows EXTERNAL-IP
# <pending> for every LoadBalancer Service, forever -- that is not a failure
# to wait out, it is a component that is simply absent.
#
# L2 mode: the speaker answers ARP for the pool addresses on the lab NIC, so
# anything on ${NODE_CIDR} (including the KVM host) can reach them. It is
# deliberately restricted to ${FLANNEL_IFACE} so it never answers on the
# vagrant-libvirt management NAT net.
# ---------------------------------------------------------------------------
if ! kubectl get ns metallb-system >/dev/null 2>&1; then
    echo "==> installing metallb ${METALLB_VERSION}"
    kubectl apply -f \
        "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
else
    echo "==> metallb already installed, skipping manifest"
fi

# The pool below is rejected by the validating webhook until the controller
# is actually serving, so wait rather than race it.
kubectl -n metallb-system rollout status deploy/controller --timeout=300s
kubectl -n metallb-system rollout status ds/speaker --timeout=300s
kubectl -n metallb-system wait --for=condition=ready pod -l component=controller --timeout=300s

# kubeadm labels every control-plane node with
# node.kubernetes.io/exclude-from-external-load-balancers -- upstream's way of
# saying "no external LB traffic here". MetalLB honours it. On a single-node
# cluster the only node is a control-plane node, so NO node is eligible to
# announce: the controller still assigns an address (EXTERNAL-IP looks fine)
# but no speaker ever answers ARP for it, and nothing is logged above debug
# level. k3s never sets this label, which is why the k3s build worked for free.
echo "==> allowing this node to announce LoadBalancer addresses"
kubectl label node "${NODE_NAME}" \
    node.kubernetes.io/exclude-from-external-load-balancers- 2>/dev/null || true

echo "==> configuring metallb pool ${LB_POOL} on ${FLANNEL_IFACE}"
cat <<eof | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
    - ${LB_POOL}
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
  interfaces:
    - ${FLANNEL_IFACE}
eof

# ---------------------------------------------------------------------------
# helm
# ---------------------------------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
    echo "==> installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add s9s-ngf https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/ 2>/dev/null || true
helm repo update

if [ -z "${CC_CHART_VERSION}" ]; then
    CC_CHART_VERSION="$(helm show chart "${CC_CHART_REF}" --devel | awk '/^version:/{print $2}' | tr -d "'\"")" || CC_CHART_VERSION=""
    [ -n "${CC_CHART_VERSION}" ] || { echo "!! could not resolve latest ${CC_CHART_REF} version" >&2; exit 1; }
fi
echo "==> using chart ${CC_CHART_REF} ${CC_CHART_VERSION}"

# Gateway API CRDs (experimental channel: TCPRoute lives only there).
# Not shipped by the chart; they must exist before helm install.
echo "==> installing Gateway API CRDs"
kubectl kustomize \
    "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/experimental?ref=v${NGF_VERSION}" \
    | kubectl apply --server-side --force-conflicts -f -

# Opt-in, and after helm exists: the mirror script drives helm as well as crane.
cc_mirror_to_gar

# ---------------------------------------------------------------------------
# ClusterControl. The bundled MySQL operator refuses to run in the default
# namespace, so a dedicated one is required, not just tidy.
#
# Note there is no --disable traefik equivalent needed here: kubeadm ships no
# ingress controller, so the chart's NGINX Gateway Fabric is the only one present.
# ---------------------------------------------------------------------------
kubectl get ns "${CC_NAMESPACE}" >/dev/null 2>&1 || \
    kubectl create ns "${CC_NAMESPACE}"

# SSH key ClusterControl uses to reach the database hosts it manages. In the
# lab that is the Vagrant user's key, already in every box's authorized_keys.
# Elsewhere point CC_SSH_KEY at a private key your database hosts accept.
# No key file, no Secret -- the install goes ahead without one.
CC_SSH_KEY="${CC_SSH_KEY:-$(getent passwd "$KUBE_USER" 2>/dev/null | cut -d: -f6 || true)/.ssh/id_rsa}"
CC_SSH_SECRET="${CC_SSH_SECRET:-my-ssh-keys}"
if [ -f "$CC_SSH_KEY" ] && ! kubectl -n "${CC_NAMESPACE}" get secret "${CC_SSH_SECRET}" >/dev/null 2>&1; then
    echo "==> creating ssh key secret from ${CC_SSH_KEY}"
    kubectl -n "${CC_NAMESPACE}" create secret generic "${CC_SSH_SECRET}" \
        --from-file=key1="${CC_SSH_KEY}"
fi

# The chart only mounts user keys (at /root/.ssh-keys-user/key1) when
# cmon.sshKeysSecretName is set, so creating the Secret alone does nothing.
# Only pass it when the Secret exists -- otherwise cmon-master-0 would sit in
# ContainerCreating waiting for a volume that never appears.
SSH_SET_ARGS=()
if kubectl -n "${CC_NAMESPACE}" get secret "${CC_SSH_SECRET}" >/dev/null 2>&1; then
    SSH_SET_ARGS=(--set cmon.sshKeysSecretName="${CC_SSH_SECRET}")
fi

CC_STATUS=$(helm -n "${CC_NAMESPACE}" list --filter '^clustercontrol$' \
    -o json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)

if [ "$CC_STATUS" = "deployed" ]; then
    echo "==> clustercontrol already deployed, skipping"
elif [ -n "$CC_STATUS" ]; then
    echo "==> found release in '${CC_STATUS}' state -- uninstalling before retry"
    helm -n "${CC_NAMESPACE}" uninstall clustercontrol --wait || true
    CC_STATUS=""
fi



if helm -n "${CC_NAMESPACE}" status clustercontrol >/dev/null 2>&1; then
    echo "==> clustercontrol release already exists, skipping install"
else
    echo "==> installing clustercontrol chart (this pulls several images, be patient)"

    # for img in \
    #     severalnines/cmon:2.4.0-18159 \
    #     europe-docker.pkg.dev/severalnines-public/clustercontrol/ccmgr:release-2.4.0-220 \
    #     container-registry.oracle.com/mysql/community-server:8.0.45 \
    #     container-registry.oracle.com/mysql/community-router:8.0.45 ; do
    #     echo "==> pre-pulling ${img}"
    #     ctr -n k8s.io images pull "$img" || echo "!! pull failed for ${img}, continuing"
    # done

    # No --wait here: it would block forever on the ingress LoadBalancer
    # Service that kubeadm can never give an external IP to. --timeout still
    # applies to the chart's own install hooks, which do have to finish.
    # Where NGF images come from. Both repositories have to be overridden
    # together: the data-plane image lives inside the NginxProxy CR, so setting
    # only the control-plane one gets you past the cert-generator hook and
    # straight into an ImagePullBackOff on the nginx pods it provisions.
    NGF_SET_ARGS=()
    case "$CC_NGF_IMAGE_SOURCE" in
        mirror)
            echo "==> NGF images: GAR mirror (forced)"
            ;;
        ghcr)
            echo "==> NGF images: ghcr.io (forced, bypassing the mirror)"
            NGF_SET_ARGS=(
                --set nginx-gateway-fabric.nginxGateway.image.repository="${NGF_UPSTREAM_REPO}"
                --set nginx-gateway-fabric.nginx.image.repository="${NGF_UPSTREAM_REPO}/nginx"
            )
            ;;
        auto)
            if cc_gar_has_image "${NGF_MIRROR_REPO}" "${NGF_VERSION}"; then
                echo "==> NGF images: GAR mirror has ${NGF_VERSION}"
            else
                echo "!! ${NGF_MIRROR_REPO}:${NGF_VERSION} is not in the mirror" >&2
                echo "   falling back to ${NGF_UPSTREAM_REPO}; seed the mirror with:" >&2
                echo "     CC_MIRROR_TO_GAR=1 CC_GAR_TOKEN=... $0 ${INDEX}" >&2
                NGF_SET_ARGS=(
                    --set nginx-gateway-fabric.nginxGateway.image.repository="${NGF_UPSTREAM_REPO}"
                    --set nginx-gateway-fabric.nginx.image.repository="${NGF_UPSTREAM_REPO}/nginx"
                )
            fi
            ;;
        *)
            echo "!! unknown CC_NGF_IMAGE_SOURCE='${CC_NGF_IMAGE_SOURCE}' (auto|mirror|ghcr)" >&2
            exit 1
            ;;
    esac

    helm install "${CC_RELEASE}" "${CC_CHART_REF}" \
        --namespace "${CC_NAMESPACE}" \
        --devel \
        --set fqdn="${CC_FQDN}" \
        "${SSH_SET_ARGS[@]}" \
        "${NGF_SET_ARGS[@]}" \
        --version "${CC_CHART_VERSION}" \
        --timeout 15m || {
            echo "!! helm install failed; dumping state" >&2
            cc_dump_state "${CC_NAMESPACE}"
            exit 1
        }
fi

# Ready or not is decided here, not by helm -- on both the fresh-install and
# the already-installed path, so a re-run also tells you the stack is healthy.
cc_wait_for_pods "${CC_NAMESPACE}" || {
    echo "!! clustercontrol did not become ready; dumping state" >&2
    cc_dump_state "${CC_NAMESPACE}"
    exit 1
}

# Needs the pods running (cmon's certificate is generated at runtime), so it
# cannot be folded into the install above.
cc_enable_backend_tls || {
    echo "!! backend TLS not enabled -- \"/\" will return 400 until it is" >&2
}

# ---------------------------------------------------------------------------
# PIN THE ENTRY POINT + BRIDGE IT ONTO THE NODE'S OWN PORTS
#
# Two separate problems, do not confuse them:
#
#   1. MetalLB above clears <pending> and makes https://${LB_IP} work from
#      anywhere on ${NODE_CIDR}. The annotation pins the address so it
#      does not move on the next helm reinstall.
#
#   2. Vagrant's `forwarded_port` does NOT reach that address. vagrant-libvirt
#      implements a forwarded port as an ssh tunnel that terminates INSIDE the
#      guest and connects to the guest's own 127.0.0.1:<guest port>. A MetalLB
#      address is not on any interface -- it only exists in kube-proxy's
#      iptables rules -- so nothing is listening on 127.0.0.1:443 and the
#      tunnel refuses the connection. socat is the two-line fix: listen on the
#      node's real sockets (loopback included) and forward to the LB address.
# ---------------------------------------------------------------------------
# Fall back to whatever LoadBalancer the chart actually created, so a renamed
# service degrades to "still pinned" instead of "silently unpinned".
if ! kubectl -n "${CC_NAMESPACE}" get svc "${LB_SVC}" >/dev/null 2>&1; then
    DETECTED_SVC="$(kubectl -n "${CC_NAMESPACE}" get svc \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | head -1)"
    if [ -n "${DETECTED_SVC}" ]; then
        echo "!! service ${LB_SVC} not found; using ${DETECTED_SVC} instead" >&2
        LB_SVC="${DETECTED_SVC}"
    fi
fi

echo "==> pinning ${LB_SVC} to ${LB_IP}"
if kubectl -n "${CC_NAMESPACE}" get svc "${LB_SVC}" >/dev/null 2>&1; then
    kubectl -n "${CC_NAMESPACE}" annotate svc "${LB_SVC}" \
        "metallb.universe.tf/loadBalancerIPs=${LB_IP}" --overwrite
    kubectl -n "${CC_NAMESPACE}" get svc "${LB_SVC}" -o wide
else
    echo "!! service ${LB_SVC} not found in ${CC_NAMESPACE} -- check:" >&2
    kubectl -n "${CC_NAMESPACE}" get svc >&2 || true
fi

command -v socat >/dev/null 2>&1 || apt-get install -y -qq socat

# 443 and 80 on every local address (0.0.0.0 covers 127.0.0.1, which is what
# the Vagrant tunnel dials, and ${PRIVATE_IP}, which is what a host-side
# DNAT would dial). This does not collide with MetalLB: L2 addresses are never
# bound to an interface.
cc_bridge_unit() {
    local port="$1"
    cat >"/etc/systemd/system/cc-bridge-${port}.service" <<eof
[Unit]
Description=Bridge node port ${port} to the ClusterControl LoadBalancer address
After=network-online.target kubelet.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat -d TCP4-LISTEN:${port},bind=0.0.0.0,fork,reuseaddr TCP4:${LB_IP}:${port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
eof
}
cc_bridge_unit 443
cc_bridge_unit 80
systemctl daemon-reload
systemctl enable --now cc-bridge-443.service cc-bridge-80.service
systemctl restart cc-bridge-443.service cc-bridge-80.service

# Prove the whole chain inside the guest before blaming the network.
#
# Always probe by NAME with --resolve, never by address: the Gateway's
# listeners are scoped to hostname ${CC_FQDN}, so a request to a bare IP
# arrives with no SNI, nginx answers TLS alert 112 (unrecognized_name) and
# curl fails with exit 35 before any HTTP code exists. Probing by IP made
# these checks report "socat bridge problem" for a perfectly good bridge.
echo "==> verifying from inside the guest"
sleep 5
cc_probe() { # label address
    curl -sk -o /dev/null --max-time 10 -w "   ${1} -> %{http_code}\n" \
        --resolve "${CC_FQDN}:443:${2}" "https://${CC_FQDN}/" || \
        echo "   ${1} FAILED (${3:-unreachable})"
}
cc_probe "${CC_FQDN} @ ${LB_IP}  " "${LB_IP}"      "metallb / service problem"
cc_probe "${CC_FQDN} @ 127.0.0.1 " "127.0.0.1"     "socat bridge problem"
cc_probe "${CC_FQDN} @ ${PRIVATE_IP}" "${PRIVATE_IP}" "socat bridge problem"

echo
echo "======================================================================"
echo " ClusterControl deployed into namespace: ${CC_NAMESPACE}"
echo " Kubernetes:                             kubeadm ${K8S_MINOR} + flannel + metallb"
echo
echo " The Gateway's listeners are scoped to hostname '${CC_FQDN}', so every"
echo " client must send it as SNI -- a bare IP in the URL gets a TLS alert,"
echo " not a page. Point the name at one of these addresses:"
echo "   ${LB_IP}     (MetalLB address for ${LB_SVC})"
echo "   ${PRIVATE_IP}     (node address, via the socat bridge)"
echo "   <public IP>      (cloud VMs: the node's public address, via the bridge;"
echo "                     open 443/tcp in the provider's firewall)"
echo
echo " e.g. on the client:  echo '${LB_IP} ${CC_FQDN}' >> /etc/hosts"
echo "      then browse:    https://${CC_FQDN}/"
echo "      or test with:   curl -k --resolve ${CC_FQDN}:443:${LB_IP} https://${CC_FQDN}/"
echo
echo " First login: there is no preset admin password -- the UI asks you to"
echo " create the admin user on your first visit."
echo
echo " Generated credentials, if you need them:"
echo "   cmon RPC user (ccrpc) password:"
echo "     kubectl -n ${CC_NAMESPACE} get secret cmon-credentials \\"
echo "       -o jsonpath='{.data.cmon-password}' | base64 -d"
echo "   setup key (INITIAL_PASSWORD in the UI's config.js):"
echo "     kubectl -n ${CC_NAMESPACE} get secret cmon-ccsetup \\"
echo "       -o jsonpath='{.data.ccsetup-password}' | base64 -d"
echo
echo " Watch it come up:"
echo "   kubectl -n ${CC_NAMESPACE} get pods -w"
echo "======================================================================"
