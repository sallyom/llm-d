# EPP (Endpoint Picker) OpenTelemetry Instrumentation Guide

## Overview

This configuration enables **hybrid tracing** for the llm-d-inference-scheduler EPP (Endpoint Picker) service, combining:
- **OpenTelemetry Operator Go Auto-Instrumentation**: gRPC, HTTP, and standard library instrumentation
- **EPP Custom Tracing**: Existing custom spans in the Go code (e.g., `llm_d.epp.pd_prerequest`)

## EPP Service Architecture

Based on the analysis of your llm-d-inference-scheduler:

**Service Type**: Go application (`/app/epp` binary)
**Ports**:
- `9002`: gRPC service (main EPP functionality)
- `9003`: gRPC health checks
- `9090`: Prometheus metrics
- `5557`: ZeroMQ SUB socket for KV-Events

**Key Components**:
- Gateway API Inference Extension (GIE)
- llm-d-kv-cache-manager integration
- Custom scheduling plugins with OpenTelemetry spans

## Quick Start

### 1. Apply the EPP Instrumentation CR
```bash
kubectl apply -f epp-instrumentation.yaml
```

### 2. Update Your Existing EPP Deployment
Add the instrumentation annotation to your deployment:
```bash
kubectl patch deployment ${EPP_NAME} -p '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-go":"epp-instrumentation"}}}}}'
```

Or apply the complete example deployment included in the YAML.

### 3. Verify Tracing is Working

**Check auto-instrumentation injection:**
```bash
kubectl logs deployment/llm-d-epp | grep -i "opentelemetry\|otel"
```

**Verify spans are generated:**
- gRPC spans for EPP service calls
- HTTP spans for metrics endpoint
- Custom EPP spans (e.g., `llm_d.epp.pd_prerequest`)

## Configuration Details

### Go Auto-Instrumentation Features

The EPP service will automatically generate spans for:

**gRPC Server/Client Spans**:
- Incoming requests to port 9002 (main EPP service)
- Health check requests to port 9003
- Any outbound gRPC calls to vLLM or other services

**HTTP Spans**:
- Metrics endpoint requests (port 9090)
- Any HTTP client calls (OpenAI API, etc.)

**Custom EPP Spans** (already implemented):
- `llm_d.epp.pd_prerequest` - Prefill disaggregation logic
- Additional custom spans you've added to the codebase

### Expected Trace Structure

With this configuration, you'll see traces containing:

#### 1. gRPC Server Spans (from auto-instrumentation)
```
- Span: /envoy.service.ext_proc.v3.ExternalProcessor/Process
  - Attributes: rpc.system=grpc, rpc.service=envoy.service.ext_proc.v3.ExternalProcessor
  - Duration: End-to-end request processing time
```

#### 2. Custom EPP Spans (from your code)
```
- Span: llm_d.epp.pd_prerequest
  - Attributes:
    - llm_d.epp.pd.disaggregation_enabled: true/false
    - llm_d.epp.pd.prefill_pod_address: <pod-ip>
    - operation.outcome: success/failure
```

#### 3. HTTP Client Spans (if EPP makes external calls)
```
- Span: HTTP GET/POST
  - Attributes: http.method, http.url, http.status_code
  - For calls to vLLM endpoints, OpenAI API, etc.
```

#### 4. Integration Spans
```
- ZeroMQ operations (manual instrumentation needed)
- KV Cache Manager interactions
- Kubernetes API calls
```

## Environment Configuration

### Collector Endpoints

**Jaeger (gRPC) - Recommended:**
```yaml
endpoint: http://jaeger-collector.observability.svc.cluster.local:4317
env:
  - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
    value: "grpc"
```

**Jaeger (HTTP):**
```yaml
endpoint: http://jaeger-collector.observability.svc.cluster.local:4318/v1/traces
env:
  - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
    value: "http/protobuf"
```

### Custom Span Configuration

Your existing custom spans will continue to work alongside auto-instrumentation:

```go
// This code from pd_prerequest.go will continue to work
tracer := otel.GetTracerProvider().Tracer("llm-d-inference-scheduler")
_, span := tracer.Start(ctx, "llm_d.epp.pd_prerequest")
defer span.End()

span.SetAttributes(
    attribute.Bool("llm_d.epp.pd.disaggregation_enabled", true),
    attribute.String("llm_d.epp.pd.prefill_pod_address", podAddress),
    attribute.String("operation.outcome", "success"),
)
```

## Adding More Custom Spans

To add custom spans that will always be generated regardless of EPP processing:

### 1. Request Processing Entry Point
Add spans at the gRPC service handler level:

```go
// In your main gRPC handler
func (s *EPPServer) Process(ctx context.Context, req *ProcessRequest) (*ProcessResponse, error) {
    tracer := otel.GetTracerProvider().Tracer("llm-d-inference-scheduler")
    ctx, span := tracer.Start(ctx, "llm_d.epp.request_processing")
    defer span.End()

    span.SetAttributes(
        attribute.String("request.id", req.GetRequestId()),
        attribute.String("request.model", req.GetModel()),
    )

    // Your existing logic here
}
```

### 2. Scheduling Decision Spans
Add spans around core scheduling logic:

```go
// In scheduling logic
ctx, span := tracer.Start(ctx, "llm_d.epp.scheduling_decision")
defer span.End()

span.SetAttributes(
    attribute.Int("candidates.count", len(candidates)),
    attribute.String("scheduler.algorithm", "your-algorithm"),
)
```

### 3. KV Cache Operations
Add spans for cache manager interactions:

```go
// In cache operations
ctx, span := tracer.Start(ctx, "llm_d.epp.kv_cache_operation")
defer span.End()

span.SetAttributes(
    attribute.String("cache.operation", "lookup"),
    attribute.String("cache.key", cacheKey),
)
```

## Troubleshooting

### Go Auto-Instrumentation Not Working

**Check operator logs:**
```bash
kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-operator
```

**Verify Go binary detection:**
```bash
kubectl logs deployment/llm-d-epp | grep -i "auto-instrumentation\|otel\|binary"
```

**Check if binary is properly targeted:**
The instrumentation targets `/app/epp` - verify this matches your binary path:
```bash
kubectl exec deployment/llm-d-epp -- ls -la /app/
```

### Custom Spans Not Appearing

**Check existing OpenTelemetry initialization:**
Your Go application already imports `go.opentelemetry.io/otel`, so custom spans should work automatically.

**Verify tracer provider:**
```bash
kubectl logs deployment/llm-d-epp | grep -i "tracer\|provider"
```

### Performance Issues

**Reduce sampling for high-throughput EPP:**
```yaml
sampler:
  argument: "0.1"  # 10% sampling for production
```

**Optimize for gRPC heavy workloads:**
```yaml
env:
  - name: OTEL_BSP_SCHEDULE_DELAY
    value: "1000"  # Faster batch processing
  - name: OTEL_BSP_MAX_EXPORT_BATCH_SIZE
    value: "256"   # Smaller batches
```

## Integration with Other Services

### Distributed Tracing with vLLM
When EPP forwards requests to vLLM, traces will be connected:

```
HTTP Request → Envoy → EPP (gRPC) → vLLM (HTTP) → Response
     ↓              ↓         ↓           ↓
  Gateway      Auto-instr  Custom    Auto-instr
   Spans        gRPC       EPP       FastAPI
                Spans      Spans     Spans
```

### Service Mesh Integration
Works with Istio/Linkerd - you'll see additional service mesh spans:

```yaml
env:
  - name: OTEL_PROPAGATORS
    value: "tracecontext,baggage,b3multi,jaeger"
```

### Correlation with Metrics
EPP metrics (port 9090) can be correlated with traces using exemplars.

## Production Recommendations

1. **Use structured logging** with trace correlation:
```yaml
env:
  - name: OTEL_GO_LOG_CORRELATION
    value: "true"
```

2. **Set appropriate sampling** for EPP's high request volume:
```yaml
sampler:
  argument: "0.05"  # 5% sampling for production
```

3. **Monitor EPP-specific attributes**:
   - `llm_d.epp.pd.disaggregation_enabled`
   - `component=endpoint-picker`
   - gRPC service and method names

4. **Use resource attributes** for filtering:
```yaml
env:
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.name=llm-d-epp,component=endpoint-picker,environment=production"
```

This configuration will give you comprehensive observability into the EPP service, showing both the framework-level operations (gRPC, HTTP) and your custom LLM scheduling logic.