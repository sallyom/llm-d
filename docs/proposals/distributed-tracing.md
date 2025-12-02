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
- **Gateway (GAIE)**: Tracing implemented in working branch `release-1.2-tracing`
- **KV Cache Manager**: Tracing implemented in working branch `tracing`
- **llm-d-inference-scheduler (EPP + P/D Sidecar)**: Tracing implemented in working branch `tracing`
- **vLLM**: Built-in `llm_request` span support (upstream feature)

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

**Proposed Spans:**
- `gateway.request`: Top-level request span with request metadata (SERVER span)
  - Added in: `pkg/epp/handlers/server.go`
  - Attributes: model name, target model, request size, streaming mode, response size, token counts (prompt, completion, cached)
  - Status tracking: Records errors and sets error status on failures

- `gateway.director.handle_request`: Admission control decisions (INTERNAL span)
  - Added in: `pkg/epp/requestcontrol/director.go`
  - Attributes: candidate pods count, admission priority, admission result (admitted/rejected), target pod name/endpoint
  - Error tracking: Records errors from admission rejection or scheduling failures

- `gateway.scheduler.schedule`: Pod selection with scheduling details (INTERNAL span)
  - Added in: `pkg/epp/scheduling/scheduler.go`
  - Attributes: candidate pods count, request ID, scheduling result (scheduled/failed), selected pod name/namespace

**Trace Context Propagation:**
- W3C trace context (traceparent, tracestate) injected into HTTP headers in `generateHeaders()`
- Headers propagated to downstream components (P/D sidecar, vLLM)
- Enables end-to-end distributed tracing across all llm-d components

**Additional Proposed Spans (llm-d-inference-scheduler plugins):**
- `llm_d.epp.startup`: Pod startup span (added in `cmd/epp/main.go`)
  - Attributes: component, operation, outcome

- `llm_d.epp.scorer.prefix_cache`: Precise prefix cache scoring (added in `pkg/plugins/scorer/precise_prefix_cache.go`)
  - Attributes: candidate pods, model, request ID, scores computed, score distribution (max, avg), pods scored

- `llm_d.epp.prerequest.pd_disaggregation`: P/D disaggregation header setup (added in `pkg/plugins/pre-request/pd_prerequest.go`)
  - Attributes: model, request ID, disaggregation enabled flag, prefill pod address/port, reason (if disabled)

#### **KV Cache Manager**

**Proposed Spans:**
- `kvcache.manager.get_scores`: Main scoring operation (SERVER span)
  - Added in: `pkg/kvcache/indexer.go` (GetPodScores method)
  - Attributes: model name, pod count, block keys count, total blocks available, hit ratio, pods with hits
  - Error tracking: Records errors from tokenization, lookup, or scoring failures

- `kvcache.storage.lookup`: Storage backend lookup (INTERNAL span)
  - Added in: `pkg/kvcache/indexer.go` (lookupWithSpan wrapper)
  - Attributes: block count, pod filter count, cache hit flag, blocks found
  - Error tracking: Records errors from Redis/Valkey lookup failures

- `kvcache.scorer.compute`: Scoring algorithm execution (INTERNAL span)
  - Added in: `pkg/kvcache/indexer.go` (scoreWithSpan wrapper)
  - Attributes: scoring algorithm/strategy, key count, score distribution (max, avg), pods scored
  - Error tracking: Records errors from scoring computation

**Implementation Notes:**
- All three spans form a parent-child relationship during pod scoring
- Spans are only created when precise-prefix-cache-scorer plugin is enabled and invoked
- Hit ratio calculation: `pods_with_hits / total_pods` provides cache effectiveness metric

#### **P/D Sidecar (llm-d-inference-scheduler/pkg/sidecar)**

Located in llm-d-inference-scheduler repository under `pkg/sidecar/proxy/` with entrypoint `cmd/pd-sidecar/main.go`.

**Proposed Spans:**
- `pd_sidecar.request`: Top-level request span for all requests through sidecar (SERVER span)
  - Added in: `pkg/sidecar/proxy/chat_completions.go` (chatCompletionsHandler)
  - Attributes: connector type (nixlv2, lmcache, sglang), request path, disaggregation enabled flag, prefill target, prefill candidates count
  - Conditional attributes: SSRF protection errors, reason for skipping disaggregation
  - Error tracking: Records SSRF protection denials

- `pd_sidecar.prefill`: Prefill stage processing (INTERNAL span)
  - Added in: `pkg/sidecar/proxy/connector_nixlv2.go` (and other connector files)
  - Attributes: request ID, prefill target host:port, connector type, prefill HTTP status code, prefill duration (ms)
  - Error tracking: Records prefill request failures with status codes

- `pd_sidecar.decode`: Decode stage processing (INTERNAL span)
  - Added in: `pkg/sidecar/proxy/connector_nixlv2.go` (and other connector files)
  - Attributes: request ID, connector type, streaming enabled flag, data parallel routing flag, decode target host, decode duration (ms)
  - Tracks whether data parallel routing was used

**Implementation Notes:**
- `pd_sidecar.request` span is created for ALL requests, even when disaggregation is not active
- `pd_sidecar.prefill` and `pd_sidecar.decode` spans are only created when P/D disaggregation is active
- When disaggregation is inactive, attributes explain why (e.g., "no_prefill_header")
- Duration tracking uses milliseconds for prefill and decode stages
- Connector-specific implementations in: `connector_nixlv2.go`, `connector_lmcache.go`, `connector_sglang.go`

#### **vLLM Instances**

**Upstream Implementation:** vLLM has built-in OpenTelemetry tracing support (no changes proposed).

**Existing Span:**
- `llm_request`: Full request lifecycle from arrival to completion (SERVER span)
  - Upstream feature: Created at request completion in vLLM's OutputProcessor
  - Automatically extracts and continues trace context from incoming HTTP headers
  - Captures complete latency breakdown and usage metrics

**Attributes (upstream):**
- Latency metrics:
  - `gen_ai.latency.time_to_first_token` (TTFT in seconds)
  - `gen_ai.latency.e2e` (end-to-end latency in seconds)
  - `gen_ai.latency.time_in_queue` (queue time in seconds)
  - `gen_ai.latency.time_in_model_prefill` (prefill time in seconds)
  - `gen_ai.latency.time_in_model_decode` (decode time in seconds)
  - `gen_ai.latency.time_in_model_inference` (total inference time in seconds)
- Usage metrics:
  - `gen_ai.usage.prompt_tokens` (input token count)
  - `gen_ai.usage.completion_tokens` (output token count)
- Request parameters:
  - `gen_ai.request.id`, `gen_ai.request.model`
  - `gen_ai.request.temperature`, `gen_ai.request.top_p`, `gen_ai.request.max_tokens`
  - `n` (number of completions requested)

**Trace Context Support (upstream):**
- Automatically extracts W3C trace context (traceparent, tracestate) from HTTP request headers
- Continues traces initiated by upstream components (gateway, P/D sidecar)
- Creates new traces for requests without incoming trace context
- Enable with: `--otlp-traces-endpoint http://otel-collector:4317`

### Enabling Distributed Tracing

Each component requires **explicit trace initialization** via the telemetry package:

**Gateway API Inference Extension + Plugins (Go):**
```go
// Proposed in: github.com/llm-d/llm-d-inference-scheduler/pkg/telemetry/tracing.go
func InitTracing(ctx context.Context) (func(context.Context) error, error) {
    // Creates TracerProvider with OTLP exporter from environment variables
    // Sets up W3C propagation for trace context headers
    // Configures parent-based sampling
    // Returns shutdown function for graceful cleanup
}

// Called in cmd/epp/main.go at startup
shutdownTracing, err := telemetry.InitTracing(ctx)
defer shutdownTracing(ctx)
```

**KV Cache Manager (Go):**
```go
// Proposed in: github.com/llm-d/llm-d-kv-cache-manager/pkg/telemetry/tracing.go
func InitTracing(ctx context.Context) (func(context.Context) error, error) {
    // Same implementation as llm-d-inference-scheduler
    // Reads OTEL environment variables
    // Sets up OTLP exporter and W3C propagation
}

// Access tracer via: telemetry.Tracer()
```

**P/D Sidecar (Go):**
```go
// Uses same telemetry package as Gateway/EPP
// Proposed in: github.com/llm-d/llm-d-inference-scheduler/pkg/telemetry
tracer := telemetry.Tracer()
```

**vLLM (Upstream - No Changes):**
- Built-in OpenTelemetry support
- Enable via: `--otlp-traces-endpoint http://otel-collector:4317`
- Configure via: `OTEL_SERVICE_NAME` environment variable

**Configuration (Environment Variables):**
```bash
# Gateway API Inference Extension / llm-d-inference-scheduler
OTEL_SERVICE_NAME=gateway-api-inference-extension
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1  # 10% sampling for production

# P/D Sidecar
OTEL_SERVICE_NAME=pd-sidecar
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1

# vLLM (via command-line flag + environment)
--otlp-traces-endpoint http://otel-collector:4317
OTEL_SERVICE_NAME=vllm
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

### Example Distributed Trace

The following shows a complete distributed trace for an inference request with P/D disaggregation flowing through the llm-d stack:

```
Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
Total Duration: 2150ms

gateway.request (2150ms) [SERVER - service: gateway-api-inference-extension]
├── Span ID: 00f067aa0ba902b7
├── Attributes:
│   ├── gen_ai.request.model: "Qwen/Qwen3-0.6B"
│   ├── gateway.target_model: "Qwen/Qwen3-0.6B"
│   ├── gateway.request.size_bytes: 1024
│   ├── gateway.response.streaming: true
│   ├── gateway.target_pod.name: "vllm-decode-pod-0"
│   ├── gateway.target_pod.ip: "10.244.0.15"
│   ├── gen_ai.usage.prompt_tokens: 128
│   ├── gen_ai.usage.completion_tokens: 512
│   └── gen_ai.usage.cached_tokens: 64
│
├── gateway.director.handle_request (45ms) [INTERNAL]
│   ├── Span ID: b7ad6b7169203331
│   ├── Parent: 00f067aa0ba902b7
│   ├── Attributes:
│   │   ├── gateway.admission.candidate_pods: 3
│   │   ├── gateway.admission.priority: 100
│   │   ├── gateway.admission.result: "admitted"
│   │   ├── gateway.target_pod.name: "vllm-decode-pod-0"
│   │   └── gateway.target_endpoint: "10.244.0.15:8200"
│   │
│   └── gateway.scheduler.schedule (38ms) [INTERNAL]
│       ├── Span ID: 3fb7a1d9928de634
│       ├── Parent: b7ad6b7169203331
│       ├── Attributes:
│       │   ├── gateway.scheduler.candidate_pods: 3
│       │   ├── gateway.request.id: "req-12345"
│       │   ├── gateway.scheduler.result: "scheduled"
│       │   ├── gateway.target_pod.name: "vllm-decode-pod-0"
│       │   └── gateway.target_pod.namespace: "llmd"
│       │
│       ├── llm_d.epp.scorer.prefix_cache (12ms) [INTERNAL]
│       │   ├── Span ID: 5e7f9a2c8d1b3046
│       │   ├── Parent: 3fb7a1d9928de634
│       │   ├── Attributes:
│       │   │   ├── gen_ai.request.model: "Qwen/Qwen3-0.6B"
│       │   │   ├── gen_ai.request.id: "req-12345"
│       │   │   ├── llm_d.scorer.candidate_pods: 3
│       │   │   ├── llm_d.scorer.scores_computed: 3
│       │   │   ├── llm_d.scorer.score.max: 0.85
│       │   │   ├── llm_d.scorer.score.avg: 0.62
│       │   │   └── llm_d.scorer.pods_scored: 3
│       │   │
│       │   └── [Calls KV Cache Manager via gRPC]
│       │
│       └── llm_d.epp.prerequest.pd_disaggregation (2ms) [INTERNAL]
│           ├── Span ID: 9c4a6f2e8b5d1037
│           ├── Parent: 3fb7a1d9928de634
│           └── Attributes:
│               ├── gen_ai.request.model: "Qwen/Qwen3-0.6B"
│               ├── gen_ai.request.id: "req-12345"
│               ├── llm_d.epp.pd.disaggregation_enabled: true
│               ├── llm_d.epp.pd.prefill_pod_address: "10.244.0.14"
│               └── llm_d.epp.pd.prefill_pod_port: "8200"
│
└── [HTTP Request to P/D Sidecar with trace + prefill headers]
    │   traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
    │   X-Prefill-Pod: 10.244.0.14:8200
    ↓
    pd_sidecar.request (2105ms) [SERVER - service: pd-sidecar]
    ├── Span ID: 7d8e9f3a1c2b4056
    ├── Parent: 00f067aa0ba902b7 (gateway.request)
    ├── Attributes:
    │   ├── pd_sidecar.connector: "nixlv2"
    │   ├── pd_sidecar.request.path: "/v1/chat/completions"
    │   ├── pd_sidecar.disaggregation_enabled: true
    │   ├── pd_sidecar.prefill_target: "10.244.0.14:8200"
    │   └── pd_sidecar.prefill_candidates: 2
    │
    ├── pd_sidecar.prefill (55ms) [INTERNAL]
    │   ├── Span ID: 2f3e4a5b6c7d8091
    │   ├── Parent: 7d8e9f3a1c2b4056
    │   ├── Attributes:
    │   │   ├── pd_sidecar.request_id: "550e8400-e29b-41d4-a716-446655440000"
    │   │   ├── pd_sidecar.prefill_target: "10.244.0.14:8200"
    │   │   ├── pd_sidecar.connector: "nixlv2"
    │   │   ├── pd_sidecar.prefill.status_code: 200
    │   │   └── pd_sidecar.prefill.duration_ms: 55.0
    │   │
    │   └── [HTTP Request to prefill vLLM pod]
    │       ↓
    │       llm_request (50ms) [SERVER - service: vllm, pod: vllm-prefill-pod-0]
    │       ├── gen_ai.request.id: "550e8400-e29b-41d4-a716-446655440000"
    │       ├── gen_ai.latency.time_in_model_prefill: 0.033s
    │       └── (KV cache blocks transferred to decode pod)
    │
    └── pd_sidecar.decode (2050ms) [INTERNAL]
        ├── Span ID: 8a9b0c1d2e3f4105
        ├── Parent: 7d8e9f3a1c2b4056
        ├── Attributes:
        │   ├── pd_sidecar.request_id: "550e8400-e29b-41d4-a716-446655440000"
        │   ├── pd_sidecar.connector: "nixlv2"
        │   ├── pd_sidecar.decode.streaming: true
        │   ├── pd_sidecar.decode.data_parallel: false
        │   ├── pd_sidecar.decode.target: "localhost:8200"
        │   └── pd_sidecar.decode.duration_ms: 2050.0
        │
        └── [HTTP Request to local decode vLLM]
            ↓
            llm_request (2045ms) [SERVER - service: vllm, pod: vllm-decode-pod-0]
            ├── Span ID: 8e3c1e2a4d6f5b9c
            ├── Parent: 8a9b0c1d2e3f4105 (pd_sidecar.decode)
            └── Attributes:
                ├── gen_ai.request.id: "550e8400-e29b-41d4-a716-446655440000"
                ├── gen_ai.request.model: "Qwen/Qwen3-0.6B"
                ├── gen_ai.request.temperature: 0.7
                ├── gen_ai.request.top_p: 0.9
                ├── gen_ai.request.max_tokens: 512
                ├── gen_ai.usage.prompt_tokens: 128
                ├── gen_ai.usage.completion_tokens: 512
                ├── gen_ai.latency.time_to_first_token: 0.015s (using transferred KV)
                ├── gen_ai.latency.e2e: 2.045s
                ├── gen_ai.latency.time_in_queue: 0.008s
                ├── gen_ai.latency.time_in_model_decode: 2.037s
                └── gen_ai.latency.time_in_model_inference: 2.037s
```

**KV Cache Manager Span Details:**

When the precise-prefix-cache-scorer plugin is invoked during scheduling, it calls the KV Cache Manager which creates additional child spans:

```
llm_d.epp.scorer.prefix_cache (12ms) [INTERNAL]
├── [Calls KV Cache Manager GetPodScores RPC]
│
└── kvcache.manager.get_scores (10ms) [SERVER - service: kv-cache-manager]
    ├── Span ID: 7c2b5a8f3e1d9042
    ├── Parent: 5e7f9a2c8d1b3046 (llm_d.epp.scorer.prefix_cache)
    ├── Attributes:
    │   ├── gen_ai.request.model: "Qwen/Qwen3-0.6B"
    │   ├── kvcache.pod_count: 3
    │   ├── kvcache.block_keys.count: 16
    │   ├── kvcache.total_blocks_available: 1024
    │   ├── kvcache.hit_ratio: 0.67
    │   └── kvcache.pods_with_hits: 2
    │
    ├── kvcache.storage.lookup (6ms) [INTERNAL]
    │   ├── Span ID: 4f8e2c1a6d3b9057
    │   ├── Parent: 7c2b5a8f3e1d9042
    │   └── Attributes:
    │       ├── kvcache.lookup.block_count: 16
    │       ├── kvcache.lookup.pod_filter_count: 3
    │       ├── kvcache.lookup.cache_hit: true
    │       └── kvcache.lookup.blocks_found: 11
    │
    └── kvcache.scorer.compute (3ms) [INTERNAL]
        ├── Span ID: 9a3d7f5b2e8c1046
        ├── Parent: 7c2b5a8f3e1d9042
        └── Attributes:
            ├── kvcache.scorer.algorithm: "hit_count"
            ├── kvcache.scorer.key_count: 16
            ├── kvcache.score.max: 11.0
            ├── kvcache.score.avg: 7.3
            └── kvcache.scorer.pods_scored: 3
```

**Key Observations:**

1. **End-to-End Trace Coverage**: Single trace ID (`4bf92f3577b34da6a3ce929d0e0e4736`) flows across all components:
   - Gateway API Inference Extension (request routing and scheduling)
   - KV Cache Manager (cache-aware pod scoring)
   - P/D Sidecar (prefill/decode disaggregation)
   - vLLM instances (prefill and decode execution)

2. **Parent-Child Relationships**: Each span references its parent via Span ID, creating a hierarchical trace tree that visualizes request flow

3. **Component Timing Breakdown**:
   - Gateway overhead: ~45ms (scheduling, admission control, cache scoring)
   - P/D Sidecar prefill: 55ms (includes 50ms vLLM prefill + 5ms overhead)
   - P/D Sidecar decode: 2050ms (includes 2045ms vLLM decode + 5ms overhead)
   - Total: 2150ms

4. **Decision Visibility**:
   - Admission control: See which pods were candidates, priority, and admission result
   - Scheduling: See prefix cache scores (max: 0.85, avg: 0.62) that influenced pod selection
   - P/D Disaggregation: See prefill target selection and KV transfer coordination
   - Cache effectiveness: Hit ratio of 0.67 (2 out of 3 pods had matching cache blocks)

5. **Performance Insights**:
   - TTFT improved from 45ms (non-P/D) to 15ms (P/D) due to transferred KV cache blocks
   - Prefill isolated to dedicated pod (50ms), decode uses cached results (2045ms)
   - Cache-aware routing selected pod with 11 matching blocks out of 16 total

6. **Cross-Component Correlation**:
   - Request ID (`req-12345`) flows through gateway and scoring plugins
   - P/D request ID (UUID) correlates prefill and decode stages
   - Service names differentiate between components in trace visualization

7. **Error Tracking**: All spans record errors with `span.RecordError()` and set error status, enabling rapid failure diagnosis

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

### Phase 1: Core Request Lifecycle (Proposed - In PoC)

This phase implements basic request tracing across all llm-d components with key decision points.

**Gateway API Inference Extension (gateway-api-inference-extension):**
- Working branch: `release-1.2-tracing`
- Spans:
  - `gateway.request` - Top-level request span with model, size, streaming, token counts
  - `gateway.director.handle_request` - Admission control with candidate pods, priority, result
  - `gateway.scheduler.schedule` - Scheduling decisions with candidate count, selected pod
- Trace context injection in HTTP headers to downstream components (traceparent, tracestate)

**llm-d-inference-scheduler (EPP plugins + P/D Sidecar):**
- Working branch: `tracing`
- EPP Spans:
  - `llm_d.epp.startup` - Pod startup and initialization
  - `llm_d.epp.scorer.prefix_cache` - Prefix cache scoring with score distribution
  - `llm_d.epp.prerequest.pd_disaggregation` - P/D header setup
- P/D Sidecar Spans:
  - `pd_sidecar.request` - Top-level request span with connector type, disaggregation status
  - `pd_sidecar.prefill` - Prefill stage with target, duration, status
  - `pd_sidecar.decode` - Decode stage with streaming mode, data parallel routing, duration

**KV Cache Manager:**
- Working branch: `tracing`
- Spans:
  - `kvcache.manager.get_scores` - Main scoring with model, pod count, hit ratio
  - `kvcache.storage.lookup` - Storage backend lookup with cache hit metrics
  - `kvcache.scorer.compute` - Scoring algorithm with score distribution

**vLLM (Upstream - No Changes Needed):**
- Built-in span: `llm_request` with full lifecycle metrics
- Trace context extraction from HTTP headers (existing feature)
- Enable via: `--otlp-traces-endpoint` flag

**Status:** Proof-of-concept implementation exists in working branches. Not yet merged to upstream.

### Phase 2: Detailed Observability (Future)

**Gateway:**
- Scheduler child spans (filters, scorers, pickers) for detailed scheduling decision visibility
- Response processing spans for streaming response handling

**Deliverable:** Enhanced decision visibility and response processing metrics

### Phase 3: Advanced Features (Future)

- Flow control spans (queue management, fairness)
- Fine-grained vLLM internal spans (worker communication, model execution steps)
- P/D disaggregation spans (prefill/decode coordination)
