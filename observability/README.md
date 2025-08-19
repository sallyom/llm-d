# Observability in llm-d 

Please join [SIG-Observability](../SIGS.md#sig-observability) to contribute to monitoring and observability topics within llm-d.

## Enable Metrics Collection in llm-d Deployments

To collect metrics from llm-d using the llm-d community's helm charts, Prometheus custom resources must be available
in the cluster. Here are a few options for installing and accessing the necessary Prometheus resources:

1. To install a simple Prometheus and Grafana stack, refer to [prometheus-grafana-stack.md](./prometheus-grafana-stack.md).
2. User Workload Monitoring enabled on OpenShift provides an accessible Prometheus Stack for scraping metrics.
   - See the [OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/configuring-user-workload-monitoring#enabling-monitoring-for-user-defined-projects_preparing-to-configure-the-monitoring-stack-uwm) to enable this feature
3. Utilize an existing Prometheus stack. Check for the existence of Prometheus and metrics collection custom resources in your Kuberenetes cluster.
   If they don't exist, reach out to a cluster administrator.

If you have access to Prometheus with PodMonitors and ServiceMonitors, the [llm-d well-lit paths](https://github.com/llm-d-incubation/llm-d-infra/tree/main/quickstart/examples)
include the option to enable PodMonitors for scraping vLLM metrics.

**Note:** Google Kubernetes Engine (GKE) uses PodMonitoring resources instead of standard PodMonitors/ServiceMonitors. If using GKE, refer to the [Google Cloud Managed Prometheus documentation](https://cloud.google.com/stackdriver/docs/managed-prometheus) for metrics collection and migration guidance.

With any llm-d quickstart well-lit path, update the modelservice values
to enable monitoring:

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
kubectl get podmonitors -A
```

The vLLM metrics from prefill and decode pods will be visible from the Prometheus UI and/or Grafana UI.

### Grafana Dashboards (optional)

Grafana dashboard raw JSON files can be imported manually into a Grafana UI. Here is a current list of community dashboards:

- [llm-d dashboard](./dashboards/grafana/llm-d-dashboard.json)
  - vLLM metrics
- [inference-gateway dashboard](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/tools/dashboards/inference_gateway.json)
  - EPP pod metrics, requires additional setup to collect metrics. See [GAIE doc](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/tools/dashboards/README.md) 
