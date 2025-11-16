# Distributed Tracing for llm-d

## Summary

This proposal introduces distributed tracing for llm-d distributed inference framework using manual OpenTelemetry instrumentation.
Distributed tracing will provide observability into inference workloads, enabling performance optimization, cost control, and quality
validation across the llm-d stack through explicit, custom spans at critical decision points. 

## Motivation

LLM inference workloads present unique observability challenges due to their expensive, non-uniform, and often slow request patterns. In distributed
systems like llm-d, understanding request flow across components like the inference scheduler, KV cache manager, and vLLM instances becomes critical
for operationalizing inference at scale.

Current monitoring approaches lack the granular, request-level visibility needed to optimize Time to First Token (TTFT), Inter-Token Latency (ITL),
and cost efficiency in complex serving topologies involving disaggregated serving, KV-cache aware routing, and multi-model deployments.

### Goals

* **Enhanced Performance Diagnostics**: Provide detailed, request-level visibility into llm-d bottlenecks, enabling optimization of TTFT,
ITL, and overall throughput across distributed serving components.

* **Cost Efficiency and Attribution**: Enable per-request token usage tracking and cost attribution across applications and workloads, crucial for
managing high LLM computational costs.

* **Quality and Accuracy Validation**: Enable validation of response quality and performance characteristics across complex RAG pipelines, while
maintaining strict data privacy by avoiding sensitive payload exposure.

* **Simplified Debugging**: Provide end-to-end request tracing across llm-d components, to reduce mean time to resolution (MTTR) for performance
degradation and error scenarios. Provide enhanced root cause analysis.

* **Optimization Validation**: Provide concrete, per-request data to validate the effectiveness of llm-d's advanced optimizations like KV-cache aware
routing and disaggregated serving.

### Non-Goals

* **Metrics Collection**: This proposal focuses on distributed tracing. While OpenTelemetry can emit metrics, that is out of scope.

* **Log Aggregation**: While OpenTelemetry supports logs, this proposal addresses distributed tracing only.

* **Real-time Alerting**: Tracing data analysis and alerting are out of scope.

* **SLO/SLA Guarantees**: Initial implementation focuses on observability rather than SLA enforcement.

* **Sensitive Data Exposure**: This proposal does not include request/response payload tracing. Only token counts and metadata are captured.

## Proposal

This proposal introduces distributed tracing across the llm-d stack using **manual OpenTelemetry instrumentation**.
Each component will explicitly initialize tracers and create custom spans around critical operations—scheduling decisions,
cache lookups, model execution—to provide deep, end-to-end observability with precise control over traced operations and attributes.

### User Stories

#### Story 1

As a platform operator running llm-d in production, I want to quickly identify which component in my distributed serving
pipeline is causing high latency so that I can properly identify root-cause of the problem, optimize resource allocation, and meet my SLAs.

#### Story 2

As a cost-conscious organization using llm-d, I want to track token usage and costs per application and request type so that
I can optimize my prompt engineering and model selection to reduce operational expenses.

#### Story 3

As an llm-d developer validating new optimizations, I want to measure the impact of KV-cache aware routing and P/D disaggregation on request 
latency so that I can quantify the benefits of these advanced features.

#### Story 4

As an llm-d developer/administrator, I have noticed a significant change in performance since the last upgrade. I want to compare the execution,
caching and decision-making in routing between the two releases.

## Design Details

### llm-d Stack

The tracing solution will be based on **OpenTelemetry**, an open,
vendor-agnostic standard for collecting and generating telemetry data. OpenTelemetry offers:

- Semantic conventions for GenAI operations
- Standardized attributes for LLM-related telemetry  
- Broad ecosystem support and vendor neutrality

#### Resources

* [OpenTelemetry traces documentation](https://opentelemetry.io/docs/concepts/signals/traces/)
* [OpenTelemetry semantic conventions for GenAI](https://github.com/open-telemetry/semantic-conventions/blob/main/model/gen-ai/spans.yaml)
* [GenAI semantic conventions for GenAI systems documentation](https://opentelemetry.io/docs/specs/semconv/gen-ai/)

### Component Instrumentation Strategy

**Manual Instrumentation Approach:**

Components will use the OpenTelemetry SDK to explicitly create custom spans at strategic points:

- **Request lifecycle spans**: Entry and exit points for end-to-end visibility
- **Decision point spans**: Scheduling, routing, admission control logic
- **Expensive operation spans**: Cache lookups, model execution, KV transfers
- **Error path spans**: Failures and exception handling

**Manual Instrumentation Benefits:**

- **Precise Control**: Decide exactly what to trace and when
- **Rich Attributes**: Custom attributes expose component-specific decision details
- **Security by Design**: Explicit control prevents accidental sensitive data exposure
- **Debugging Power**: Detailed spans at key operations enable rapid root cause analysis
- **Performance Aware**: Add instrumentation only where overhead is acceptable

### Sampling Strategy

**Parent-Based Sampling (Recommended):**

- Respect upstream sampling decisions when llm-d is called by traced services
- Allow independent sampling for llm-d-initiated operations
- Default sampling rate: **10%** (configurable via `OTEL_TRACES_SAMPLER_ARG`)

**Configuration:**
```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1  # 10% sampling
```

Sampling decision is made at trace entry (gateway) and propagated to all components via trace context.

## Implementation Approach

The implementation uses **manual OpenTelemetry instrumentation** across llm-d components. Each component explicitly
initializes its tracer and creates custom spans around critical operations.

**Current Status:**
- **Gateway**: OTel SDK initialized (`pkg/common/telemetry.go`), zero custom spans
- **vLLM v1**: Tracer initialized, one custom span (`llm_request` at completion)

**Implementation Pattern:**

```go
// Gateway (Go)
tracer := otel.Tracer("gateway-api-inference-extension")
ctx, span := tracer.Start(ctx, "gateway.scheduler.schedule")
defer span.End()

span.SetAttributes(
    attribute.String("scheduler.policy", policy),
    attribute.Int("candidates.count", len(candidates)),
)
```

```python
# vLLM (Python)
with self.tracer.start_as_current_span("vllm.scheduler.schedule") as span:
    span.set_attribute("batch.total_tokens", total_tokens)
```

### Components

#### **Inference Gateway (gateway-api-inference-extension)**

**Key Spans:**
- `gateway.request`: Top-level request span with request metadata (SERVER span)
- `gateway.director.handle_request`: Admission control decisions (INTERNAL span)
- `gateway.scheduler.schedule`: Pod selection with filter/scorer details (INTERNAL span)

**Trace Context Propagation:**
- W3C trace context (traceparent, tracestate) injected into HTTP headers when proxying to vLLM backends
- Enables end-to-end distributed tracing across gateway and vLLM components

**Critical Attributes:**
- Request: model name, request size, streaming mode, token counts
- Director: candidate pods, admission priority, result (admitted/rejected), target pod
- Scheduler: candidate count, request ID, scheduling result, selected pod name/namespace

#### **KV Cache Manager**

**Key Spans:**
- `kvcache.manager.get_scores`: Main scoring operation
- `kvcache.storage.lookup`: Storage backend lookup
- `kvcache.scorer.compute`: Scoring algorithm execution

**Critical Attributes:**
- Model identifier, pod count, cache hit ratio, blocks available

#### **P/D Proxy (Transitional)**

Minimal instrumentation recommended given deprecation plans. Basic `pd_proxy.request` span with disaggregation metadata only.

#### **vLLM Instances**

**Current Status:** Production-ready tracing already implemented with comprehensive request-level observability.

**Key Span:**
- `llm_request`: Full request lifecycle from arrival to completion (SERVER span)
  - Created at request completion in OutputProcessor
  - Extracts and continues trace context from incoming HTTP headers
  - Captures complete latency breakdown and usage metrics

**Critical Attributes:**
- Latency: TTFT (time to first token), E2E latency, queue time, prefill time, decode time, inference time
- Usage: prompt tokens, completion tokens
- Request params: model, temperature, top_p, max_tokens, n (number of completions)
- Request ID for correlation

**Trace Context Support:**
- Automatically extracts W3C trace context (traceparent, tracestate) from HTTP request headers
- Continues traces initiated by upstream components (e.g., gateway)
- Creates new traces for requests without incoming trace context

### Enabling Distributed Tracing

Each component requires **explicit trace initialization** in code:

**Gateway (Go):**
```go
// Already implemented in pkg/common/telemetry.go
func InitTracing(ctx context.Context) error {
    // Creates TracerProvider with OTLP exporter
    // Sets up W3C propagation, configures sampling
}
```

**vLLM (Python):**
```python
# Already implemented in async_llm.py
tracer = init_tracer("vllm.llm_engine", otlp_endpoint)
```

**Configuration:**
```bash
# Gateway
OTEL_SERVICE_NAME=gateway-api-inference-extension
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1

# vLLM
vllm_config.observability_config.otlp_traces_endpoint = "http://otel-collector:4317"
```


### Trace Context Propagation

The gateway injects W3C trace context into HTTP headers when proxying requests to vLLM backends:

```go
// In gateway request handler (generateHeaders function)
traceHeaders := make(map[string]string)
propagator := otel.GetTextMapPropagator()
propagator.Inject(ctx, propagation.MapCarrier(traceHeaders))

// Headers include: traceparent, tracestate
// These are added to the HTTP request forwarded to vLLM
```

vLLM automatically extracts trace context from incoming HTTP headers (already implemented). This creates parent-child span relationships across components, enabling end-to-end distributed tracing from gateway through vLLM.

### Semantic Conventions and Attributes

**OpenTelemetry GenAI Conventions:**
- `gen_ai.request.model`, `gen_ai.request.id`
- `gen_ai.usage.prompt_tokens`, `gen_ai.usage.completion_tokens`
- `gen_ai.latency.*` (TTFT, queue time, prefill/decode time)

**llm-d Custom Attributes:**
- Namespace: `llm_d.*` or component-specific (`vllm.*`, `kvcache.*`)
- Avoid high-cardinality attributes
- Record errors: `span.RecordError(err)`, `span.SetStatus(codes.Error, msg)`

## Alternatives Considered

**Auto-Instrumentation via Agents:**
- Rejected: Provides only generic HTTP/gRPC spans without llm-d-specific decision visibility (scheduling, caching, batching)
- Cannot expose internal operations critical for debugging LLM workloads

**Third-Party APM Solutions:**
- Rejected: Vendor lock-in, may lack GenAI semantic conventions, less control over security

## Security Considerations

### Metadata-Only Tracing

**What is Captured:**
- Timing metrics (TTFT, ITL, latency), token **counts** (not actual tokens)
- Model identifiers, routing decisions, operational metadata
- Error states, KV cache hit ratios, component communication patterns

**What is Excluded:**
- Request payloads (prompts, inputs, messages)
- Response content (generated text, completions)
- Actual tokens or token IDs

### Security Benefits of Manual Instrumentation

- **Explicit Control**: Developers consciously decide what enters spans (code review catches issues)
- **No Accidental Exposure**: No dependency on agent configuration for security
- **Auditable**: All span attributes visible in code

### Implementation

```go
// SAFE: Metadata only
span.SetAttributes(
    attribute.Int("gen_ai.usage.prompt_tokens", len(tokens)),
    attribute.String("gen_ai.request.model", "llama-2-70b"),
)

// NEVER DO THIS - FORBIDDEN
span.SetAttributes(
    attribute.String("request.prompt", userPrompt),  // Exposes sensitive data
)
```

**Additional Measures:**
- Use TLS for OTLP export
- Treat trace data as operationally sensitive
- Configure appropriate retention policies

## Implementation Phases

### Phase 1: Core Request Lifecycle (Completed)

**Gateway (gateway-api-inference-extension):**
- `gateway.request` - Top-level request span with model, size, streaming, token counts
- `gateway.director.handle_request` - Admission control with candidate pods, priority, result
- `gateway.scheduler.schedule` - Scheduling decisions with candidate count, selected pod
- Trace context injection in HTTP headers to vLLM backends (traceparent, tracestate)

**vLLM:**
- `llm_request` - Full lifecycle span with TTFT, E2E latency, queue time, prefill/decode breakdown, token counts, request parameters
- Trace context extraction from HTTP headers (already implemented)

**KV Cache Manager:**
- `kvcache.manager.get_scores` - Main scoring operation with model, pod count, hit ratio
- `kvcache.storage.lookup` - Storage backend lookup (INTERNAL span)
- `kvcache.scorer.compute` - Scoring algorithm execution (INTERNAL span)

**Status:** Implemented and documented. End-to-end distributed tracing functional across gateway, vLLM, and KV cache manager.

### Phase 2: Detailed Observability (Future)

**Gateway:**
- Scheduler child spans (filters, scorers, pickers) for detailed scheduling decision visibility
- Response processing spans for streaming response handling

**Deliverable:** Enhanced decision visibility and response processing metrics

### Phase 3: Advanced Features (Future)

- Flow control spans (queue management, fairness)
- Fine-grained vLLM internal spans (worker communication, model execution steps)
- P/D disaggregation spans (prefill/decode coordination)
