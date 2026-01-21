# Distributed Tracing for llm-d

This guide explains how to enable OpenTelemetry distributed tracing across llm-d deployments.

## Prerequisites

1. An OpenTelemetry Collector deployed in your cluster (see [Collector Configuration](#opentelemetry-collector-configuration) below)
2. A tracing backend (e.g., Jaeger, Tempo, or a managed service)

## Overview

llm-d deployments consist of multiple components that support distributed tracing:

1. **Gateway API Inference Extension (GAIE/EPP)** - Routes requests and scores endpoints
2. **[Tracing coming soon] KV Cache Manager** - Embedded in the llm-d-inference-scheduler image, provides cache-aware scoring
3. **[Tracing coming soon] P/D Sidecar** - Embedded in the llm-d-inference-scheduler image, routes prefill/decode requests
4. **vLLM** - LLM serving engine with built-in tracing support

Refer to the distributed tracing proposal for details on spans and implementation. <!-- TODO: Add actual URL when proposal merges -->

## Enabling Tracing

llm-d makes it easy to enable distributed tracing across all components with a single global configuration. Tracing is **disabled by default** and can be enabled at the guide level.

### Quick Start

**Step 1: Enable tracing in your guide**

Edit your guide's values file and set `enabled: true`:

```yaml
# For Model Service deployments (ms-*/values.yaml)
global:
  tracing:
    enabled: true  # Just flip this switch!
    # otlpEndpoint defaults to http://opentelemetry-collector.monitoring.svc.cluster.local:4317
```

```yaml
# For Gateway/EPP deployments (gaie-*/values.yaml)
inferenceExtension:
  tracing:
    enabled: true  # Just flip this switch!
    # otelExporterEndpoint defaults to http://opentelemetry-collector.monitoring.svc.cluster.local:4317
```

**Step 2: Deploy with helmfile**

```bash
helmfile apply
```

If you need to override the default collector endpoint, edit the `otlpEndpoint` or `otelExporterEndpoint` field in your values file before deploying.

That's it! All components will automatically export traces to your OpenTelemetry Collector.

### What Gets Traced

When you enable `global.tracing.enabled: true` in model service values:

- ✅ **vLLM decode instances** - Automatically receive tracing environment variables and command-line arguments
- ✅ **vLLM prefill instances** - Automatically receive tracing environment variables and command-line arguments
- ✅ **Routing proxy sidecar** - [Tracing coming soon] Automatically receives tracing environment variables

When you enable `inferenceExtension.tracing.enabled: true` in gateway values:

- ✅ **Gateway API Inference Extension (EPP)** - Exports request routing and endpoint scoring traces

### Configuration Reference

#### Global Tracing Options (Model Service)

Add this to your model service values file (e.g., `ms-*/values.yaml`):

```yaml
global:
  tracing:
    # Enable/disable tracing across all components
    enabled: true

    # OpenTelemetry Collector gRPC endpoint
    # Edit this value to point to your collector
    # Default: http://opentelemetry-collector.monitoring.svc.cluster.local:4317
    otlpEndpoint: "http://opentelemetry-collector.monitoring.svc.cluster.local:4317"

    # Sampling configuration
    sampling:
      # Sampler type: "parentbased_traceidratio", "always_on", "always_off"
      sampler: "parentbased_traceidratio"
      # Sampling ratio: 1.0 = 100% (demo/debug), 0.1 = 10% (production)
      samplerArg: "1.0"

    # Customize service names (optional)
    serviceNames:
      vllmDecode: "vllm-decode"
      vllmPrefill: "vllm-prefill"
      routingProxy: "llm-d-pd-proxy"

    # vLLM-specific tracing options
    vllm:
      # Detail level: "all", "model", "scheduler"
      collectDetailedTraces: "all"
```

#### Gateway Tracing Options

Add this to your gateway values file (e.g., `gaie-*/values.yaml`):

```yaml
inferenceExtension:
  tracing:
    enabled: true
    # Edit this value to point to your collector
    # Default: http://opentelemetry-collector.monitoring.svc.cluster.local:4317
    otelExporterEndpoint: "http://opentelemetry-collector.monitoring.svc.cluster.local:4317"
    sampling:
      sampler: "parentbased_traceidratio"
      samplerArg: "1.0"
```

### Environment Variables Injected

When tracing is enabled, the following environment variables are automatically injected:

**For vLLM containers:**
- `OTEL_SERVICE_NAME` - Service identifier (e.g., "vllm-decode", "vllm-prefill")
- `OTEL_EXPORTER_OTLP_ENDPOINT` - Collector endpoint URL
- `OTEL_TRACES_EXPORTER` - Set to "otlp"
- `OTEL_TRACES_SAMPLER` - Sampler type
- `OTEL_TRACES_SAMPLER_ARG` - Sampling ratio

**vLLM command-line arguments:**
- `--otlp-traces-endpoint` - Collector endpoint
- `--collect-detailed-traces` - Detail level (e.g., "all")

### Custom Commands (Advanced)

If you're using `modelCommand: custom` with a custom shell script, tracing args are **not** injected automatically. You must add them manually:

```yaml
decode:
  containers:
  - name: vllm
    modelCommand: custom
    command: ["/bin/sh", "-c"]
    args:
      - |
        vllm serve model/name \
        --host 0.0.0.0 \
        --port 8000 \
        # Add tracing args manually for custom commands:
        # --otlp-traces-endpoint http://opentelemetry-collector.monitoring.svc.cluster.local:4317 \
        # --collect-detailed-traces all
    env:
      # Add tracing env vars manually for custom commands:
      # - name: OTEL_SERVICE_NAME
      #   value: "vllm-custom"
```

Uncomment the tracing lines when you want to enable tracing.

### Disabling Tracing

To disable tracing, set `enabled: false`:

```yaml
global:
  tracing:
    enabled: false
```

When disabled, no tracing environment variables or command-line arguments are injected.

### Changing the Collector Endpoint

To configure a custom OpenTelemetry Collector endpoint, edit the values file directly:

**For Model Service deployments (ms-*/values.yaml):**

```yaml
global:
  tracing:
    enabled: true
    # Edit this to point to your collector
    otlpEndpoint: "http://my-collector.observability.svc.cluster.local:4317"
```

**For Gateway/EPP deployments (gaie-*/values.yaml):**

```yaml
inferenceExtension:
  tracing:
    enabled: true
    # Edit this to point to your collector
    otelExporterEndpoint: "http://my-collector.observability.svc.cluster.local:4317"
```

**Default Endpoint**

The default endpoint is:
```
http://opentelemetry-collector.monitoring.svc.cluster.local:4317
```

### Production Sampling

For production deployments, use lower sampling rates to reduce overhead:

```yaml
global:
  tracing:
    enabled: true
    sampling:
      samplerArg: "0.1"  # 10% sampling
```

For demo or debugging, use 100% sampling:

```yaml
global:
  tracing:
    enabled: true
    sampling:
      samplerArg: "1.0"  # 100% sampling
```

### Overriding Per-Component

You can override global tracing settings for specific components:

```yaml
global:
  tracing:
    enabled: true
    serviceNames:
      vllmDecode: "vllm-decode"

decode:
  containers:
  - name: vllm
    env:
      # Override the service name for this specific decode instance
      - name: OTEL_SERVICE_NAME
        value: "my-special-decode-instance"
```

## OpenTelemetry Collector Configuration

### Recommended Filters

**IMPORTANT**: When using OpenTelemetry Collector with llm-d, you **must** configure filters to drop traces generated by Prometheus scraping `/metrics` endpoints. Without these filters, metrics collection will flood your tracing backend with high-volume, low-value trace spans.

**Note**: This drops **trace spans** of Prometheus scraping, NOT the metrics themselves. Your metrics pipeline (e.g., OpenShift workload monitoring, Prometheus) continues to collect metrics normally. The traces and metrics pipelines are completely separate.

Add these processors to your OpenTelemetry Collector configuration:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: llm-d-collector
  namespace: monitoring  # Or your preferred namespace
spec:
  config:
    processors:
      # Filter out trace spans generated by Prometheus scraping /metrics
      # This does NOT affect metrics collection - only drops traces of scraping
      filter/drop-metrics-scraping:
        error_mode: ignore
        traces:
          span:
            # Drop trace spans from Prometheus/OpenShift monitoring scraping /metrics
            - 'attributes["url.path"] == "/metrics"'
            - 'attributes["http.route"] == "/metrics"'
            - 'attributes["http.target"] == "/metrics"'
            - 'attributes["http.url"] == "/metrics"'
            - name == "GET /metrics"
            - name == "GET"

      # Batch spans for efficient export
      batch:
        send_batch_max_size: 2048
        send_batch_size: 1024
        timeout: 1s

    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: '0.0.0.0:4317'
          http:
            endpoint: '0.0.0.0:4318'

    exporters:
      # Configure your backend here (Jaeger, Tempo, etc.)
      debug:
        verbosity: basic

    service:
      pipelines:
        traces:
          receivers:
            - otlp
          processors:
            - filter/drop-metrics-scraping  # Apply filter BEFORE batching
            - batch
          exporters:
            - debug  # Replace with your backend exporter
```

### Why These Filters Are Needed

**Understanding the Two Pipelines:**

llm-d components expose `/metrics` endpoints for Prometheus/OpenShift workload monitoring. When you have both metrics collection AND tracing enabled:

```
┌─────────────────────────────────────────────────────────────┐
│  llm-d Component (vLLM, EPP, routing proxy)                │
│  - Exposes /metrics endpoint                                │
│  - Has OTEL auto-instrumentation enabled                    │
└─────────────────────────────────────────────────────────────┘
           │                                  │
           │ HTTP GET /metrics                │ OTLP traces
           │ (for metrics)                    │ (for tracing)
           ▼                                  ▼
    ┌──────────────┐                  ┌──────────────┐
    │  Prometheus  │                  │ OTEL         │
    │  (OpenShift  │                  │ Collector    │
    │  monitoring) │                  │              │
    └──────────────┘                  └──────────────┘
           │                                  │
           │ Metrics data                     │ Trace spans
           ▼                                  ▼
    ┌──────────────┐                  ┌──────────────┐
    │  Prometheus  │                  │  Tempo/      │
    │  Storage     │                  │  Jaeger      │
    └──────────────┘                  └──────────────┘
```

**The Problem:**

When Prometheus scrapes `/metrics` (left pipeline), the HTTP request ALSO generates a trace span (right pipeline) because auto-instrumentation captures ALL HTTP requests. This causes:

1. **High Volume**: Scrapes happen every 15-30 seconds per pod → 100s of trace spans per minute
2. **Low Value**: These GET requests represent monitoring overhead, not actual inference workload
3. **Noise**: They obscure meaningful request traces (inference, routing) in your tracing backend

**The Solution:**

Filter out the trace spans representing metrics scraping. This only affects the **traces pipeline** (right side). Your **metrics pipeline** (left side) continues working normally - Prometheus still collects metrics.

**Multiple Filter Patterns:**

The filters match multiple patterns because different components use different OpenTelemetry semantic conventions:
- `url.path` - Modern semantic convention (HTTP server spans)
- `http.route`, `http.target`, `http.url` - Legacy HTTP conventions
- Span names like "GET /metrics" and "GET" - vLLM and proxy patterns

### Minimal Example for Testing

For quick testing with a local backend like Jaeger:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: llm-d-collector
  namespace: monitoring
spec:
  mode: deployment
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: '0.0.0.0:4317'

    processors:
      filter/drop-metrics-scraping:
        error_mode: ignore
        traces:
          span:
            - 'attributes["url.path"] == "/metrics"'
            - name == "GET /metrics"
      batch: {}

    exporters:
      otlp:
        endpoint: "jaeger-collector.monitoring.svc.cluster.local:4317"
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [filter/drop-metrics-scraping, batch]
          exporters: [otlp]
```

### Verifying Filter Configuration

After deploying your collector with filters:

1. **Check collector logs** for dropped spans:
   ```bash
   kubectl logs -n monitoring deployment/llm-d-collector-collector | grep -i filter
   ```

2. **Query your tracing backend** - You should NOT see traces for:
   - Span name: "GET /metrics"
   - URL path: "/metrics"

3. **You SHOULD see traces for**:
   - vLLM inference requests (e.g., "/v1/completions", "/v1/chat/completions")
   - EPP/GAIE request routing spans
   - Routing proxy spans

## Additional Resources

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [llm-d Distributed Tracing Proposal](../../proposals/distributed-tracing.md)
- [GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
