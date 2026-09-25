# Severalnines helm-charts — NGINX Gateway Fabric (development)

![Helm: v3](https://img.shields.io/static/v1?label=Helm&message=v3&color=informational&logo=helm)

Development chart repository for the Ingress-NGINX → Gateway API migration.

> **Not for production.** Use [severalnines/helm-charts](https://github.com/severalnines/helm-charts) for that.

## Add a chart helm repository
Access a Kubernetes cluster.

Add a chart helm repository with follow commands:

```console
helm repo add s9s-ngf https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/

helm repo update
```

See [charts/clustercontrol](charts/clustercontrol) for installation and configuration.
