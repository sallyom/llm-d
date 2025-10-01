# vLLM OpenTelemetry Instrumentation Guide

## Overview

This configuration enables **hybrid tracing** for vLLM, combining:
- **OpenTelemetry Operator Auto-Instrumentation**: FastAPI, HTTP clients, async operations
- **vLLM Custom Tracing**: LLM-specific spans with token counts, latencies, and performance metrics

## Quick Start

### 1. Apply the Instrumentation CR
```bash
kubectl apply -f vllm-instrumentation.yaml
```

### 2. Deploy Your vLLM Application
The example deployment in the YAML includes the necessary annotation:
```yaml
annotations:
  instrumentation.opentelemetry.io/inject-python: "vllm-instrumentation"
```

### 3. Verify Tracing is Working

**Check auto-instrumentation injection:**
```bash
kubectl logs deployment/vllm-server | grep -i "opentelemetry"
```

**Verify spans are generated:**
- FastAPI spans for HTTP requests
- vLLM custom spans for LLM operations
- Combined traces in your collector (Jaeger/OTLP)

## Configuration Options

### Collector Endpoints

**Jaeger (gRPC):**
```yaml
endpoint: http://jaeger-collector.observability.svc.cluster.local:4317
```

**Jaeger (HTTP):**
```yaml
endpoint: http://jaeger-collector.observability.svc.cluster.local:4318/v1/traces
env:
  - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
    value: "http/protobuf"
```

**External OTLP Endpoint:**
```yaml
endpoint: https://your-external-otlp-endpoint.com:4317
env:
  - name: OTEL_EXPORTER_OTLP_TRACES_INSECURE
    value: "false"
```

### Sampling Configuration

**Production (10% sampling):**
```yaml
sampler:
  type: parentbased_traceidratio
  argument: "0.1"
```

**Debug (100% sampling):**
```yaml
sampler:
  type: parentbased_traceidratio
  argument: "1.0"
```

### vLLM Custom Tracing Options

**Basic tracing (default spans only):**
```bash
--otlp-traces-endpoint=http://jaeger-collector.observability.svc.cluster.local:4317
```

**Detailed tracing (model + worker spans):**
```bash
--otlp-traces-endpoint=http://jaeger-collector.observability.svc.cluster.local:4317
--collect-detailed-traces=all
```

**Selective detailed tracing:**
```bash
--collect-detailed-traces=model,worker
```

## Expected Trace Structure

With this configuration, you'll see traces containing:

### 1. FastAPI Spans (from auto-instrumentation)
- HTTP request/response spans
- Request validation and routing
- Middleware execution
- Response serialization

### 2. HTTP Client Spans (from auto-instrumentation)
- Outbound HTTP requests (if any)
- OpenAI API calls (if using external APIs)
- Internal service communication

### 3. vLLM Custom Spans
- **Request Processing**: End-to-end request handling
- **Token Metrics**: Prompt and completion token counts
- **Latency Metrics**: Queue time, first token time, generation time
- **Model Execution**: Forward pass timing (if detailed tracing enabled)

### 4. Span Attributes
```
gen_ai.request.id
gen_ai.usage.prompt_tokens
gen_ai.usage.completion_tokens
gen_ai.latency.time_in_queue
gen_ai.latency.time_to_first_token
gen_ai.latency.e2e
gen_ai.request.temperature
gen_ai.request.max_tokens
http.method
http.url
http.status_code
```

## Troubleshooting

### Auto-Instrumentation Not Working

**Check operator logs:**
```bash
kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-operator
```

**Verify instrumentation injection:**
```bash
kubectl get pods -o yaml | grep -A 10 -B 10 "opentelemetry"
```

### vLLM Custom Spans Missing

**Check vLLM logs for tracing initialization:**
```bash
kubectl logs deployment/vllm-server | grep -i "trac\|otel"
```

**Verify OTLP endpoint is reachable:**
```bash
kubectl exec -it deployment/vllm-server -- curl -v http://jaeger-collector.observability.svc.cluster.local:4317
```

### Performance Issues

**Reduce sampling:**
```yaml
sampler:
  argument: "0.01"  # 1% sampling
```

**Adjust batch processing:**
```yaml
env:
  - name: OTEL_BSP_MAX_QUEUE_SIZE
    value: "1024"
  - name: OTEL_BSP_SCHEDULE_DELAY
    value: "10000"
```

## Integration with Existing Services

### Adding to Existing Deployments

Simply add the annotation to any existing deployment:
```bash
kubectl patch deployment your-vllm-deployment -p '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-python":"vllm-instrumentation"}}}}}'
```

### Multi-Container Pods

Specify which container to instrument:
```yaml
annotations:
  instrumentation.opentelemetry.io/inject-python: "vllm-instrumentation"
  instrumentation.opentelemetry.io/container-names: "vllm,sidecar"
```

### Service Mesh Integration

Works with Istio/Linkerd - traces will include service mesh spans:
```yaml
env:
  - name: OTEL_PROPAGATORS
    value: "tracecontext,baggage,b3multi,jaeger"
```

## Best Practices

1. **Use both auto-instrumentation AND vLLM custom tracing** for complete observability
2. **Configure appropriate sampling** for production workloads
3. **Monitor trace export performance** and adjust batch settings
4. **Use consistent service naming** across your microservices
5. **Include relevant resource attributes** for filtering and grouping
6. **Test with a trace analysis tool** like Jaeger or Grafana to validate span structure