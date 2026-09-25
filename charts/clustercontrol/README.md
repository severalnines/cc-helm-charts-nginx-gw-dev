# ClusterControl helm-chart — NGINX Gateway Fabric

![Helm: v3](https://img.shields.io/static/v1?label=Helm&message=v3&color=informational&logo=helm)

Development build of the ClusterControl chart, exposing ClusterControl through the
**Gateway API** (NGINX Gateway Fabric) instead of the retired Ingress-NGINX controller.

> **Not for production.** Use [severalnines/helm-charts](https://github.com/severalnines/helm-charts) for that.

# Dependencies
This helm chart is designed to provide everything you need to get ClusterControl running in a vanila kubernetes cluster.
This includes dependencies like
* NGINX Gateway Fabric (Gateway API implementation)
* mysql operator and innodbcluster
* victoria metrics

If you do not wish to install any of those, please see [Dependencies](#helm-chart-dependencies) below.

## Gateway API CRDs (one-time, per cluster)

Gateway API types are not part of Kubernetes and are not shipped by any chart, so they
must exist before installing. This is the only prerequisite — NGINX Gateway Fabric's own
CRDs are installed automatically by Helm as part of the chart.

```console
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/experimental?ref=v2.6.8" | kubectl apply --server-side --force-conflicts -f -
```

`--server-side` is required — the `httproutes` schema exceeds the annotation size limit
that client-side apply uses. The **experimental** channel is required because `TCPRoute`,
used for kuber-proxy's gRPC port, only exists there.

Verify (expect 12):

```console
kubectl get crd | grep gateway.networking | wc -l
```

# Install

## Add a S9s helm repository

Add a chart helm repository with follow commands:

```console
helm repo add s9s-ngf https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/
helm repo update
```

## Create a namespace
It's recommended to create a namespace for ClusterControl.
It's also **required** to run in custom namespace (not default) when using mysql-operator - default install
```
kubectl create ns clustercontrol
kubectl config set-context --current --namespace=clustercontrol
```

## Install

```
helm install clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2
```

`--version` is required: versions in this repository are semver prereleases, which Helm
hides unless asked for. `helm search repo s9s-ngf/clustercontrol --versions --devel`
lists them.

## Providing your own SSH keys for ClusterControl to use
ClusterControl provides an example SSH key for you to use, however
You should provide your SSH keys for ClusterControl to use and connect to your target machines.
These should already be configured on target server's `authorized_keys`

### Create k8s secrets with your SSH keys

`key1` is the filename of your ssh key in ClusterControl - this will be created under `/root/.ssh-keys-user`

```
kubectl create secret generic my-ssh-keys --from-file=key1=/path/to/my/.ssh/id_rsa
```

**NOTE**: You can use multiple `--from-file` - be sure to provide unique keynames - `key1`, `key2`, `key3`

### Install or Upgrade ClusterControl

```
helm upgrade --install clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2 \
  --set cmon.sshKeysSecretName=my-ssh-keys
```

## Custom configuration via values.yaml

### Create your own values.yaml

```
helm show values s9s-ngf/clustercontrol --version 0.4.0-ngf.2 > values.yaml
```

### Install / Upgrade using your custom values.yaml

```
helm upgrade --install clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2 -f values.yaml
```

## Exposing the gateway

NGINX Gateway Fabric requests a `LoadBalancer` Service. Pick whichever matches your cluster:

| Cluster | values.yaml |
|---|---|
| MetalLB, or any cloud load balancer | nothing needed; optionally pin an address |
| k3s (klipper-lb built in) | nothing needed |
| No LoadBalancer provider at all | bind the ports on the node |

```yaml
# MetalLB - the address must be inside your IPAddressPool
nginx-gateway-fabric:
  nginx:
    service:
      loadBalancerIP: 192.168.40.100
```

```yaml
# No LoadBalancer provider - binds 0.0.0.0 on the node, covering every interface
nginx-gateway-fabric:
  nginx:
    container:
      hostPorts:
        - {port: 80,    containerPort: 80}
        - {port: 443,   containerPort: 443}
        - {port: 50051, containerPort: 50051}
```

## TLS

### Frontend certificate

The chart issues a self-signed certificate for the HTTPS listener and reuses any existing
Secret, so upgrades never rotate it. Set `cmon.gateway.ssl.clusterIssuer` to let
cert-manager issue it instead — cert-manager watches `Gateway` resources directly.

Add the address you browse to, if that isn't the fqdn:

```yaml
cmon:
  gateway:
    ssl:
      selfSigned:
        extraIPs:
          - 192.168.40.100
```

Self-signed certificates are untrusted by browsers. Import it on the client, or the
handshake is rejected:

```console
kubectl get secret cmon-cert -n clustercontrol -o jsonpath='{.data.tls\.crt}' | base64 -d > cc.crt
sudo cp cc.crt /usr/local/share/ca-certificates/clustercontrol.crt && sudo update-ca-certificates
# Chrome on Linux uses its own NSS store (apt install libnss3-tools):
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n clustercontrol -i cc.crt
```

### Backend TLS

`cmon.gateway.backendTLS` replaces the old
`nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` annotation. **Both cmon (9501) and
ccmgr (19051) are TLS-only listeners**, so with it disabled the gateway proxies plain HTTP
and they reject it — `/` returns 400 and `/cmon/*` returns 500.

Unlike the old annotation, Gateway API's `BackendTLSPolicy` always validates the backend
certificate and has no skip-verify mode, so it needs a CA bundle trusting both backends:

* **ccmgr** — issued by this chart, readable from the `clustercontrol-ccmgr-tls` Secret
* **cmon** — generated by cmon itself at runtime, so it can only be read off the live
  listener once the pod is running

```console
kubectl get secret clustercontrol-ccmgr-tls -n clustercontrol \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ccmgr.crt

kubectl port-forward -n clustercontrol svc/cmon-master 9501:9501 &
openssl s_client -connect localhost:9501 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > cmon-9501.crt
kill %1

# the key MUST be named ca.crt - the Gateway API spec mandates it
cat cmon-9501.crt ccmgr.crt > ca-bundle.crt
kubectl create configmap cmon-backend-ca -n clustercontrol --from-file=ca.crt=ca-bundle.crt
```

Then enable it:

```console
helm upgrade clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2 \
  --set cmon.gateway.backendTLS.enabled=true \
  --set cmon.gateway.backendTLS.caCertificateRef=cmon-backend-ca
```

Rebuild the bundle if `cmon-master` is ever recreated, since cmon regenerates its
certificate.

## Notes
cmon API is accessible within the cluster via cmon-master:9501

ClusterControl V2 is accessible within the cluster via cmon-master:3000

Is is *HIGHLY* recommended to use the Gateway as ClusterControl V2 requires cmon API to be exposed and available externaly.

## Access UI (Gateway API)

Wait for the gateway's Service to get an address:

```console
kubectl get svc clustercontrol-gateway-nginx -n clustercontrol
```

Then set `fqdn` to a DNS name that resolves to it:

```console
helm upgrade --install clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2 \
  --set fqdn=<external-ip>.nip.io
```

Routes match on hostname, so the Host header must be exactly your `fqdn` — browsing the IP
directly returns 404.

Check the gateway came up:

```console
kubectl describe gateway clustercontrol-gateway -n clustercontrol | grep -A8 Conditions:
```

All listeners should report `Programmed: True`.

## Upgrading an existing Ingress-NGINX release

Upgrading, rather than installing fresh, needs two extra steps — both consequences of Helm
behaviour rather than this chart:

* **Helm installs a chart's `crds/` only on install, never on upgrade.** NGF's own CRDs
  (`NginxProxy`, `NginxGateway`, `SnippetsFilter`) therefore need applying by hand.
* **NGF tags its cert-generator RBAC `helm.sh/hook: pre-install`**, which never fires on an
  upgrade, leaving the `pre-upgrade` Job without a ServiceAccount until it times out.

[`scripts/install-clustercontrol.sh`](../../scripts/install-clustercontrol.sh) handles both,
along with building the backend CA bundle. It is a convenience for this migration path only
— a fresh install needs nothing but the commands above.

## Helm chart dependencies

### If you already have Oracle MySQL Operator or a Gateway API implementation installed

```
helm install clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2 --debug \
  --set fqdn=clustercontrol.example.com --set installMysqlOperator=false --set gatewayController.enabled=false
```

This helm chart has certain dependencies that makes ClusterControl easier to install.
None of these is necessary if you provide your own equivalent or you already have it installed.

* oracle-mysql-operator
Oracle MySQL operator, required for running MySQL DB withing the k8s cluster.
```
installMysqlOperator: false
```

* oracle-mysql-innodbcluster
An MySQL Innodb cluster required for ClusterControl
```
createDatabases: false
```

* nginx-gateway-fabric
NGINX's Gateway API implementation. If you already have a Gateway API implementation
installed (Envoy Gateway, Istio, Cilium, Kong, Traefik, ...), disable the bundled one and
point `cmon.gateway.gatewayClassName` at your own `GatewayClass`:
```
gatewayController:
  enabled: false
```
Note that `templates/gateway.yaml`'s `SnippetsFilter` (response header rewriting) and
`TCPRoute` (kuber-proxy gRPC passthrough) are written against NGINX Gateway Fabric's
feature set — another implementation may need those reworked.
More information - https://github.com/nginx/nginx-gateway-fabric

### If you wish to use your own victoria metrics or other prometheus compatibile monitoring system

```
prometheusHostname: my-prometheus-server
monitoring:
  enabled: false
```

## Uninstall
```
helm uninstall clustercontrol
```

### Persistent resources
You might need to delete pvc created for the innodb database cluster manually.
```
kubectl delete pvc datadir-clustercontrol-0
```

### Dependent resources
```
kubectl delete innodbclusters.mysql.oracle.com clustercontrol
```

Gateway API CRDs are cluster-scoped and are **not** removed by `helm uninstall` — they may
be in use by other workloads.
