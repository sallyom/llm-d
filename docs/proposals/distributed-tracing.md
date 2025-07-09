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

**Current Implementation Status Summary:**
- **Inference Gateway (gateway-api-inference-extension)**: Has OpenTelemetry dependencies, needs activation
- **llm-d-inference-scheduler (EPP)**: Has OpenTelemetry dependencies, needs activation
- **llm-d-kv-cache-manager**: No OpenTelemetry instrumentation
- **Routing Proxy (llm-d-routing-sidecar)**: No OpenTelemetry instrumentation  
- **vLLM v1**: No tracing support, was explicitly removed in v1 (v0.x had tracing support)

#### **Component: `llm-d-inference-scheduler (Endpoint Picker Protocol)`**

  * **Current Status**: **OpenTelemetry packages present** - Dependencies are present but require activation and tracing instrumentation.
    - `go.opentelemetry.io/otel v1.35.0`
    - `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.58.0`
    - `go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.33.0`
    - OTLP gRPC exporter and SDK components

  * **Component Architecture**: Provides the Endpoint Picker Protocol (EPP) that integrates with the 
Inference Gateway. It operates as a gRPC service that receives routing requests from the gateway and makes 
intelligent endpoint selection decisions.

  * **Instrumentation Focus**: This component is responsible for making smart load-balancing and routing decisions,
applying filtering and scoring algorithms based on awareness of P/D, KV-cache, SLA, and load.

  * **Requests to Instrument**:
    - Request entry into the EPP gRPC service from the Inference Gateway
    - Prefill pod selection decision for P/D disaggregation
    - Decode pod selection and response
    - Request duration and basic success/failure status
 
  * **Key Spans and Attributes**:
    - EPP gRPC request receipt and processing
    - P/D prefill pod selection decision
    - Decode pod selection decision and response

  * **Benefit**: This will provide insights into why a particular model instance was chosen (or not chosen), quantify the overhead
of scheduling decisions, and help validate and optimize the complex routing logic (e.g., is KV-cache aware routing actually directing requests to
instances with relevant cached data efficiently?). This will provide visibility into disaggregated serving decisions.

#### **Component: `llm-d-kv-cache-manager`**

  * **Current Status**: **No OpenTelemetry instrumentation** - No dependencies or tracing imports in current codebase.

  * **Instrumentation Focus**: This component manages a global view of KV cache states and localities, for optimizing LLM inference by reusing
computed key/value attention vectors. It interacts with storage to index KV block availability.

  * **Requests to Instrument**:
    - Cache lookup operations (finding pods with relevant KV blocks)
    - Cache management operations
    - Pod scoring and routing decisions based on cache hits
    - Request duration and basic success/failure status

  * **Key Spans and Attributes**:
    - Cache operation request receipt and processing
    - Cache hit/miss status
    - Cache operation completion and response

  * **Benefit**: Tracing will reveal the efficacy of KV-caching strategies, identifying potential bottlenecks in cache access or transfer, and
quantifying the performance gains from cache hits. This is directly tied to improving latency and reducing resource consumption.

#### **Component: `Routing Proxy (llm-d-routing-sidecar)`**

  * **Current Status**: **No OpenTelemetry instrumentation** - No dependencies or tracing imports in current codebase.

  * **Instrumentation Focus**: This component acts as a reverse proxy for P/D (Prefill/Decode) disaggregation, redirecting requests to the appropriate
prefill worker. This component is deployed when P/D disaggregation is enabled.

  * **Requests to Instrument**:
    - Request entry into the routing proxy
    - Request forwarding to prefill pod
    - Request forwarding to decode pod
    - Request duration and basic success/failure status

  * **Key Spans and Attributes**:
    - Routing proxy request receipt and processing
    - Prefill pod forwarding
    - Decode pod forwarding
    - Request completion status

  * **Benefit**: Tracing behavior of the routing proxy will provide data on the performance characteristics of P/D disaggregation with
technologies like NVIDIA NIXL, informing future design choices for latency-optimized or throughput-optimized implementations.

#### **Component: `vLLM Instances`**

  * **Current Status**: **No tracing support in vLLM v1** - vLLM v0.x includes tracing with dedicated
`vllm/tracing.py` module and example implementations.

  * **Instrumentation Focus**: llm-d leverages vLLM as its reference LLM inference engine. This proposal advocates for restoring OpenTelemetry tracing
support in vLLM v1 given its importance for LLM observability.

  * **Requests to Instrument**:
    - Inference request entry into vLLM
    - Inference response completion from vLLM
    - Request duration and basic success/failure status
    - Token counts for cost attribution

  * **Key Spans and Attributes**:
    - vLLM inference request receipt and processing
    - `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`
    - Request completion status and duration
    - Basic model performance metrics

  * **Benefit**: This provides the fundamental performance data at the model serving layer, allowing for detailed analysis of model execution, and
validating the impact of llm-d's optimizations (like P/D disaggregation and prefix caching) on the actual vLLM inference process. It also provides
token usage attributes for cost analysis.

#### **Component: `Inference Gateway (gateway-api-inference-extension)`**

  * **Current Status**: **OpenTelemetry packages present** - Dependencies are present but require activation and tracing instrumentation.
    - `go.opentelemetry.io/otel v1.35.0` 
    - `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.58.0`
    - `go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.33.0`
    - OTLP gRPC exporter and SDK components

  * **Instrumentation Focus**: This component serves as the entry point for inference requests, providing
optimized routing and load balancing.

  * **Requests to Instrument**:
    - Request entry through the gateway
    - EPP routing decision execution
    - Request forwarding to selected model instance
    - Request duration and basic success/failure status

  * **Key Spans and Attributes**:
    - Gateway request receipt and processing
    - EPP routing decision and endpoint selection
    - Request forwarding to selected model instance
    - Request completion status

  * **Benefit**: Provides complete end-to-end visibility from the Kubernetes ingress layer through 
the intelligent routing decisions, enabling validation of advanced scheduling optimizations like
KV-cache aware routing and identification of gateway-level performance bottlenecks.

### Unified and Opt-in Feature

Given that llm-d is designed as a solution of several individual components deployable via a single Helm chart, tracing will be
implemented as an opt-in feature configured through the llm-d-deployer.

This approach provides:

* **Simplicity**: Users enable distributed tracing across their entire llm-d stack with minimal configuration.

* **Operational Consistency**: Centralized configuration ensures all components send traces to a designated collector, simplifying trace correlation
and analysis.

* **Granular Control**: While top-level enablement is unified, individual components retain fine-grained controls.

* **Scalability**: Single collector endpoint configuration supports scalable trace ingestion and forwarding to various observability backends.

### Configuration

```yaml
tracing:
  enabled: false
  otelCollectorEndpoint: "http://otel-collector:4317"
  apiToken: ""
  samplingRate: 0.1
  components:
    eppInferenceScheduler: true
    kvCacheManager: true
    routingProxy: true
    vllm: true
    inferenceGateway: true
```

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

The implementation should follow OpenTelemetry semantic conventions for GenAI, including:

**Request-level attributes**:
- `gen_ai.request.model`: Model identifier
- `gen_ai.request.max_tokens`: Maximum tokens requested
- `gen_ai.request.temperature`: Model temperature setting
- `gen_ai.request.top_p`: Top-p sampling parameter

**Response-level attributes**:
- `gen_ai.response.finish_reason`: Completion reason
- `gen_ai.usage.input_tokens`: Input token count
- `gen_ai.usage.output_tokens`: Output token count
- `gen_ai.response.id`: Unique response identifier

**Performance attributes**:
- `gen_ai.latency.time_to_first_token`: TTFT measurement
- `gen_ai.latency.inter_token_latency`: ITL measurement
- `llm_d.cache.hit_ratio`: KV cache hit ratio
- `llm_d.routing.decision_time`: Routing algorithm duration

## Alternatives

### Manual Instrumentation Per Component

Platform operators could manually instrument each llm-d component independently, configuring OpenTelemetry for each service separately.
While this provides maximum flexibility, it significantly increases operational complexity and error surface, particularly for correlating
traces across the distributed serving pipeline.

### Third-party APM Solutions

Commercial APM solutions could provide automatic instrumentation. However, these solutions may lack the GenAI-specific semantic 
conventions needed for LLM workload analysis and introduce vendor lock-in.
