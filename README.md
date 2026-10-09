# Severalnines helm-charts — NGINX Gateway Fabric (development)

![Helm: v3](https://img.shields.io/static/v1?label=Helm&message=v3&color=informational&logo=helm)

> **Alternative, and not the official Helm Charts of Severalnines.** Use [severalnines/helm-charts](https://github.com/severalnines/helm-charts) for that.

Helm chart repository for the Ingress-NGINX → Gateway API migration. If you want to migrate away from Ingress-NGINX and retain NGINX, use this (it deploys [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric)). Otherwise, use the official chart linked above.

## Prerequisites

* A Kubernetes cluster you can access, and Helm v3
* The Gateway API CRDs installed on the cluster (one-time, cluster-wide). They are not shipped by any chart, see [charts/clustercontrol](charts/clustercontrol) for the command. [scripts/install-clustercontrol.sh](scripts/install-clustercontrol.sh) installs them for you.

## Add the chart helm repository

```console
helm repo add s9s-ngf https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/

helm repo update
```

> **Note:** chart versions here are prereleases (e.g. `0.4.0-ngf.2`). Helm hides prereleases unless you ask for them, so pass `--devel` or an explicit `--version`:
>
> ```console
> helm search repo s9s-ngf --devel
> helm install clustercontrol s9s-ngf/clustercontrol --version 0.4.0-ngf.2 -n clustercontrol --create-namespace
> ```

## Install

See [charts/clustercontrol](charts/clustercontrol) for installation and configuration.

To install or upgrade in one step (CRDs, RBAC and the Helm release), use [scripts/install-clustercontrol.sh](scripts/install-clustercontrol.sh). It adds its own helm repo alias, so it doesn't depend on the `s9s-ngf` one above.
