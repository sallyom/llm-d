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

This instrumentation enables the following important insights for llm-d distributed inference:

#### 1. True End-to-End Latency in P/D Disaggregation Mode

**Problem**: vLLM instances in P/D mode report misleading TTFT metrics—the prefiller doesn't include KV cache transfer time,
and the decoder reports artificially low TTFT since KV cache is pre-transferred.

**Solution**: P/D sidecar coordinator metrics (`llm_d.pd_proxy.true_ttft_ms`, `total_duration_ms`, `coordinator_overhead_ms`)
capture real client-experienced latency including gateway routing, scheduling, prefill, and sidecar coordination overhead.

**Important Distinction**:
- `coordinator_overhead_ms` measures **sidecar processing** (JSON parsing, parameter extraction) between prefill HTTP response and decode HTTP request
- **Actual KV cache transfer** happens **inside vLLM** during decode execution and is included in `decode_duration_ms`, not in coordinator overhead

#### 2. KV Cache-Aware Routing Effectiveness

**Enabled by**: `llm_d.epp.scorer.prefix_cache` and `llm_d.kv_cache.get_scores` spans

**Insights**:
- Which pods have cached blocks for incoming requests and their cache hit ratios
- How scoring decisions route requests to pods with optimal cache locality
- Score distributions that validate whether KV cache-aware scheduling provides measurable value
- Individual pod cache hit patterns to identify hot/cold pods and optimize cache distribution

#### 3. P/D Disaggregation Decision Intelligence

**Enabled by**: `llm_d.epp.profile_handler.pick` span

**Insights**:
- **Why** each request chose decode-only vs prefill+decode mode based on cache hit ratio and input size
- Decision rationale showing when disaggregation provides benefit vs when it adds unnecessary overhead
- Threshold tuning data: observe cache hit ratio vs configured P/D threshold to optimize disaggregation policy
- Validation that P/D mode is used appropriately based on actual request characteristics

#### 4. Performance Bottleneck Identification

**Enabled by**: End-to-end trace across Gateway → EPP plugins → KV Cache → P/D Sidecar → vLLM

**Insights**:
- Component-level latency breakdown to identify whether slowness is in scheduling, cache lookup, prefill, decode, or coordination
- End-to-end analysis showing where time is actually spent in complex multi-hop requests
- Comparison of P/D coordination overhead vs monolithic inference for different request patterns

#### 5. Error Attribution and Root Cause Analysis

**Enabled by**: Distributed trace context propagation with error status tracking

**Insights**:
- Trace errors across component boundaries with full context
- Exact failure point identification (gateway admission, cache lookup, prefill failure, decode failure)
- Error correlation linking downstream failures back to originating gateway requests

#### 6. Request-Level Cost and Resource Attribution

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

- **Gateway (GAIE)**: Tracing implemented in working branch `release-1.2-tracing`
- **KV Cache**: Tracing implemented in working branch `tracing`
- **llm-d-inference-scheduler (EPP + P/D Sidecar)**: Tracing implemented in working branch `tracing`
- **vLLM**: Built-in `llm_request` span support (upstream feature)

### Components

#### **Inference Gateway (gateway-api-inference-extension)**

**Proposed Spans:**
- `gateway.request`: Top-level request span wrapping entire gateway processing (SERVER span)
  - Added in: `pkg/epp/handlers/server.go` (Process method)
  - Span created at request entry, ended when processing completes
  - Provides end-to-end visibility into gateway request handling

**Trace Context Propagation:**
- W3C trace context (traceparent, tracestate) injected into HTTP headers in `pkg/epp/handlers/request.go` (generateHeaders function)
- Headers propagated to downstream components (EPP plugins, P/D sidecar, vLLM)
- Enables end-to-end distributed tracing across all llm-d components

**Implementation Notes:**
- Gateway provides single entry span that wraps all request processing
- EPP plugins (from llm-d-inference-scheduler) execute within the gateway process and create child spans
- Simplified approach compared to instrumenting individual gateway internal operations
- Focus on plugin-level visibility where scheduling and routing decisions occur

#### **EPP Plugins (llm-d-inference-scheduler)**

EPP plugins run within the gateway-api-inference-extension process but are provided by llm-d-inference-scheduler. These plugins create child spans under the gateway.request span:

**Proposed Spans:**
- `llm_d.epp.startup`: Pod startup span (added in `cmd/epp/main.go`)
  - Attributes: component, operation
  - Status tracking: Records errors on startup failures

- `llm_d.epp.scorer.prefix_cache`: Precise prefix cache scoring (added in `pkg/plugins/scorer/precise_prefix_cache.go`)
  - Attributes: candidate pods, model, request ID, scores computed, score distribution (max, avg), pods scored
  - Parent span: gateway.request

- `llm_d.epp.prerequest.pd_disaggregation`: P/D disaggregation header setup (added in `pkg/plugins/pre-request/pd_prerequest.go`)
  - Attributes: model, request ID, disaggregation enabled flag, prefill pod address/port, reason (if disabled)
  - Parent span: gateway.request

- `llm_d.epp.profile_handler.pick`: P/D profile selection decision point (added in `pkg/plugins/profile/pd_profile_handler.go`)
  - Attributes: total_profiles, executed_profiles, decision (run_decode/complete/decode_only/prefill_decode), selected_profile, pd_threshold, user_input_bytes, cache_hit_ratio, cache_hits, non_cached_bytes, reason
  - Highlights decision of whether to use decode-only or prefill+decode based on cache hit ratio and input size
  - Enables understanding of P/D disaggregation decisions: why requests used or skipped disaggregation
  - Status tracking: Records errors when unable to compute user input bytes
  - Parent span: gateway.request

#### **KV Cache**

**Proposed Spans:**
- `llm_d.kv_cache.get_scores`: Main scoring operation (SERVER span)
  - Added in: `pkg/kvcache/indexer.go` (GetPodScores method)
  - Attributes: model name, pod count, considered pods list, block keys count, total blocks available, hit ratio, pods with hits count, pods with hits list
  - Error tracking: Records errors from tokenization, lookup, or scoring failures
  - Pod tracking: Records all considered pods and which pods had cache hits

- `llm_d.kv_cache.storage.lookup`: Storage backend lookup (INTERNAL span)
  - Added in: `pkg/kvcache/indexer.go` (lookupWithSpan wrapper)
  - Attributes: block count, pod filter count, cache hit flag, blocks found
  - Error tracking: Records errors from Redis/Valkey lookup failures

- `llm_d.kv_cache.scorer.compute`: Scoring algorithm execution (INTERNAL span)
  - Added in: `pkg/kvcache/indexer.go` (scoreWithSpan wrapper)
  - Attributes: scoring algorithm/strategy, key count, score distribution (max, avg), pods scored
  - Error tracking: Records errors from scoring computation

**Implementation Notes:**
- All three spans form a parent-child relationship during pod scoring
- Spans are only created when precise-prefix-cache-scorer plugin is enabled and invoked
- Hit ratio calculation: `pods_with_hits / total_pods` provides cache effectiveness metric
- Pod tracking uses OpenTelemetry's StringSlice attribute type to record lists of pods

#### **P/D Proxy (llm-d-inference-scheduler/pkg/sidecar)**

Located in llm-d-inference-scheduler repository under `pkg/sidecar/proxy/` with entrypoint `cmd/pd-sidecar/main.go`.

**Proposed Spans:**
- `llm_d.pd_proxy.request`: Top-level request span for all requests through proxy (SERVER span)
  - Added in: `pkg/sidecar/proxy/chat_completions.go` (chatCompletionsHandler)
  - Attributes: connector type (nixlv2, lmcache, sglang), request path, disaggregation enabled flag, prefill target, prefill candidates count
  - Conditional attributes: SSRF protection errors, reason for skipping disaggregation
  - Error tracking: Records SSRF protection denials
  - **End-to-End P/D Metrics** (added to solve TTFT/TPOT measurement issues in P/D mode):
    - `llm_d.pd_proxy.total_duration_ms`: Total request duration from sidecar entry to completion (ms)
    - `llm_d.pd_proxy.true_ttft_ms`: True Time to First Token from client perspective (includes prefill + coordinator overhead)
    - `llm_d.pd_proxy.prefill_duration_ms`: Prefill stage HTTP round-trip duration (ms)
    - `llm_d.pd_proxy.decode_duration_ms`: Decode stage HTTP round-trip duration (ms) - includes KV cache transfer inside vLLM
    - `llm_d.pd_proxy.coordinator_overhead_ms`: Sidecar coordination overhead (JSON processing only, excludes KV cache transfer which happens inside vLLM) (ms)
    - `llm_d.pd_proxy.concurrent_pd`: Boolean flag (SGLang only) indicating concurrent prefill/decode execution

- `llm_d.pd_proxy.prefill`: Prefill stage processing (INTERNAL span)
  - Added in: `pkg/sidecar/proxy/connector_nixlv2.go` (and other connector files)
  - Attributes: request ID, prefill target host:port, connector type, prefill HTTP status code, prefill duration (ms)
  - Error tracking: Records prefill request failures with status codes

- `llm_d.pd_proxy.decode`: Decode stage processing (INTERNAL span)
  - Added in: `pkg/sidecar/proxy/connector_nixlv2.go` (and other connector files)
  - Attributes: request ID, connector type, streaming enabled flag, data parallel routing flag, decode target host, decode duration (ms)
  - Tracks whether data parallel routing was used

**Implementation Notes:**
- `llm_d.pd_proxy.request` span is created for ALL requests, even when disaggregation is not active
- `llm_d.pd_proxy.prefill` and `llm_d.pd_proxy.decode` spans are only created when P/D disaggregation is active
- When disaggregation is inactive, attributes explain why (e.g., "no_prefill_header")
- Duration tracking uses milliseconds for prefill and decode stages
- Connector-specific implementations in: `connector_nixlv2.go`, `connector_lmcache.go`, `connector_sglang.go`

**P/D Metrics Rationale:**
The end-to-end P/D metrics address an observability gap: vLLM instances in P/D mode report TTFT and TPOT from their local perspective, not the client's end-to-end view. Specifically:
- **Prefiller instance** reports TTFT that doesn't include KV cache transfer time
- **Decoder instance** reports artificially low TTFT (KV cache already transferred)
- **Neither instance** captures the true end-to-end latency experienced by the client

The sidecar, acting as the P/D coordinator, has visibility into both stages and can calculate the "true" metrics:
- `true_ttft_ms`: Time from request arrival to when decoder can start generating (prefill + coordinator overhead)
- `total_duration_ms`: Complete request latency from sidecar entry to response completion
- `coordinator_overhead_ms`: Sidecar coordination overhead (JSON parsing, parameter extraction) between prefill HTTP completion and decode HTTP start

These coordinator-level metrics should be used instead of per-instance vLLM metrics for accurate P/D performance analysis.

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

Components initialize tracing via `telemetry.InitTracing()` in their startup code (see `pkg/telemetry/tracing.go` in each repository). This configures:
- OTLP gRPC exporter for sending traces to an OpenTelemetry collector
- W3C trace context propagation (traceparent/tracestate headers)
- Parent-based sampling with configurable ratio (default 10%)

Configuration uses standard OpenTelemetry environment variables: `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER`, and `OTEL_TRACES_SAMPLER_ARG`.

vLLM uses built-in OpenTelemetry support (no code changes required), enabled via `--otlp-traces-endpoint` command-line flag.

### Example Distributed Trace

The following shows an abbreviated trace structure for a P/D disaggregation request:

```
gateway.request (2150ms) [gateway-api-inference-extension]
│
├── llm_d.epp.scorer.prefix_cache (12ms)
│   └── llm_d.kv_cache.get_scores (10ms) [kv-cache service]
│       ├── llm_d.kv_cache.storage.lookup (6ms)
│       └── llm_d.kv_cache.scorer.compute (3ms)
│
├── llm_d.epp.profile_handler.pick (3ms)
│   └── Attributes: decision="prefill_decode", cache_hit_ratio=0.31, pd_threshold=1024
│
├── llm_d.epp.prerequest.pd_disaggregation (2ms)
│   └── Sets prefill pod headers for P/D proxy
│
└── llm_d.pd_proxy.request (2105ms) [llm-d-pd-proxy]
    ├── Coordinator Metrics: true_ttft_ms=55, total_duration_ms=2105, coordinator_overhead_ms=0.5
    │
    ├── llm_d.pd_proxy.prefill (55ms)
    │   └── vllm:llm_request (50ms) [vllm-prefill-pod]
    │       └── Attributes: gen_ai.latency.time_in_model_prefill=0.033s
    │
    └── llm_d.pd_proxy.decode (2050ms)
        └── vllm:llm_request (2045ms) [vllm-decode-pod]
            └── Attributes: gen_ai.usage.prompt_tokens=128, completion_tokens=512,
                           gen_ai.latency.time_to_first_token=0.015s (using transferred KV),
                           Note: KV cache transfer happens during decode execution inside vLLM
```

**Key Trace Characteristics:**
- **Gateway span** wraps entire request including EPP plugin execution
- **KV cache spans** show cache lookup and scoring for routing decisions
- **Profile handler span** captures P/D disaggregation decision rationale
- **P/D proxy coordinator metrics** provide true end-to-end TTFT (not vLLM's misleading local TTFT)
- **Coordinator overhead** measures sidecar JSON processing only (~0.5ms in this example)
- **Actual KV cache transfer** happens inside vLLM decode instance (included in vllm:llm_request duration)
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
