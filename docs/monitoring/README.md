# Observability and Monitoring in llm-d

Please join [SIG-Observability](https://github.com/llm-d/llm-d/blob/main/SIGS.md#sig-observability) to contribute to monitoring and observability topics within llm-d.

## Enable Metrics Collection in llm-d Deployments

### Platform-Specific

- If running on Google Kubernetes Engine (GKE), 
  - Refer to [Google Cloud Managed Prometheus documentation](https://cloud.google.com/stackdriver/docs/managed-prometheus)
  for general guidance on how to collect metrics.
  - Enable [automatic application monitoring](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-automatic-application-monitoring) which will automatically collect metrics for vLLM.
  - GKE provides an out of box [inference gateway dashboard](https://cloud.google.com/kubernetes-engine/docs/how-to/customize-gke-inference-gateway-configurations#inference-gateway-dashboard).
- If running on OpenShift, User Workload Monitoring provides an accessible Prometheus Stack for scraping metrics. See the
  [OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/configuring-user-workload-monitoring#enabling-monitoring-for-user-defined-projects_preparing-to-configure-the-monitoring-stack-uwm)
  to enable this feature.
- In other Kubernetes environments, Prometheus custom resources must be available in the cluster. To install a simple Prometheus and Grafana stack,
  refer to [prometheus-grafana-stack.md](./prometheus-grafana-stack.md).

### Helmfile Integration

All [llm-d guides](../../guides/README.md) have monitoring enabled by default, supporting multiple monitoring stacks depending on the environment. We provide out of box monitoring configurations for scraping the [Endpoint Picker (EPP)](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/docs/proposals/004-endpoint-picker-protocol) metrics, and vLLM metrics.

See the vLLM Metrics and EPP Metrics sections below for how to further config or disable monitoring.

### vLLM Metrics

vLLM metrics collection is enabled by default with:

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

### EPP (Endpoint Picker) Metrics

EPP provides additional metrics for request routing, scheduling latency, and plugin performance. EPP metrics collection is enabled by default with:

* For self-installed Prometheus,

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

* For GKE managed Prometheus,

  ```yaml
  # In your gaie-*/values.yaml files
  inferenceExtension:
    monitoring:
      gke:
        enabled: true
  ```

EPP metrics include request rates, error rates, scheduling latency, and plugin processing times, providing insights into the inference routing and scheduling performance.

## Dashboards

Grafana dashboard raw JSON files can be imported manually into a Grafana UI. Here is a current list of community dashboards:

- [llm-d dashboard](./grafana/dashboards/llm-d-dashboard.json)
  - vLLM metrics
- [inference-gateway dashboard v1.0.1](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.0.1/tools/dashboards/inference_gateway.json)
  - EPP metrics
- [GKE managed inference gateway dashboard](https://cloud.google.com/kubernetes-engine/docs/how-to/customize-gke-inference-gateway-configurations#inference-gateway-dashboard)

### Enhanced Grafana Dashboard (llm-d-comprehensive-dashboard.json)

The [llm-d Comprehensive Dashboard](./grafana/dashboards/llm-d-comprehensive-dashboard.json) provides complete monitoring coverage with two tiers of metrics:

**Tier 1: Immediate Indicators (11 panels)**
- Overall Error Rate (platform-wide)
- Per-Model Error Rate
- Request Preemptions
- Overall Latency (P50/P90/P99)
- Model-Specific TTFT P99
- Model-Specific TPT P99
- Scheduler Health
- GPU Utilization
- Request Rate
- EPP E2E Latency P99
- Plugin Processing Latency

**Tier 2: Diagnostic Panels (15 panels)**
- Path A: Model Serving (5 panels) - KV cache, queue lengths, throughput, generation tokens, queue utilization
- Path B: Routing (4 panels) - Request/token distribution, idle GPU time, routing latency
- Path C: Prefix Caching (3 panels) - Cache hit rates (overall and per-instance), cache utilization
- Path D: P/D Disaggregation (3 panels) - Prefill/decode worker utilization, prefill queue length

**Features:**
- Namespace filtering with multi-select support and "All" option
- Model name filtering for focused analysis
- Works with all Prometheus-compatible data sources

**Import Instructions:**
1. Open Grafana UI and navigate to Dashboards
2. Click "New" > "Import"
3. Upload `grafana/dashboards/llm-d-comprehensive-dashboard.json`
4. Select your Prometheus data source
5. Click "Import"

### Perses Dashboard (llm-d-dashboard.yaml)

The [llm-d Perses Dashboard](./perses/llm-d-dashboard.yaml) provides basic monitoring with 6 core panels for teams using Perses as their observability platform:

**Core Metrics:**
- E2E Request Latency (P50, P90, P99)
- Token Throughput (prompt and generation tokens)
- Time Per Output Token Latency
- Scheduler State (running, waiting, swapped requests)
- Time To First Token Latency
- Cache Utilization (GPU and CPU)

**Features:**
- Namespace and model name filtering
- Compatible with Perses dashboard format
- Lightweight alternative to Grafana

**Import Instructions:**

*Via Perses UI:*
1. Open Perses UI and navigate to Dashboards
2. Click "Create" > "Import"
3. Upload `perses/llm-d-dashboard.yaml`
4. Verify datasource configuration matches your Prometheus endpoint
5. Click "Import"

*Via persesctl CLI:*
```bash
# Apply the dashboard to your Perses instance
persesctl apply -f docs/monitoring/perses/llm-d-dashboard.yaml

# Verify the dashboard was created
persesctl get dashboard llm-d-basic-monitoring -p default
```

## PromQL Query Examples

For specific PromQL queries to monitor LLM-D deployments, see:

- [Example PromQL Queries](./example-promQL-queries.md) - Ready-to-use queries for monitoring vLLM, EPP, and prefix caching metrics

## Load Testing and Error Generation

To populate metrics (especially error metrics) for testing and monitoring validation:

- [Load Generation Script](./scripts/generate-load-llmd.sh) - Sends both valid and malformed requests to generate metrics

## Troubleshooting

### "No Data" in Dashboard Panels

**Scenario 1: Metric Not Available**
- **Cause**: The metric has not been emitted yet or the component is not running
- **Solution**:
  - Verify pods are running: `kubectl get pods -n <namespace>`
  - Check PodMonitors/ServiceMonitors are deployed: `kubectl get podmonitors,servicemonitors -n <namespace>`
  - Verify metrics endpoint is accessible: `kubectl port-forward <pod-name> 8080:8080` and check `http://localhost:8080/metrics`

**Scenario 2: Wrong Namespace Selected**
- **Cause**: Dashboard namespace filter doesn't match where metrics are being collected
- **Solution**:
  - Check the namespace variable at the top of the dashboard
  - Select "All" to view metrics from all namespaces
  - Verify your deployment namespace matches the filter

### Missing EPP Metrics

EPP (Endpoint Picker Protocol) metrics require the Gateway API Inference Extension (GAIE) deployment.

**Symptoms:**
- Empty panels for: Scheduler Health, EPP E2E Latency, Plugin Processing Latency
- Missing `inference_extension_*` and `inference_model_*` metrics

**Solution:**
- Deploy GAIE following the [installation guide](../../guides/README.md)
- Enable EPP monitoring in your `gaie-*/values.yaml`:
  ```yaml
  inferenceExtension:
    monitoring:
      prometheus:
        enabled: true
  ```
- Verify ServiceMonitor is created: `kubectl get servicemonitors -n <namespace>`

### Missing GPU Metrics

GPU utilization metrics require DCGM Exporter or equivalent GPU monitoring.

**Symptoms:**
- Empty "GPU Utilization" panel
- Missing `DCGM_FI_DEV_GPU_UTIL` or `nvidia_gpu_duty_cycle` metrics

**Solution:**
- Install DCGM Exporter in your cluster
- For GKE with GPU monitoring enabled, metrics should be available automatically
- Verify GPU metrics are being scraped by Prometheus

### Namespace Selection Issues

**Problem**: Multi-select namespace filter shows no data

**Solutions:**
- Click "All" to select all namespaces
- Manually select specific namespaces where llm-d is deployed
- Verify the namespace label exists in your metrics: query `up{namespace=~".*"}` in Prometheus
- Check that your Prometheus scrape configs include namespace labels

### Metric Name Variations

Some deployments may have different metric naming conventions:

**GAIE Metrics:**
- Older versions: `inference_model_*` (e.g., `inference_model_request_total`)
- Newer versions: `inference_objective_*` (e.g., `inference_objective_request_total`)

**Solution:**
If queries return no data, try the alternative metric name pattern. Update dashboard queries as needed to match your deployment's metric naming convention.

