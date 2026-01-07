# Distributed Tracing for llm-d

## Summary

This proposal introduces distributed tracing for llm-d distributed inference framework using manual OpenTelemetry instrumentation.
Distributed tracing will provide observability into inference workloads, enabling performance optimization, cost control, and quality
validation across the llm-d stack through explicit, custom spans at critical decision points. 

## Motivation

LLM inference workloads present unique observability challenges due to their expensive, non-uniform, and often slow request patterns. In distributed
systems like llm-d, understanding request flow across components like the inference scheduler, KV cache manager, and vLLM instances is required
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
Each component will explicitly initialize tracers and create custom spans around key operations—scheduling decisions,
cache lookups, model execution—to provide deep, end-to-end observability with precise control over traced operations and attributes.

### Key Observability Capabilities

This initial instrumentation enables the following important insights for llm-d distributed inference:

#### 1. KV Cache-Aware Routing Effectiveness

**Enabled by**: `llm_d.epp.scorer.prefix_cache` and `llm_d.kv_cache.get_scores` spans

**Insights**:
- Which pods have cached blocks for incoming requests and their cache hit ratios
- How scoring decisions route requests to pods with optimal cache locality
- Score distributions that validate whether KV cache-aware scheduling provides measurable value
- Individual pod cache hit patterns to identify hot/cold pods and optimize cache distribution

#### 2. P/D Disaggregation Decision Intelligence

**Enabled by**: `llm_d.epp.profile_handler.pick` span

**Insights**:
- Why each request chose decode-only vs prefill+decode mode based on cache hit ratio and input size
- Decision rationale showing when disaggregation provides benefit vs when it adds unnecessary overhead
- Threshold tuning data to optimize disaggregation policy

#### 3. Performance Bottleneck Identification

**Enabled by**: End-to-end trace across Gateway → EPP plugins → KV Cache → P/D Sidecar → vLLM

**Insights**:
- Component-level latency breakdown to identify whether slowness is in scheduling, cache lookup, prefill, decode, or coordination
- End-to-end analysis showing where time is actually spent in complex multi-hop requests

#### 4. Error Attribution and Root Cause Analysis

**Enabled by**: Distributed trace context propagation with error status tracking

**Insights**:
- Trace errors across component boundaries with full context
- Exact failure point identification (gateway admission, cache lookup, prefill failure, decode failure)
- Error correlation linking downstream failures back to originating gateway requests

#### 5. Request-Level Cost and Resource Attribution

**Enabled by**: Token usage attributes from vLLM `llm_request` spans and gateway metadata

**Insights**:
- Token usage per request (prompt tokens, completion tokens, cached tokens)
- Per-model and per-application cost tracking for chargeback and optimization
- Cache effectiveness impact on cost: measure how cached tokens reduce computational expense

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

The implementation uses **manual OpenTelemetry instrumentation** across llm-d components:

### Components

#### **Inference Gateway (gateway-api-inference-extension)**

**Proposed Spans:**
- `gateway.request`: Top-level request span wrapping entire gateway processing (SERVER span)
  - Span created at request entry, ended when processing completes
  - Provides end-to-end visibility into gateway request handling

**Trace Context Propagation:**
- W3C trace context (traceparent, tracestate) injected into HTTP headers in `pkg/epp/handlers/request.go` (generateHeaders function)
- Headers propagated to downstream components (EPP plugins, P/D sidecar, vLLM)
- Enables end-to-end distributed tracing across all llm-d components

#### **EPP Plugins (llm-d-inference-scheduler)**

EPP plugins run within the gateway-api-inference-extension process but are provided by llm-d-inference-scheduler.
These plugins create child spans under the gateway.request span:

**Added Spans:**
- `llm_d.epp.startup`: Pod startup span
- `llm_d.epp.scorer.prefix_cache`: Precise prefix cache scoring
- `llm_d.epp.prerequest.pd_disaggregation`: P/D disaggregation header setup
- `llm_d.epp.profile_handler.pick`: P/D profile selection decision point

#### **KV Cache (llm-d-kv-cache)**

**Added Spans:**
- `llm_d.kv_cache.get_scores`: Main scoring operation (SERVER span)
- `llm_d.kv_cache.storage.lookup`: Storage backend lookup (INTERNAL span)
- `llm_d.kv_cache.scorer.compute`: Scoring algorithm execution (INTERNAL span)

**Implementation Notes:**
- All three spans form a parent-child relationship during pod scoring
- Spans are only created when precise-prefix-cache-scorer plugin is enabled and invoked
- Hit ratio calculation: `pods_with_hits / total_pods` provides cache effectiveness metric

#### **P/D Proxy (llm-d-inference-scheduler/pkg/sidecar)**

Located in llm-d-inference-scheduler repository under `pkg/sidecar/proxy/` with entrypoint `cmd/pd-sidecar/main.go`.

**Added Spans:**
- `llm_d.pd_proxy.startup`: Sidecar startup span
- `llm_d.pd_proxy.request`: Top-level request span for all requests through proxy (SERVER span)
- `llm_d.pd_proxy.prefill`: Prefill stage processing (INTERNAL span)
- `llm_d.pd_proxy.decode`: Decode stage processing (INTERNAL span)

**Implementation Notes:**
- `llm_d.pd_proxy.request` span is created for ALL requests, even when disaggregation is not active
- `llm_d.pd_proxy.prefill` and `llm_d.pd_proxy.decode` spans are only created when P/D disaggregation is active

#### **vLLM Instances**

**Upstream Implementation:** vLLM has built-in OpenTelemetry tracing support (no changes proposed).

**Existing Span:**
- `llm_request`: Full request lifecycle from arrival to completion (SERVER span)
  - Created at request completion in vLLM's OutputProcessor
  - Automatically extracts and continues trace context from incoming HTTP headers

### Enabling Distributed Tracing

Components initialize tracing via `telemetry.InitTracing()` in their startup code. This configures:
- OTLP gRPC exporter for sending traces to an OpenTelemetry collector
- W3C trace context propagation (traceparent/tracestate headers)
- Parent-based sampling with configurable ratio (default 10%)

Configuration uses standard OpenTelemetry environment variables: `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER`, and `OTEL_TRACES_SAMPLER_ARG`.

vLLM uses built-in OpenTelemetry support (no code changes required), enabled via `--otlp-traces-endpoint` command-line flag.

### Example Distributed Trace

The following shows an abbreviated trace structure for a request with KV cache-aware routing and P/D disaggregation:

```
gateway.request (2150ms) [gateway-api-inference-extension]
│
├── llm_d.epp.scorer.prefix_cache (12ms)
│   ├── Attributes: candidate_pods=3, scores_computed=3
│   └── llm_d.kv_cache.get_scores (10ms) [kv-cache service]
│       ├── Attributes: pod_count=3, block_keys.count=42, hit_ratio=0.67, pods_with_hits=2
│       ├── llm_d.kv_cache.storage.lookup (6ms)
│       │   └── Attributes: block_count=42, cache_hit=true, blocks_found=28
│       └── llm_d.kv_cache.scorer.compute (3ms)
│           └── Attributes: algorithm="precise", pods_scored=3, score.max=28.0, score.avg=9.3
│
├── llm_d.epp.profile_handler.pick (3ms)
│   └── Attributes: decision="prefill_decode", cache_hit_ratio=0.31,
│                    pd_threshold=1024, non_cached_bytes=1402
│
├── llm_d.epp.prerequest.pd_disaggregation (2ms)
│   └── Attributes: disaggregation_enabled=true, prefill_pod_address=10.0.1.5
│
└── llm_d.pd_proxy.request (2105ms) [llm-d-pd-proxy]
    ├── Attributes: connector="nixlv2", disaggregation_enabled=true,
    │              total_duration_ms=2105, true_ttft_ms=55
    │
    ├── llm_d.pd_proxy.prefill (55ms)
    │   ├── Attributes: prefill_target=10.0.1.5:8000, status_code=200, duration_ms=55
    │   └── vllm:llm_request (50ms) [vllm-prefill-pod]
    │       └── Attributes: gen_ai.latency.time_in_model_prefill=0.033s
    │
    └── llm_d.pd_proxy.decode (2050ms)
        ├── Attributes: streaming=true, duration_ms=2050
        └── vllm:llm_request (2045ms) [vllm-decode-pod]
            └── Attributes: gen_ai.usage.prompt_tokens=128, completion_tokens=512,
                           gen_ai.latency.time_to_first_token=0.015s
```

**Key Trace Characteristics:**
- **Gateway span** wraps entire request including EPP plugin execution
- **KV cache spans** show cache lookup, scoring, and hit ratio for routing decisions
- **Profile handler span** captures P/D disaggregation decision with cache hit ratio and threshold
- **P/D proxy spans** track prefill and decode stages with timing breakdowns
- **vLLM spans** show prefill and decode execution with GenAI semantic conventions


### Semantic Conventions and Attributes

**OpenTelemetry GenAI Conventions:**
- `gen_ai.request.model`, `gen_ai.request.id`
- `gen_ai.usage.prompt_tokens`, `gen_ai.usage.completion_tokens`
- `gen_ai.latency.*` (TTFT, queue time, prefill/decode time)

**llm-d Custom Attributes:**
- Namespace: `llm_d.*` or component-specific (`vllm.*`, `kvcache.*`)
- Avoid high-cardinality attributes

**Span Status (Minimal Approach):**
- **Default (Success)**: Spans default to "Unset" status, which is treated as success by observability backends
- **Failure Only**: Only set status for errors: `span.SetStatus(codes.Error, "description")`
- **No Explicit Success**: Do not use `span.SetStatus(codes.Ok, "")` - the default "Unset" is sufficient
- **Error Details**: Rely on structured logging for detailed error information and stack traces
- **Rationale**: Minimal overhead, clear separation of concerns (traces for flow, logs for debugging)

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
