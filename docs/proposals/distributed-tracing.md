# Distributed Tracing for llm-d

## Summary

This proposal introduces distributed tracing for llm-d distributed inference framework. Distributed tracing will provide observability into inference
workloads, enabling performance optimization, cost control, and quality validation across the llm-d stack. The solution will be built on OpenTelemetry
standards and integrated as a unified opt-in feature through the llm-d-deployer, ensuring vendor neutrality and operational simplicity while
providing visibility into complex LLM serving pipelines.

## Motivation

LLM inference workloads present unique observability challenges due to their expensive, non-uniform, and often slow request patterns. In distributed
systems like llm-d, understanding request flow across components like the inference scheduler, KV cache manager, and vLLM instances becomes critical
for operationalizing inference at scale.

Current monitoring approaches lack the granular, request-level visibility needed to optimize Time to First Token (TTFT), Inter-Token Latency (ITL),
and cost efficiency in complex serving topologies involving disaggregated serving, KV-cache aware routing, and multi-model deployments.

### Goals

* **Enhanced Performance Diagnostics**: Provide detailed, request-level visibility into llm-d pipeline bottlenecks, enabling optimization of TTFT,
ITL, and overall throughput across distributed serving components.

* **Cost Efficiency and Attribution**: Enable per-request token usage tracking and cost attribution across applications and workloads, crucial for
managing high LLM computational costs.

* **Quality and Accuracy Validation**: Enable inspection of LLM inputs/outputs and validation of response quality, particularly in complex RAG
pipelines where context enrichment occurs across multiple services.

* **Simplified Debugging**: Provide end-to-end request tracing across llm-d components, to reduce mean time to resolution (MTTR) for performance
degradation and error scenarios.

* **Optimization Validation**: Provide concrete, per-request data to validate the effectiveness of llm-d's advanced optimizations like KV-cache aware
routing and disaggregated serving.

### Non-Goals

* **Comprehensive Internal Instrumentation**: This proposal focuses on end-to-end visibility through ingress/egress tracing, not exhaustive instrumentation of every internal operation, function call, or database query within components.

* **Metrics Collection**: This proposal focuses on distributed tracing, not metrics collection, though OpenTelemetry collectors can export to both.

* **Log Aggregation**: While OpenTelemetry supports logs, this proposal addresses distributed tracing only.

* **Real-time Alerting**: Tracing data analysis and alerting are out of scope, though trace data can feed into alerting systems.

* **SLO and SLA Guarantees**: Initial implementation focuses on observability rather than SLA enforcement, though tracing data
supports SLO and SLA validation.

## Proposal

This proposal introduces distributed tracing as a unified opt-in capability across the llm-d stack,
implemented through OpenTelemetry and configured via the llm-d-deployer. The solution focuses on instrumenting the critical
path of LLM inference requests to provide end-to-end observability from inference gateway to model response.

The tracing implementation will instrument key llm-d components: the llm-d-inference-scheduler, llm-d-kv-cache-manager,
routing proxy, vLLM instances, and inference gateway. Comprehensive instrumentation enables validation of llm-d's
optimizations while maintaining operational simplicity through centralized configuration.

### User Stories

#### Story 1

As a platform operator running llm-d in production, I want to quickly identify which component in my distributed serving
pipeline is causing high latency so that I can optimize resource allocation and meet my SLAs.

#### Story 2

As a cost-conscious organization using llm-d, I want to track token usage and costs per application and request type so that
I can optimize my prompt engineering and model selection to reduce operational expenses.

#### Story 3

As an llm-d developer validating new optimizations, I want to measure the impact of KV-cache aware routing and P/D disaggregation on request 
latency so that I can quantify the benefits of these advanced features.

#### Story 4

As an llm-d developer/administrator, I have noticed a significant change in performance since the last upgrade. I want to compare the execution, caching and decision-making in routing between the two releases.

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

The instrumentation strategy focuses on the critical path of LLM inference requests through the llm-d stack,
covering key components responsible for routing, caching, and serving.

**Implementation Approach:**
Initial implementation will focus on ingress/egress instrumentation to establish end-to-end visibility with minimal complexity.
Implementation prioritizes request entry and exit points from each component rather than internal operation tracing.

**Phase 0 Implementation - Proposed Changes:**
The following changes are proposed for Phase 0 implementation to establish basic distributed tracing across the llm-d stack:

- **Inference Gateway (gateway-api-inference-extension)**: Add tracing infrastructure with spans for request processing, orchestration, and EPP scheduling
- **llm-d-inference-scheduler (EPP)**: Add OpenTelemetry initialization and instrument P/D disaggregation pre-request plugin
- **llm-d-kv-cache-manager**: Implement tracing for GetPodScores operation with Redis instrumentation via redisotel
- **Routing Proxy (llm-d-routing-sidecar)**: Add complete OpenTelemetry instrumentation for NIXL V2 protocol and request forwarding
- **vLLM v1**: No tracing support, was explicitly removed in v1 (v0.x had tracing support)

## Implementation Phases

This proposal follows a phased implementation approach to ensure end-to-end tracing is established quickly while allowing component experts to add detailed instrumentation over time.

**Phase 0 - Basic Request/Response Tracing:**
- OpenTelemetry initialization and context propagation setup
- Single span per main operation (request entry → response)
- Basic attributes (model, success/failure, timing)
- Essential for end-to-end trace continuity

**Phase 1 - Detailed Internal Instrumentation:**
- Multiple internal spans for complex operations
- Component-specific performance metrics and attributes
- Granular error tracking and debugging information
- Advanced optimization validation metrics

#### **Component: `llm-d-inference-scheduler (Endpoint Picker Protocol)`**

  * **Component Architecture**: Provides the Endpoint Picker Protocol (EPP) that integrates with the 
Inference Gateway. It operates as a gRPC service that receives routing requests from the gateway and makes 
intelligent endpoint selection decisions.

  * **Instrumentation Focus**: This component is responsible for making smart load-balancing and routing decisions,
applying filtering and scoring algorithms based on awareness of P/D, KV-cache, SLA, and load.

  * **Phase 0 - Basic Request/Response Tracing**:
    - **Tracing Infrastructure**: Environment-based OpenTelemetry initialization with proper context propagation
    - **Added Spans**: 
      - `epp.pd_prerequest`: P/D disaggregation pre-request plugin operation
    - **Basic Attributes**: 
      - `llm_d.pd.disaggregation_enabled`: Whether P/D disaggregation is active
      - `llm_d.pd.prefill_pod_address`: Selected prefill pod address (when applicable)
      - `operation.outcome`: success/error (via `tracing.SetSpanSuccess`)
    - **Context Propagation**: Maintains trace context across EPP operations and downstream calls
    - **Benefit**: Establishes EPP visibility in end-to-end traces, P/D disaggregation tracking

  * **Phase 1 - Detailed Internal Instrumentation**:
    - **Additional Spans**:
      - EPP gRPC request (main entry → response) span
      - Prefill pod selection decision span
      - Decode pod selection span  
      - KV-cache aware routing logic span
      - Individual filter and scorer operation spans
    - **Advanced Attributes**:
      - `gen_ai.request.model`: Model identifier from EPP request
      - `llm_d.routing.decision_time`: Algorithm execution duration
      - `llm_d.routing.selected_pod`: Chosen endpoint identifier
      - `llm_d.routing.selection_reason`: Why this pod was selected
      - `llm_d.epp.candidate_pods`: Number of candidate pods considered
      - `llm_d.epp.filter_chain`: Applied filters and results
    - **Benefit**: Detailed insights into routing decisions, quantifies scheduling overhead, validates optimization effectiveness

#### **Component: `llm-d-kv-cache-manager`**

  * **Instrumentation Focus**: This component manages a global view of KV cache states and localities, for optimizing LLM inference by reusing
computed key/value attention vectors. It interacts with storage to index KV block availability.

  * **Phase 0 - Basic Request/Response Tracing**:
    - **Single Span**: `GetPodScores` operation (entry → response)
    - **Basic Attributes**:
      - `gen_ai.request.model`: Model identifier
      - `llm_d.kv_cache.hit_ratio`: Cache hit ratio for the request
      - `llm_d.kv_cache.pod_count`: Number of pods considered
      - `operation.outcome`: success/error/timeout
    - **Context Propagation**: Maintains trace context across cache operations
    - **Redis Instrumentation**: Automatic tracing of Redis operations via `redisotel`
    - **Benefit**: Establishes KV cache manager visibility in end-to-end traces, basic cache effectiveness metrics

  * **Phase 1 - Detailed Internal Instrumentation**:
    - **Additional Spans**:
      - Token processing and prefix matching span
      - Cache lookup and scoring span
      - Individual Redis operation spans (if needed beyond automatic instrumentation)
    - **Advanced Attributes**:
      - `llm_d.kv_cache.token_count`: Number of tokens processed
      - `llm_d.kv_cache.block_keys`: Cache block identifiers
      - `llm_d.kv_cache.lookup_duration`: Time spent in cache lookup
    - **Benefit**: Detailed cache operation analysis, bottleneck identification, fine-grained performance optimization

#### **Component: `Routing Proxy (llm-d-routing-sidecar)`**

  * **Instrumentation Focus**: This component acts as a reverse proxy for P/D (Prefill/Decode) disaggregation, redirecting requests to the appropriate
prefill worker. This component is deployed when P/D disaggregation is enabled.

  * **Phase 0 - Basic Request/Response Tracing**:
    - **Tracing Infrastructure**: Environment-based OpenTelemetry initialization with HTTP instrumentation via otelhttp
    - **Single Span**: `routing_proxy.request` covering entire request lifecycle (entry → response)
    - **Basic Attributes**:
      - `llm_d.proxy.connector`: Connector type (nixlv2, lmcache, nixl)
    - **Context Propagation**: Extract incoming trace context, propagate to prefill/decode pods
    - **HTTP-level Tracing**: Automatic request/response timing via otelhttp wrapper
    - **Benefit**: Establishes P/D proxy visibility in end-to-end traces with minimal complexity

  * **Phase 1 - Detailed Internal Instrumentation**:
    - **Additional Spans**:
      - `routing_proxy.nixlv2_protocol`: NIXL V2 protocol execution
      - `routing_proxy.prefiller_forward`: Forward to prefill pod
      - `routing_proxy.decoder_forward`: Forward to decode pod
    - **Advanced Attributes**:
      - `gen_ai.request.model`: Model identifier extracted from request body
      - `gen_ai.request.max_tokens`: Maximum tokens requested
      - `gen_ai.response.id`: Generated request UUID
      - `llm_d.proxy.disaggregated_prefill`: Whether P/D disaggregation is active
      - `llm_d.proxy.prefiller_url`: Prefill pod URL (when applicable)
      - `llm_d.proxy.decoder_url`: Decode pod URL
      - `llm_d.routing.decision_time`: Total protocol execution time
      - `http.request.body.size`: Request payload size
      - `http.response.status_code`: Response status code
      - Detailed error tracking and span status setting
    - **Benefit**: Detailed P/D disaggregation analysis, protocol timing metrics, request parsing and validation

#### **Component: `vLLM Instances`**

  * **Current Status**: **No tracing support in vLLM v1** - vLLM v0.x includes tracing with dedicated
`vllm/tracing.py` module and example implementations.

  * **Instrumentation Focus**: llm-d leverages vLLM as its reference LLM inference engine. This proposal advocates for restoring OpenTelemetry tracing
support in vLLM v1 given its importance for LLM observability.

  * **Phase 0 - Basic Request/Response Tracing**:
    - **Single Span**: vLLM inference request (entry → response)
    - **Basic Attributes**:
      - `gen_ai.request.model`: Model identifier
      - `gen_ai.usage.input_tokens`: Input token count
      - `gen_ai.usage.output_tokens`: Output token count
      - `operation.outcome`: success/error/timeout
    - **Context Propagation**: Extract incoming trace context from inference requests
    - **Benefit**: Establishes vLLM visibility in end-to-end traces, essential token usage for cost attribution

  * **Phase 1 - Detailed Internal Instrumentation**:
    - **Additional Spans**:
      - Request preprocessing span
      - Model execution span
      - Response generation span
    - **Advanced Attributes**:
      - `gen_ai.latency.time_to_first_token`: TTFT measurement
      - `gen_ai.latency.inter_token_latency`: ITL measurement
      - `llm_d.vllm.kv_cache_utilization`: KV cache usage metrics
      - `llm_d.vllm.batch_size`: Request batch size
    - **Benefit**: Detailed model performance analysis, optimization validation, fine-grained latency breakdown

#### **Component: `Inference Gateway (gateway-api-inference-extension)`**

  * **Instrumentation Focus**: This component serves as the entry point for inference requests, providing
optimized routing and load balancing.

  * **Phase 0 - Basic Request/Response Tracing**:
    - **Tracing Infrastructure**: Environment-based OpenTelemetry initialization with proper context propagation
    - **Spans**: 
      - `gateway.request`: Main gateway request processing
    - **Basic Attributes**:
      - HTTP method and route attributes (via otelhttp instrumentation)
      - Request/response timing (automatic via span duration)
    - **Context Propagation**: Create root trace context, propagate to EPP and model instances
    - **Benefit**: Establishes gateway entry point visibility in end-to-end traces

  * **Phase 1 - Detailed Internal Instrumentation**:
    - **Additional Spans**:
      - Request parsing and validation span
      - Model instance selection span  
      - Request/response transformation spans
    - **Advanced Attributes**:
      - `gen_ai.usage.input_tokens`: Input token count (requires parsing)
      - `gen_ai.usage.output_tokens`: Output token count (from response)
      - `llm_d.gateway.routing_algorithm`: Algorithm used for selection
      - `llm_d.gateway.load_balancing_decision`: Load balancing choice
      - `llm_d.gateway.request_size`: Request payload size
      - `llm_d.gateway.response_size`: Response payload size
    - **Benefit**: Token usage tracking for cost attribution, detailed performance analysis, optimization validation

### Unified and Opt-in Feature

Given that llm-d is designed as a solution of several individual components deployable via a single Helm chart, tracing will be
implemented as an opt-in feature configured through the llm-d-deployer.

This approach provides:

* **Simplicity**: Users enable distributed tracing across their entire llm-d stack with minimal configuration.

* **Operational Consistency**: Centralized configuration ensures all components send traces to a designated collector, simplifying trace correlation
and analysis.

* **Granular Control**: While top-level enablement is unified, individual components retain fine-grained controls.

* **Scalability**: Single collector endpoint configuration supports scalable trace ingestion and forwarding to various observability backends.

### Installation and Configuration

#### Helm Chart Architecture

The llm-d system uses a multi-chart architecture where **tracing configuration is only needed in the llm-d-modelservice chart**:

1. **llm-d-infra**: Provides infrastructure components (Gateway resources, network configuration)
   - Deployed via `llmd-infra-installer.sh` script
   - **No tracing configuration needed** - contains no instrumented components
   
2. **Gateway API Inference Extension (GAIE)**: Provides EPP functionality (external chart)
   - Deployed via `helmfile` using quickstart examples
   - **Will require tracing configuration** via dedicated tracing values section
   
3. **llm-d-modelservice**: Provides model serving components (EPP when enabled, routing proxy, vLLM pods)
   - Deployed via `helmfile` using quickstart examples
   - **Contains all instrumented components** - this is where tracing configuration is needed

#### Enabling Distributed Tracing

Tracing is configured in **both the llm-d-modelservice chart and the GAIE chart** to enable full end-to-end tracing:

**llm-d-modelservice values (e.g., `quickstart/examples/inference-scheduling/ms-inference-scheduling/values.yaml`):**
```yaml
tracing:
  enabled: true
  otelCollectorEndpoint: "http://otel-collector:4317"
  apiToken: ""  # Optional for authentication
  samplingRate: 0.1
  components:
    eppInferenceScheduler: true  # includes KV cache manager and inference gateway
    routingProxy: true
    vllm: false  # vLLM tracing not yet implemented

# ... rest of model configuration
```

**GAIE chart values (e.g., `quickstart/examples/inference-scheduling/gaie-inference-scheduling/values.yaml`):**
```yaml
tracing:
  enabled: true
  otelCollectorEndpoint: "http://otel-collector:4317"
  apiToken: ""  # Optional for authentication
  samplingRate: 0.1

# ... rest of GAIE configuration
```

#### Component Configuration Details

When `tracing.enabled: true`, the Helm templates automatically inject the following environment variables into relevant pods:

**EPP (Endpoint Picker Protocol) Deployment:**
```yaml
env:
- name: OTEL_TRACING_ENABLED
  value: "true"
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector:4317"
- name: OTEL_SAMPLING_RATE
  value: "0.1"
# Optional API token for authentication:
- name: OTEL_EXPORTER_OTLP_HEADERS
  value: "authorization=Bearer <token>"
```

**Routing Proxy Sidecar (Init Container):**
```yaml
env:
- name: OTEL_TRACING_ENABLED
  value: "true"
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector:4317"
- name: OTEL_SAMPLING_RATE
  value: "0.1"
```

**Note**: GAIE chart and llm-d-modelservice chart will require dedicated tracing configuration support as part of this Phase 0 implementation. The GAIE chart will need to inject OpenTelemetry environment variables into the EPP deployment to enable seamless end-to-end tracing across the entire llm-d stack.

#### Configuration Schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tracing.enabled` | boolean | `false` | Master switch for distributed tracing |
| `tracing.otelCollectorEndpoint` | string | `"http://otel-collector:4317"` | OpenTelemetry collector endpoint |
| `tracing.apiToken` | string | `""` | Optional API token for trace export authentication |
| `tracing.samplingRate` | number | `0.1` | Sampling rate (0.0 to 1.0) |
| `tracing.components.eppInferenceScheduler` | boolean | `true` | Enable tracing for EPP component (includes KV cache manager and inference gateway) |
| `tracing.components.routingProxy` | boolean | `true` | Enable tracing for routing proxy sidecar |
| `tracing.components.vllm` | boolean | `true` | Enable tracing for vLLM instances |


### Trace Context Propagation

Even when tracing is disabled for individual components, **trace context propagation must be maintained** to preserve end-to-end trace continuity. Components with disabled tracing should still:

* Extract incoming trace context from HTTP/gRPC headers
* Propagate trace context to downstream service calls
* Include trace context in outgoing HTTP/gRPC headers

This ensures that disabling tracing for a single component doesn't break the distributed trace chain. OpenTelemetry provides lightweight context propagation that operates independently of span creation and export.

**Performance Impact:**
Context propagation has minimal overhead when tracing is disabled:
- OpenTelemetry uses no-op propagators by default when unconfigured
- Propagators are stateless and designed to avoid runtime allocations
- Header extraction/injection operations are constant-time
- No spans are created or exported, only context headers are passed through

### Semantic Conventions and Attributes

The implementation follows OpenTelemetry semantic conventions for GenAI with a phased approach:

**Phase 0 - Essential Attributes** (implemented across all components):
- `gen_ai.request.model`: Model identifier
- `gen_ai.usage.input_tokens`: Input token count (where available)
- `gen_ai.usage.output_tokens`: Output token count (where available)
- `operation.outcome`: success/error/timeout
- Request duration (automatic via span timing)

**Phase 1 - Advanced Attributes** (component-specific implementation):
- `gen_ai.request.max_tokens`: Maximum tokens requested
- `gen_ai.request.temperature`: Model temperature setting
- `gen_ai.request.top_p`: Top-p sampling parameter
- `gen_ai.response.finish_reason`: Completion reason
- `gen_ai.response.id`: Unique response identifier
- `gen_ai.latency.time_to_first_token`: TTFT measurement
- `gen_ai.latency.inter_token_latency`: ITL measurement

**llm-d Specific Attributes**:
- `llm_d.kv_cache.hit_ratio`: KV cache hit ratio (implemented)
- `llm_d.kv_cache.pod_count`: Number of pods considered (implemented)
- `llm_d.kv_cache.token_count`: Number of tokens processed
- `llm_d.routing.decision_time`: Routing algorithm duration
- `llm_d.routing.selected_pod`: Chosen endpoint identifier
- `llm_d.proxy.forwarding_latency`: Proxy forwarding time

## Alternatives

### Manual Instrumentation Per Component

Platform operators could manually instrument each llm-d component independently, configuring OpenTelemetry for each service separately.
While this provides maximum flexibility, it significantly increases operational complexity and error surface, particularly for correlating
traces across the distributed serving pipeline.

### Third-party APM Solutions

Commercial APM solutions could provide automatic instrumentation. However, these solutions may lack the GenAI-specific semantic 
conventions needed for LLM workload analysis and introduce vendor lock-in.
