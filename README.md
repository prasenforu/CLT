## Observability
Observability for Multi Cluster Container Platform

Kubernetes multi-cluster observability using Cortex (Monitoring) Loki (Logging) & Tempo (Tracing).

<p align="center">
  <img src="https://github.com/prasenforu/CLT/blob/main/single/observability-mono.png">
</p>

### Quick start

- Central

```curl -s https://raw.githubusercontent.com/prasenforu/CLT/main/mono-setup.sh | bash```

- Edge

```curl -s https://raw.githubusercontent.com/prasenforu/CLT/main/mono-edge-setup.sh | INGIP=<Central Host IP> bash -s <Cluster Name>```

