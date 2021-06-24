## Observability
Observability for Multi Cluster Container Platform

Kubernetes multi-cluster observability using Cortex (Monitoring) Loki (Logging) & Tempo (Tracing).

<p align="center">
  <img src="https://github.com/cloudcafetech/observability/blob/main/observability-mono.png">
</p>

### Quick start

- Central

```curl -s https://raw.githubusercontent.com/cloudcafetech/observability/main/mono-setup.sh | bash```

- Edge

```curl -s https://raw.githubusercontent.com/cloudcafetech/observability/main/mono-edge-setup.sh | INGIP=<Central Host IP> bash -s <Cluster Name>```

