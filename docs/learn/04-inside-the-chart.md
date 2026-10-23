# 4. Inside the chart

[← The install script](03-install-script-walkthrough.md) · Next: [Day-2 operations →](05-day-2-operations.md)

The install script ends in one `helm install`. This page opens up what that command installs:
[charts/clustercontrol](../../charts/clustercontrol).

```text
charts/clustercontrol/
├── Chart.yaml                  identity + dependencies
├── values.yaml                 defaults for every input
├── templates/
│   ├── _helpers.tpl            named snippets (names, labels, image selection)
│   ├── deployment.yaml         StatefulSet cmon-master + 4 PVCs
│   ├── service.yaml            Service cmon-master (+ an ExternalName "severalnines")
│   ├── secrets.yaml            cmon.cnf, credentials, s9s.conf, ssh-keys, config.js
│   ├── certs.yaml              self-signed TLS for the Gateway and for ccmgr
│   ├── gateway.yaml            Gateway, HTTPRoutes, TCPRoute, SnippetsFilter, BackendTLSPolicy
│   ├── NOTES.txt               the message helm prints after install
│   └── tests/test-connection.yaml   `helm test` pod
└── files/ssh-keys/             example key pair, packed into Secret "ssh-keys"
```

---

## `Chart.yaml` — identity and dependencies

```yaml
name: clustercontrol
version: '0.1.2'           # the CHART's version — what --version selects
appVersion: '2.5.0-24068'  # the APPLICATION version — also the default cmon image tag
dependencies:
  - name: mysql-operator           # condition: installMysqlOperator
  - name: mysql-innodbcluster      # condition: createDatabases
  - name: victoria-metrics-single  # condition: monitoring.enabled, alias: monitoring
  - name: nginx-gateway-fabric     # condition: gatewayController.enabled
```

* **Chart version vs app version.** Bumping `version` is what publishes a new chart (the release
  workflow triggers on `Chart.yaml` changes). `appVersion` is the cmon version: when `cmon.image`
  is empty (the default) the chart runs `severalnines/cmon:<appVersion>`. The other images are
  set in `values.yaml` (`cmon.ccmgr.image`, `cmon.kuberProxy.image`, …).
* **Dependencies are whole charts** installed as part of this release. Each has a `condition` —
  a value that switches it off, e.g. `--set gatewayController.enabled=false` if the cluster already
  has a Gateway API implementation.
* **`alias: monitoring`** means the VictoriaMetrics subchart's values live under `monitoring:` in
  `values.yaml`, not under `victoria-metrics-single:`.
* Three dependencies come from the Severalnines GAR mirror (`oci://europe-docker.pkg.dev/…`), NGF from
  `oci://ghcr.io/nginx/charts`. `helm dependency update charts/clustercontrol` fetches them into
  `charts/clustercontrol/charts/` when you work from a checkout.

## `values.yaml` — the inputs

Values form one tree. `--set a.b.c=x` and `-f file.yaml` override leaves of it; the *subchart's*
values sit under the subchart's name (or alias).

| Path | Default | What it controls |
|------|---------|------------------|
| `fqdn` | `localhost` | **required in practice.** Gateway hostname and TLS certificate name. The install script sets it to `CC_FQDN` |
| `storageClassName` | *(empty)* | empty → the cluster default (local-path, when the install script built the cluster) |
| `installMysqlOperator` / `createDatabases` | `true` / `true` | bring your own MySQL by setting both false and filling `cmon.db.*` |
| `gatewayController.enabled` | `true` | install NGF as a subchart |
| `cmon.license` | *(empty)* | ClusterControl licence; creates Secret `cmon-license` when set |
| `cmon.sshKeysSecretName` | *(empty)* | your Secret of SSH keys, mounted at `/root/.ssh-keys-user` |
| `cmon.user` / `cmon.password` | `ccrpc` / *(random)* | cmon RPC credentials |
| `cmon.db.*` | operator's InnoDB Cluster | cmon's own database |
| `cmon.image`, `.ccmgr.image`, `.kuberProxy.image`, … | | container images (`devBuild: true` switches to `devImage`) |
| `cmon.gateway.enabled` | `true` | render `gateway.yaml` at all |
| `cmon.gateway.ssl.clusterIssuer` | *(empty)* | use cert-manager instead of a self-signed cert |
| `cmon.gateway.ssl.selfSigned.extraDNSNames/extraIPs` | `[]` | extra names in the self-signed cert |
| `cmon.gateway.backendTLS.enabled` / `.caCertificateRef` | `false` / *(empty)* | gateway → cmon-master TLS; the install script turns it on after install |
| `mysql-innodbcluster.serverInstances` | `1` | MySQL instances (1 is fine for a lab) |
| `monitoring.*` | VictoriaMetrics single | metrics store; scrape config uses cmon service discovery |
| `nginx-gateway-fabric.*` | experimental features + snippets on | NGF subchart; images default to `ghcr.io` |

See every value with its comment:

```bash
helm show values s9s-ngf/clustercontrol --devel --version 0.1.2 | less
```

## Templates — how YAML gets generated

A template is YAML with Go-template actions. Three patterns appear throughout this chart:

```yaml
# 1. substitute a value
hostname: {{ .Values.fqdn }}

# 2. render a block only when a value is set
{{ if .Values.cmon.gateway.enabled }} … {{ end }}

# 3. look at the LIVE cluster during install/upgrade
{{- $existing := lookup "v1" "Secret" .Release.Namespace "cmon-credentials" }}
```

`lookup` is how the chart keeps generated secrets stable: on first install it generates random
passwords and self-signed certificates; on every upgrade it finds the existing Secret and reuses
it, so an upgrade never rotates a password or certificate under a running cmon. (`helm template`
and `--dry-run` cannot reach the cluster, so they always show freshly generated values — expected.)

Render the chart without installing anything:

```bash
helm template clustercontrol s9s-ngf/clustercontrol --devel --version 0.1.2 \
  --namespace clustercontrol --set fqdn=cc.example.com > /tmp/cc.yaml
grep -n '^kind:' /tmp/cc.yaml | sort -k2 | uniq -c -f1
```

## What gets created

### The ClusterControl pod — StatefulSet `cmon-master`

One pod, `cmon-master-0`, with several containers that share its network address and volumes:

| Container | Port(s) | Role |
|-----------|---------|------|
| *init-cmon*, *check-cmon-configs* (init) | | prepare `cmon.cnf` and `s9s.conf` |
| *init-ccmgr* (init) | | prepare ccmgr's directory and install the chart-issued TLS cert |
| `cmon-master` | 9501 (RPC v2, TLS), 9500 | **cmon**, the ClusterControl controller |
| `cmon-cloud` | 9518 | cloud backup helper |
| `cmon-sd` | 8080 | Prometheus-style service discovery for VictoriaMetrics |
| `cmon-exporter` | 9954 | cmon's own metrics |
| `cmon-ssh` | 9511 | web SSH terminal |
| `ccmgr` | 19051 (TLS) | serves the ClusterControl v2 web UI and proxies to cmon |
| `kuber-proxy` | 8081, 50051 | ClusterControl's Kubernetes operator proxy |

Four 1 GiB PVCs keep state across pod restarts: `cmon-master-volume`, `cmon-var-lib-cmon`,
`cmon-ccmgr-volume`, `kuber-proxy-volume`.

Service `cmon-master` (ClusterIP) exposes every one of those ports inside the cluster.

### Configuration — `secrets.yaml`

| Object | Contents |
|--------|----------|
| Secret `cmon-cnf` | `cmon.cnf`: DB host/port/user, RPC user/key, controller id, Prometheus host |
| Secret `cmon-credentials` | `cmon-user`, `cmon-password` (RPC; random unless `cmon.password` is set) |
| Secret `cmon-ccsetup` | `ccsetup-password` (random) |
| Secret `s9s-conf` | `s9s.conf` for the `s9s` CLI inside the pod |
| Secret `ssh-keys` | everything in `files/ssh-keys/` |
| ConfigMap `config-js` | the UI's `config.js`: API path `/cmon/v2`, version, initial password, registration on |

### The database and monitoring (subcharts)

* **mysql-operator** watches `InnoDBCluster` objects. **mysql-innodbcluster** creates one, named after
  the release (`clustercontrol`), so pods `clustercontrol-0` (MySQL) and a `clustercontrol-router-…`
  appear — that is why the script waits for the `clustercontrol-` prefix. cmon connects to Service
  `clustercontrol:3306`.
* **victoria-metrics-single** (aliased `monitoring`) runs `clustercontrol-monitoring-server`, which
  cmon uses as its Prometheus (`prometheus_hostname` in `cmon.cnf`).

```bash
kubectl -n clustercontrol get innodbcluster
kubectl -n clustercontrol get pods -l app.kubernetes.io/instance=clustercontrol
```

### The front door — `gateway.yaml` and NGF

Described in [Concepts §8](01-concepts.md#8-gateway-api-and-nginx-gateway-fabric). Two details that
only make sense after reading the templates:

* **SnippetsFilter** `clustercontrol-cmon-headers` injects raw nginx directives into the `/cmon`
  location (pass cmon's `Server` header through, keep cookie paths). There is no portable Gateway
  API filter for that, which ties this chart to NGF specifically — and is why
  `nginx-gateway-fabric.nginxGateway.snippets.enable: true` is set.
* **BackendTLSPolicy** verifies the backends against hostname `localhost`, because that is the SAN
  cmon puts in its own 9501 certificate. The chart's ccmgr certificate (`clustercontrol-ccmgr-tls`)
  carries `localhost` too, so one policy covers both.

## One request, end to end

What happens when you open `https://cc.example.com/` (your `CC_FQDN`), with DNS or `/etc/hosts`
pointing that name at the node:

```text
 browser ──TLS, SNI=cc.example.com──▶ <node address>:443
   ▼
 socat cc-bridge-443 on the node ──▶ LB_IP:443
   │  (on a flat LAN you can also dial LB_IP directly: MetalLB's speaker answers ARP for it)
   ▼
 kube-proxy iptables (Service clustercontrol-gateway-nginx, type LoadBalancer)
   ▼
 nginx data-plane pod (NGF)
   │  listener "https", hostname cc.example.com, cert from Secret cmon-cert   ← TLS ends here
   │  HTTPRoute clustercontrol-ccmgr-route:  PathPrefix "/"  → cmon-master:19051
   │  BackendTLSPolicy: open a NEW TLS connection, verify against cmon-backend-ca, name "localhost"
   ▼
 Service cmon-master:19051  ──▶  pod cmon-master-0, container ccmgr
   │  the UI loads config.js, then calls /cmon/v2/…
   ▼
 nginx again: HTTPRoute clustercontrol-cmon-route  "/cmon" → rewrite to "/" → cmon-master:9501
   ▼
 container cmon-master (cmon) ──▶ MySQL via Service clustercontrol:3306
```

In the reference lab, browsing through Vagrant's forwarded port adds one hop at the start —
`127.0.0.1:41000 on the KVM host → SSH tunnel → node 127.0.0.1:443 → socat → LB_IP:443` — and is
identical after that.

## Two ways to install the same chart

| | [Node script](../scripts/README.md) | [scripts/install-clustercontrol.sh](../../scripts/install-clustercontrol.sh) |
|-|-----------|-----------------------------------|
| Builds the cluster | yes (kubeadm, flannel, local-path, MetalLB) | no — needs one |
| Gateway API CRDs | yes | yes (`--skip-crds` to skip) |
| NGF vendor CRDs, cert-generator RBAC on upgrade | no (uses `--no-hooks` on its one upgrade) | yes |
| Helm | `install`, then `upgrade` for backend TLS | `upgrade --install`, then `upgrade --reuse-values` for backend TLS |
| Sets `fqdn` | yes (`CC_FQDN`) | yes (`--fqdn`) |
| Backend CA bundle + backend TLS on | yes | yes (`--skip-ca-bundle` to skip both) |
| Waits for pods | own poller | waits for `cmon-master` |

---

## Try it

1. `helm template … --set fqdn=cc.example.com` and again with `--set cmon.gateway.enabled=false`.
   Diff the two: which objects disappear?
2. Render with `--set cmon.gateway.backendTLS.enabled=true` but without `caCertificateRef`. Read the
   error — which template line produced it (`required …`)?
3. `kubectl -n clustercontrol get secret cmon-cnf -o jsonpath='{.data.cmon\.cnf}' | base64 -d` —
   match each line to the template in `secrets.yaml`.
4. Follow the request path above with real commands: `kubectl get svc`, `kubectl get httproute -o yaml`,
   `kubectl get endpointslices -l kubernetes.io/service-name=cmon-master`.

[← The install script](03-install-script-walkthrough.md) · Next: [Day-2 operations →](05-day-2-operations.md)
