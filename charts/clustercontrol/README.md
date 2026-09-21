# ClusterControl helm-chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/clustercontrol)](https://artifacthub.io/packages/helm/severalnines/clustercontrol)
![Helm: v3](https://img.shields.io/static/v1?label=Helm&message=v3&color=informational&logo=helm)
[![Slack](https://img.shields.io/badge/Join_Slack-%23sovereign_dbaas-purple)](https://sovereign-dbaas.slack.com/join/shared_invite/zt-b15k9477-jLllD6qJOUm3bGnOWynVig)

# Dependencies
This helm chart is designed to provide everything you need to get ClusterControl running in a vanila kubernetes cluster.
This includes dependencies like
* NGINX Gateway Fabric (Gateway API implementation)
* mysql operator and innodbcluster
* victoria metrics

If you do not wish to install any of those, please see [Dependencies](#helm-chart-dependencies) below.

## Gateway API prerequisite
Unlike the old nginx Ingress controller, a Gateway API implementation only works once the
Gateway API CRDs are present in the cluster - this chart does **not** install them (they're
cluster-scoped and shared across every chart/tenant on the cluster, so installing them from
here would risk clobbering a version someone else already relies on). Install them once per
cluster, **before** `helm install`/`upgrade`:

```console
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/experimental?ref=v2.6.7" | kubectl apply --server-side --force-conflicts -f -
```

Two details matter here:

* Use the **experimental** channel, not standard - `TCPRoute`, used for kuber-proxy's gRPC
  port, only exists there.
* `--server-side` is **required**. Client-side apply stores the whole manifest in the
  `kubectl.kubernetes.io/last-applied-configuration` annotation, and the `httproutes` schema
  exceeds the 256KiB annotation limit (`metadata.annotations: Too long`).

Verify (expect 12):

```console
kubectl get crd | grep gateway.networking | wc -l
```

### Enabling the gateway on an existing release

Helm installs a chart's `crds/` directory only on `helm install`, **never on
`helm upgrade`**. If you are switching an already-deployed release from the old nginx Ingress
controller to the gateway, NGINX Gateway Fabric's own CRDs (`NginxProxy`, `NginxGateway`,
`SnippetsFilter`) therefore never get created, and the upgrade fails with
`no matches for kind "NginxGateway" in version "gateway.nginx.org/v1alpha1"`.

Apply them by hand after `helm dependency build`:

```console
tar -xzf charts/clustercontrol/charts/nginx-gateway-fabric-2.6.7.tgz -C /tmp nginx-gateway-fabric/crds
kubectl apply --server-side --force-conflicts -f /tmp/nginx-gateway-fabric/crds/
```

The same upgrade path misses NGF's cert-generator RBAC, which upstream tags
`helm.sh/hook: pre-install` only - a hook that never fires on upgrade. Without it the
`pre-upgrade` cert-generator Job has no ServiceAccount and hangs until it times out. Create
the `ServiceAccount`, `Role` and `RoleBinding` named
`<release>-nginx-gateway-fabric-cert-generator` before upgrading. Fresh installs need neither
workaround.

## TLS

### Frontend certificate

The `Gateway`'s HTTPS listener needs a certificate. Unlike the old nginx Ingress controller -
which silently fell back to a built-in certificate when the named Secret was missing - Gateway
API reports `InvalidCertificateRef` and refuses to serve without one.

The chart handles this automatically, in one of two ways:

* **`cmon.gateway.ssl.clusterIssuer` set** - the `Gateway` is annotated and cert-manager
  issues the certificate (it watches `Gateway` resources directly since 1.15). The chart
  generates nothing.
* **`clusterIssuer` empty (default)** - the chart issues a self-signed certificate covering
  `.Values.fqdn` into the Secret named by `cmon.gateway.ssl.secretName` (default `cmon-cert`).

An existing Secret is always reused, so upgrades never rotate the certificate. Add the node
or LoadBalancer address if you also reach the gateway by IP:

```yaml
cmon:
  gateway:
    ssl:
      selfSigned:
        extraIPs:
          - 192.168.40.12
```

Self-signed certificates are untrusted by browsers. Import it on the client, or the browser
rejects the handshake (visible in the gateway log as `alert certificate unknown:SSL alert
number 46`):

```console
kubectl get secret cmon-cert -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d > ca.crt
sudo cp ca.crt /usr/local/share/ca-certificates/clustercontrol.crt && sudo update-ca-certificates
# Chrome on Linux uses its own NSS store (apt install libnss3-tools):
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n clustercontrol -i ca.crt
```

### Backend TLS

`cmon.gateway.backendTLS` replaces the old
`nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` annotation on the ccmgr (19051) and
cmon (9501) routes. It is **disabled by default**, because it cannot simply be switched on:
the old annotation encrypted the connection without verifying anything, whereas Gateway API's
`BackendTLSPolicy` always validates the backend certificate, hostname included, and has no
skip-verify mode.

Both backends present self-signed certificates, so each is trusted as its own CA, and both go
into a single bundle. The two differ in where the certificate comes from:

* **ccmgr (19051)** - its stock certificate has *no* CN and *no* SAN
  (`subject=O = Severalnines AB`), so nothing can verify it and `/` returns 502. **The chart
  fixes this for you**: it issues a certificate with `SAN: DNS:localhost`, and the
  `init-ccmgr` container copies it over `/usr/share/ccmgr/server.crt` on every pod start.
  That works on existing installs too, because `ccmgr.yaml` already points `tls_cert` there
  and `ccmgradm init` does not re-run once that file exists. Disable with
  `cmon.gateway.backendTLS.provisionCcmgrCert=false` if you manage the file yourself.
* **cmon (9501)** - cmon generates this one itself at runtime, declaring
  `SAN: IP:0.0.0.0, DNS:localhost`. That is why the policy validates against `localhost`.
  The chart cannot know it in advance, so it must be extracted per install.

Build the bundle from the chart's ccmgr certificate plus cmon's runtime one:

```console
# ccmgr's - issued by the chart
kubectl get secret <release>-ccmgr-tls -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ccmgr.crt

# cmon's - generated at runtime, so read it off the live listener
kubectl port-forward -n <namespace> svc/cmon-master 9501:9501 &
openssl s_client -connect localhost:9501 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > cmon-9501.crt
kill %1

# trust both (the key MUST be named ca.crt - the Gateway API spec mandates it)
cat cmon-9501.crt ccmgr.crt > ca-bundle.crt
kubectl create configmap cmon-backend-ca -n <namespace> --from-file=ca.crt=ca-bundle.crt
```

Then enable it:

```console
helm upgrade ... \
  --set cmon.gateway.backendTLS.enabled=true \
  --set cmon.gateway.backendTLS.caCertificateRef=cmon-backend-ca
```

cmon regenerates its certificate whenever `cmon-master` is recreated, so the bundle needs
refreshing if that pod is replaced.

`backendTLS` defaults to disabled only because it cannot be switched on without the bundle
above - **it is not optional in practice**. Both ccmgr (19051) and cmon (9501) are TLS-only
listeners, so with it disabled the gateway proxies plain HTTP to them and they reject it:
`/` returns `400 Client sent an HTTP request to an HTTPS server` and `/cmon/*` returns 500.

## Exposing the gateway

NGINX Gateway Fabric provisions the data-plane `Service` as `type: LoadBalancer`. On k3s that
works out of the box (klipper-lb); on a cluster with no LoadBalancer provider it stays
`<pending>` forever. Bind the ports on the node instead:

```yaml
nginx-gateway-fabric:
  nginx:
    container:
      hostPorts:
        - port: 80
          containerPort: 80
        - port: 443
          containerPort: 443
        - port: 50051
          containerPort: 50051
```

`hostPorts` binds `0.0.0.0`, covering every interface - preferable to `externalIPs`, which
binds a single address and will miss traffic arriving on any other NIC. It requires the CNI
`portmap` plugin; without it, fall back to patching `externalIPs` onto the Service through
`nginx.service.patches`. On multi-node clusters use a real load balancer such as MetalLB.

# Install

## Add a S9s helm repository

Add a chart helm repository with follow commands:

```console
helm repo add s9s https://severalnines.github.io/helm-charts/
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
helm install clustercontrol s9s/clustercontrol
```

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

Providing cmon.sshKeysSecretName value with our secret name created above

```
helm upgrade --install clustercontrol s9s/clustercontrol --set cmon.sshKeysSecretName=my-ssh-keys
```

## Custom configuration via values.yaml

### Create your own values.yaml

Look at the `values.yaml` and create your own file with proper overrides.

```
helm show values s9s/clustercontrol > values.yaml
```

### Install / Upgrade using your custom values.yaml

```
helm install clustercontrol s9s/clustercontrol -f values.yaml
```

## Notes
cmon API is accessible within the cluster via cmon-master:9501

ClusterControl V2 is accessible within the cluster via cmon-master:3000

Is is *HIGHLY* recommended to use the Gateway as ClusterControl V2 requires cmon API to be exposed and available externaly.


## Access UI (Gateway API)
If you enabled the bundled NGINX Gateway Fabric, wait for its Service to get an external IP/hostname:

```bash
kubectl get svc -n clustercontrol clustercontrol-nginx-gateway-fabric
```

Then set `fqdn` to a DNS name that resolves to that IP. For quick testing you can use nip.io:

```bash
helm upgrade --install clustercontrol s9s/clustercontrol --set fqdn=<external-ip>.nip.io
```


## Helm chart dependencies

### If you already have Oracle MySQL Operator or a Gateway API implementation installed

```
helm install clustercontrol s9s/clustercontrol --debug --set fqdn=clustercontrol.example.com --set installMysqlOperator=false --set gatewayController.enabled=false
```

This helm chart has certain dependencies that makes ClusterControl easier to install.
None of these is necessary if you provide your own equivalent or you already have it installed.

* oracle-mysql-operator
Oracle MySQL operator, required for running MySQL DB withing the k8s cluster.
You can disable this by setting
```
installMysqlOperator: false
```

* oracle-mysql-innodbcluster
An MySQL Innodb cluster required for ClusterControl
You can disable this by setting
```
createDatabases: false
```
But you will need to provide a different MySQL / MariaDB or compatibile for ClusterControl to use.
For exact documentation refer to the official helm chart documentation
https://github.com/mysql/mysql-operator/blob/trunk/helm/mysql-innodbcluster/values.yaml

* nginx-gateway-fabric
NGINX's Gateway API implementation (the migration target recommended alongside Ingress-NGINX's
retirement - see https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/). You need
a Gateway API implementation to access ClusterControl.
If you already have one installed or wish to use a different one (Envoy Gateway, Istio, Cilium,
Kong, Traefik, ...), you can disable the bundled one by
```
gatewayController:
  enabled: false
```
and pointing `cmon.gateway.gatewayClassName` at your own `GatewayClass`. Note that
`templates/gateway.yaml`'s `SnippetsFilter` (response header rewriting) and its
`TCPRoute` (kuber-proxy gRPC passthrough) are written against NGINX Gateway Fabric's supported
feature set - swapping the implementation may require reworking those two resources.
More information - https://github.com/nginx/nginx-gateway-fabric

### If you wish to use your own victoria metrics or other prometheus compatibile monitoring system

* victoria-metrics-single
https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-metrics-single#parameters
These defaults provide minimal needed for ClusterControl metrics and dashboards to work
Feel free to adjust as needed, however keep in mind required labels and annotations and service discovery.
If you already have your own VictoriaMetrics or Prometheus cluster and don't want to install this, you can disable by setting
```
prometheusHostname: my-prometheus-server
monitoring:
  enabled: false
```

## Uninstall
To uninstall ClusterControl from your kubernetes cluster simply run
```
helm uninstall clustercontrol
```

### Persistent resources
You might need to delete pvc created for the innodb database cluster manually.
To do so, simply run
```
kubectl delete pvc datadir-clustercontrol-0
```

### Dependent resources
Although, uninstall **should** remove every dependency created by this helm chart, sometimes the database cluster hang. To clean up, try removing them manualy by running
```
kubectl delete innodbclusters.mysql.oracle.com clustercontrol
```

or editing above resource and removing finalizers.