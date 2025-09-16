# Observability and Monitoring in llm-d

Please join [SIG-Observability](https://github.com/llm-d/llm-d/blob/dev/SIGS.md#sig-observability) to contribute to monitoring and observability topics within llm-d.

## Enable Metrics Collection in llm-d Deployments

### Platform-Specific

- If running on Google Kubernetes Engine (GKE), refer to [Google Cloud Managed Prometheus documentation](https://cloud.google.com/stackdriver/docs/managed-prometheus)
  for guidance on how to collect metrics.
- If running on OpenShift, User Workload Monitoring provides an accessible Prometheus Stack for scraping metrics. See the
  [OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/configuring-user-workload-monitoring#enabling-monitoring-for-user-defined-projects_preparing-to-configure-the-monitoring-stack-uwm)
  to enable this feature.
- In other Kubernetes environments, Prometheus custom resources must be available in the cluster. To install a simple Prometheus and Grafana stack,
  refer to [prometheus-grafana-stack.md](./prometheus-grafana-stack.md).

### Helmfile Integration

Provided Prometheus custom resources exist in the cluster, all [llm-d guides](../../guides/README.md) include the option to enable Prometheus
PodMonitor creation for scraping vLLM metrics and ServiceMonitor creation for scraping EPP (Endpoint Picker Protocol) metrics.
With any llm-d helmfile example, update the values to enable monitoring:

### vLLM Metrics

```yaml
# In your ms-*/values.yaml files
decode:
  monitoring:
    podmonitor:
      enabled: true

prefill:
  monitoring:
    podmonitor:
      enabled: true
```

Upon installation, view prefill and/or decode podmonitors with:

```bash
kubectl get podmonitors -n my-llm-d-namespace
```

The vLLM metrics from prefill and decode pods will be visible from the Prometheus and/or Grafana user interface.

### EPP (Endpoint Picker Protocol) Metrics

EPP provides additional metrics for request routing, scheduling latency, and plugin performance. To enable EPP metrics collection:

**For Gateway API Inference Extension (GAIE) deployments of EPP:**

```yaml
# In your gaie-*/values.yaml files
inferenceExtension:
  monitoring:
    prometheus:
      enabled: true
```

Upon installation, view EPP servicemonitors with:

```bash
kubectl get servicemonitors -n my-llm-d-namespace
```

EPP metrics include request rates, error rates, scheduling latency, and plugin processing times, providing insights into the inference routing and scheduling performance.

## Dashboards

Grafana dashboard raw JSON files can be imported manually into a Grafana UI. Here is a current list of community dashboards:

- [llm-d dashboard](./grafana/dashboards/llm-d-dashboard.json)
  - vLLM metrics
- [inference-gateway dashboard](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/tools/dashboards/inference_gateway.json)
  - EPP pod metrics, requires additional setup to collect metrics. See [GAIE doc](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/tools/dashboards/README.md)

## PromQL Query Examples

For specific PromQL queries to monitor LLM-D deployments, see:

- [Example PromQL Queries](./example-promQL-queries.md) - Ready-to-use queries for monitoring vLLM, EPP, and prefix caching metrics

## Load Testing and Error Generation

To populate metrics (especially error metrics) for testing and monitoring validation:

- [Load Generation Script](./scripts/generate-load-llmd.sh) - Sends both valid and malformed requests to generate metrics

