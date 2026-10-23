# 6. Troubleshooting

[← Day-2 operations](05-day-2-operations.md) · [Back to How to use me](../../HOW-TO-USE-ME.md)

Almost every entry below is a failure the install script already guards against; its comments
record how each one was found. When something breaks, work **from the bottom of the stack up** —
a broken layer makes every layer above it look broken too.

```text
  6  ClusterControl     UI / cmon / MySQL pods
  5  Gateway            NGF, routes, TLS, BackendTLSPolicy
  4  LoadBalancer       MetalLB, socat bridge
  3  Storage            StorageClass, PVCs
  2  Pod network        flannel, CoreDNS
  1  Node               containerd, kubelet, kubeadm
  0  Machine            OS, disk, NIC, cloud firewall (reference lab: Vagrant, libvirt)
```

## The five commands that answer most questions

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -v -E 'Running|Completed'          # anything unhappy, any namespace
kubectl -n clustercontrol get events --sort-by=.lastTimestamp | tail -30
kubectl -n clustercontrol describe pod <pod>                   # read Conditions + Events at the bottom
kubectl -n clustercontrol logs <pod> -c <container> --previous # logs of the crashed attempt
```

When the script fails it runs the same checks itself (`cc_dump_state`), so scroll up in its output
(or `~/cc-install.log`) before re-running anything. "Re-run" below means running the install script
again with the same settings ([how](../scripts/README.md#4-run-it); reference lab: `vagrant provision pupnode100`).

---

## The script stops early

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ERROR: tested on Ubuntu 24.04 only` | another OS or release | use Ubuntu 24.04 (RHEL-family is not supported yet) |
| `ERROR: could not work out this node's address` | no default route | set `PRIVATE_IP` |
| `ERROR: NODE_CIDR=… is not an IPv4 CIDR` | typo, or prefix missing / outside 1–30 | e.g. `NODE_CIDR=10.20.0.0/24` |
| `ERROR: …: host N does not fit in NODE_CIDR=…` | lab index or `LB_POOL_FIRST`/`LAST` beyond the subnet size | use a larger subnet or smaller host numbers |
| `ERROR: could not find interface holding <PRIVATE_IP>` | `PRIVATE_IP` is not on any local interface (in the reference lab: the private network did not come up) | `ip -br addr`; fix `PRIVATE_IP` (lab: `vagrant reload pupnode100`) |
| `apt-get update` 404 on `pkgs.k8s.io` | `K8S_MINOR` names an unpublished version | set it to a [supported release](https://kubernetes.io/releases/) |
| `apt-get` errors on Ubuntu repos | broken mirror or no outbound access | `sudo apt-get update` by hand; check egress rules (reference lab: the repo-fix provisioner runs *after* the install on pupnode100) |
| kubelet will not start, `swap` in its logs | swap still on | `swapoff -a`, check `/etc/fstab` |
| `No space left on device` during image pulls | root disk too small | `df -h /` must show 40 GB+; cloud defaults (8–20 GB) must be raised when creating the VM |

## Layer 1–2: node and network

| Symptom | Cause | Fix |
|---------|-------|-----|
| node `NotReady`, CoreDNS `Pending` | no CNI yet | `kubectl -n kube-flannel get pods`; re-run |
| node INTERNAL-IP is not `PRIVATE_IP` | kubelet registered on another NIC | `/etc/default/kubelet` must hold `--node-ip`; `systemctl restart kubelet` |
| pods cannot reach each other / DNS times out | flannel on the wrong NIC | `kubectl -n kube-flannel logs ds/kube-flannel-ds \| grep -i interface` must name the NIC holding `PRIVATE_IP` |
| every pod `Pending`, event mentions *taint* | control-plane taint still present | `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` |
| pods restart randomly, cgroup errors | containerd and kubelet disagree on cgroup driver | `grep SystemdCgroup /etc/containerd/config.toml` → `true`; restart containerd |

## Layer 3: storage

| Symptom | Cause | Fix |
|---------|-------|-----|
| pods `Pending`, PVCs `Pending`, *no persistent volumes available* | no **default** StorageClass | `kubectl get sc` — `local-path` must say `(default)`; re-apply the patch from step 7 |
| PVC `Pending` with `WaitForFirstConsumer` | normal: local-path binds when the pod is scheduled | look at the pod instead |

## Layer 4: LoadBalancer and bridge

| Symptom | Cause | Fix |
|---------|-------|-----|
| `EXTERNAL-IP <pending>` forever | MetalLB missing or pool not applied | `kubectl -n metallb-system get pods,ipaddresspool` |
| `helm install --wait` times out although every pod is Running | Helm waits for the LoadBalancer IP | do not use `--wait`; the script polls pods itself |
| EXTERNAL-IP shows `LB_IP` but even the node gets no answer | node carries `exclude-from-external-load-balancers` | `kubectl label nodes --all node.kubernetes.io/exclude-from-external-load-balancers-` |
| `LB_IP` answers on the node but not from other machines, on a **cloud VPC** | expected: the provider does not route addresses it did not assign | browse to the node's own address instead (socat bridge) |
| `LB_IP` answers on the node but not from the LAN, on a **flat network** | L2Advertisement on the wrong interface, or `LB_IP` inside the DHCP range / already used | check `interfaces:` in `lab-l2`; pick free addresses (lab: `virsh net-dumpxml vagrant-libvirt`) |
| node address times out from your laptop, works on the node | cloud firewall / security group blocks 443 | allow TCP 443 (and 80) inbound |
| node address refuses on 443, `LB_IP` works | socat bridge down | `systemctl status cc-bridge-443`; `ss -ltnp \| grep :443` |
| another machine already uses `LB_IP` | address collision with the pool (lab: a pupnode240–242 VM is running) | set `NODE_CIDR` (or `LB_POOL_FIRST`/`LB_POOL_LAST`, or `LB_POOL`) to free addresses and re-run |
| the address changed after reinstall | annotation not re-applied | re-run, or annotate `metallb.universe.tf/loadBalancerIPs=<LB_IP>` |

## Layer 5: Gateway, TLS and routing

| Symptom | Cause | Fix |
|---------|-------|-----|
| `curl: (35) … unrecognized name` / TLS alert 112 | you connected by IP, so no SNI | connect by name: DNS, `/etc/hosts`, or `curl --resolve <CC_FQDN>:443:<ip>` |
| `404` from nginx | the `Host` does not match `fqdn` | browse to `CC_FQDN`, or change `fqdn` with a helm upgrade |
| `400 Client sent an HTTP request to an HTTPS server` | backend TLS not enabled | step 13 failed: `kubectl -n clustercontrol get cm cmon-backend-ca`; re-run |
| `502` on `/` or `/cmon` | BackendTLSPolicy cannot verify the backend cert — usually cmon-master was recreated and regenerated its 9501 cert | `kubectl -n clustercontrol delete cm cmon-backend-ca`, then re-run |
| `500` on everything under `/cmon` | SnippetsFilter not found (snippets feature off in NGF) | `nginx-gateway-fabric.nginxGateway.snippets.enable=true` |
| install fails: `no matches for kind "TCPRoute"` / `"Gateway"` | Gateway API CRDs missing or standard-channel only | apply the experimental CRDs (step 9) |
| NGF `unknown directive more_set_headers` | old snippet from Ingress-NGINX days | the chart uses `proxy_cookie_path` now; upgrade the chart |
| `helm upgrade` hangs on a cert-generator Job | NGF's RBAC is a `pre-install`-only hook | add `--no-hooks`, or use `scripts/install-clustercontrol.sh` |

Inspect the gateway's own view of things:

```bash
kubectl -n clustercontrol describe gateway clustercontrol-gateway        # Listeners: Accepted / Programmed
kubectl -n clustercontrol describe httproute clustercontrol-cmon-route   # Parents: ResolvedRefs
kubectl -n clustercontrol describe backendtlspolicy
kubectl -n clustercontrol logs deploy/clustercontrol-nginx-gateway-fabric | tail -50
```

## Layer 6: ClusterControl

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ImagePullBackOff` on NGF pods, often inside the cert-generator hook | the GAR mirror lacks that NGF tag | re-run with `CC_NGF_IMAGE_SOURCE=ghcr` |
| `ImagePullBackOff` on other images | tag pruned upstream / typo / no network | `kubectl describe pod` → *Events* shows the exact reference |
| `cmon-master-0` never appears | the MySQL cluster is not ready yet (cmon waits on it) | `kubectl -n clustercontrol get innodbcluster`, logs of the mysql-operator |
| MySQL operator does nothing | installed into `default` | it must run in a dedicated namespace (`clustercontrol`) |
| cmon logs `Can't connect to MySQL` | DB not ready, or wrong `cmon.db.*` | wait; check `cmon-cnf` Secret |
| UI loads, no metrics/dashboards | VictoriaMetrics down, or `prometheusHostname` wrong | `kubectl -n clustercontrol get pods \| grep monitoring` |
| cmon cannot SSH to a database host | user SSH key not mounted | `--set cmon.sshKeysSecretName=my-ssh-keys` ([Day-2](05-day-2-operations.md#adding-database-hosts)) |
| release in `failed` / `pending-install` state | an earlier run died | the script uninstalls and retries when re-run; by hand: `helm -n clustercontrol uninstall clustercontrol` |

## When all else fails

Rebuild: delete the VM (or reinstall Ubuntu 24.04) and run the install script again. In the
reference lab: `vagrant destroy -f pupnode100 && vagrant up pupnode100`.

That is the point of a throwaway machine: a clean rebuild costs half an hour and tells you whether
the problem was in your changes or in the environment.

[← Day-2 operations](05-day-2-operations.md) · [Back to How to use me](../../HOW-TO-USE-ME.md)
