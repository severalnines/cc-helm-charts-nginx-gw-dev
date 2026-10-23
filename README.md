# Severalnines helm-charts — NGINX Gateway Fabric

![Helm: v3](https://img.shields.io/static/v1?label=Helm&message=v3&color=informational&logo=helm)

> **Alternative, and not the official Helm Charts of Severalnines.** Use [severalnines/helm-charts](https://github.com/severalnines/helm-charts) for that.

Helm chart repository for the Ingress-NGINX → Gateway API migration. If you want to migrate away from Ingress-NGINX and retain NGINX, use this (it deploys [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric)). Otherwise, use the official chart linked above.

> **New to Kubernetes, Helm or this chart? Start with [HOW-TO-USE-ME.md](HOW-TO-USE-ME.md).** It is the
> learning guide for this repository. It takes one fresh Ubuntu 24.04 machine to a working
> ClusterControl with NGINX Gateway Fabric, and explains every layer on the way: kubeadm, networking,
> storage, MetalLB, Gateway API, Helm, the chart itself, day-2 operations and troubleshooting.

## Choose how to install

| You have… | Use | Guide |
|-----------|-----|-------|
| a fresh Ubuntu 24.04 machine (cloud VM, private cloud, bare metal, local VM) and no cluster | [docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh](docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh): builds a single-node cluster *and* installs ClusterControl | [HOW-TO-USE-ME.md](HOW-TO-USE-ME.md), [docs/scripts/README.md](docs/scripts/README.md) |
| an existing Kubernetes cluster (EKS, GKE, AKS, k3s, kubeadm…) | [scripts/install-clustercontrol.sh](scripts/install-clustercontrol.sh), or plain Helm as below | this page, [chart README](charts/clustercontrol/README.md) |

## Prerequisites

* A Kubernetes cluster you can access, and Helm v3
* The Gateway API CRDs installed on the cluster (one-time, cluster-wide). They are not shipped by any chart, see [charts/clustercontrol](charts/clustercontrol) for the command. [scripts/install-clustercontrol.sh](scripts/install-clustercontrol.sh) installs them for you.

## Add the chart helm repository

```console
helm repo add s9s-ngf https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/

helm repo update
```

## Install

```console
helm search repo s9s-ngf
helm install clustercontrol s9s-ngf/clustercontrol -n clustercontrol --create-namespace \
  --set fqdn=clustercontrol.example.com
```

Set `fqdn` to the name you will browse to: the Gateway only answers for that hostname. After the
pods are up, enable backend TLS, or `/` returns 400. See
[Backend TLS](charts/clustercontrol/README.md#backend-tls) in [charts/clustercontrol](charts/clustercontrol)
for that step and the rest of installation and configuration.

To install or upgrade in one step, use [scripts/install-clustercontrol.sh](scripts/install-clustercontrol.sh). It installs the CRDs and RBAC, installs or upgrades the Helm release, builds the backend CA bundle and switches backend TLS on, so the UI works with nothing left to do by hand. It adds its own helm repo alias, so it doesn't depend on the `s9s-ngf` one above.

```console
./scripts/install-clustercontrol.sh --fqdn clustercontrol.example.com
```

Pass `--fqdn` (and any `-f values.yaml`) again on every re-run; `--help` lists the other options.

## Learn how it works

[HOW-TO-USE-ME.md](HOW-TO-USE-ME.md) is the starting point. The learning path it links to:

1. [Concepts](docs/learn/01-concepts.md): containers, Kubernetes objects, kubeadm, CNI, storage, LoadBalancers, Helm, Gateway API
2. [The reference lab (Vagrant)](docs/learn/02-the-lab-vm.md): the environment the guide was tested on
3. [The install script, step by step](docs/learn/03-install-script-walkthrough.md)
4. [Inside the chart](docs/learn/04-inside-the-chart.md): templates, values, and one request traced from browser to cmon
5. [Day-2 operations](docs/learn/05-day-2-operations.md): inspect, upgrade, roll back, reinstall
6. [Troubleshooting](docs/learn/06-troubleshooting.md)
