# Distributed Tracing for llm-d

## Summary

This proposal introduces distributed tracing for llm-d distributed inference framework. Distributed tracing will provide observability into inference
workloads, enabling performance optimization, cost control, and quality validation across the llm-d stack. The solution will be built on OpenTelemetry
standards and integrated as a unified opt-in feature through the llm-d-infra installer to provide visibility into complex LLM serving pipelines.

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
implemented through OpenTelemetry and configured via the llm-d-infra well-lit paths. The solution focuses on instrumenting
the critical path of LLM inference requests to provide end-to-end observability from inference gateway to model response.

The tracing implementation will instrument key llm-d components: the llm-d-inference-scheduler, llm-d-kv-cache-manager,
routing proxy, vLLM instances, and inference gateway. Instrumentation enables validation of llm-d's
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

**Auto-instrumentation Implementation:**
The llm-d stack will implement distributed tracing using an auto-instrumentation approach with external observability agents:
- **llm-d-inference-scheduler (EPP)**: Auto-instrumentation support with P/D disaggregation pre-request plugin instrumentation
- **llm-d-kv-cache-manager**: Auto-instrumentation with utility functions and Redis instrumentation via redisotel
- **Routing Proxy (llm-d-routing-sidecar)**: Auto-instrumentation support with minimal tracing package
- **vLLM v1**: No tracing support (was removed in v1, though v0.x had tracing support)

**Auto-instrumentation Benefits:**
- **Zero Configuration**: Components use global tracers via `otel.Tracer()`, eliminating need for environment variables or explicit setup
- **Agent Compatibility**: Auto-instrumentation agents provide TraceProvider configuration without requiring application code changes
- **Minimal Implementation**: Adds tracing capability with minimal code footprint and dependencies
- **Operational Consistency**: All components will follow the same auto-instrumentation pattern for unified observability

## Implementation Approach

The implementation establishes end-to-end tracing with minimal complexity, allowing component experts to enhance instrumentation over time.

**Initial Auto-instrumentation:**
- Auto-instrumentation using `otel.Tracer()` without explicit initialization
- Single span per main operation (request entry → response)
- Basic attributes (model, success/failure, timing)
- Essential for end-to-end trace continuity
- Compatible with external auto-instrumentation agents

**Future Enhancements:**
Component owners can independently add detailed instrumentation including:
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

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("llm-d-inference-scheduler")` without explicit initialization
    - **Initial Spans**: 
      - `epp.pd_prerequest`: P/D disaggregation pre-request plugin operation
    - **Basic Attributes**: 
      - `llm_d.pd.disaggregation_enabled`: Whether P/D disaggregation is active
      - `llm_d.pd.prefill_pod_address`: Selected prefill pod address (when applicable)
      - `operation.outcome`: success/error
    - **Context Propagation**: Maintains trace context across EPP operations and downstream calls using global tracer
    - **Benefit**: Establishes EPP visibility in end-to-end traces, P/D disaggregation tracking with zero configuration

  * **Future Enhancement Opportunities**:
    Component owners can add detailed spans for EPP gRPC requests, pod selection decisions, routing logic, and filter operations. Advanced attributes could include routing decision details, algorithm execution timing, and optimization effectiveness metrics.

#### **Component: `llm-d-kv-cache-manager`**

  * **Instrumentation Focus**: This component manages a global view of KV cache states and localities, for optimizing LLM inference by reusing
computed key/value attention vectors. It interacts with storage to index KV block availability.

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("llm-d-kv-cache-manager")` without explicit initialization
    - **Initial Spans**: `GetPodScores` operation (entry → response)
    - **Basic Attributes**:
      - `gen_ai.request.model`: Model identifier
      - `llm_d.kv_cache.hit_ratio`: Cache hit ratio for the request
      - `llm_d.kv_cache.pod_count`: Number of pods considered
      - `operation.outcome`: success/error/timeout
    - **Context Propagation**: Maintains trace context across cache operations using global tracer
    - **Redis Instrumentation**: Automatic tracing of Redis operations via `redisotel`
    - **Cross-compatibility**: Utility functions for gateway compatibility
    - **Benefit**: Establishes KV cache manager visibility in end-to-end traces with zero configuration

  * **Future Enhancement Opportunities**:
    Component owners can add detailed spans for token processing, prefix matching, cache lookup operations, and individual Redis interactions. Enhanced attributes could include token counts, cache block identifiers, and lookup timing metrics.

#### **Component: `Routing Proxy (llm-d-routing-sidecar)`**

  * **Instrumentation Focus**: This component acts as a reverse proxy for P/D (Prefill/Decode) disaggregation, redirecting requests to the appropriate
prefill worker. This component is deployed when P/D disaggregation is enabled.

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("llm-d-routing-sidecar")` without explicit initialization
    - **Initial Spans**: `routing_proxy.request` covering entire request lifecycle (entry → response)
    - **Basic Attributes**:
      - `llm_d.proxy.connector`: Connector type (nixlv2, lmcache, nixl)
    - **Context Propagation**: Extract incoming trace context, propagate to prefill/decode pods using global tracer
    - **HTTP-level Tracing**: Automatic request/response timing via otelhttp wrapper
    - **Benefit**: Establishes P/D proxy visibility in end-to-end traces with zero configuration

  * **Future Enhancement Opportunities**:
    Component owners can add detailed spans for NIXL V2 protocol execution, prefill/decode forwarding operations, and request parsing. Enhanced attributes could include model identifiers, token counts, disaggregation status, and protocol timing metrics.

#### **Component: `vLLM Instances`**

  * **Current Status**: **No tracing support in vLLM v1** - vLLM v0.x includes tracing with dedicated
`vllm/tracing.py` module and example implementations.

  * **Instrumentation Focus**: llm-d leverages vLLM as its reference LLM inference engine. This proposal advocates for restoring OpenTelemetry tracing
support in vLLM v1 given its importance for LLM observability.

  * **Potential Auto-instrumentation Implementation** (requires vLLM v1 tracing support):
    - **Initial Spans**: vLLM inference request (entry → response)
    - **Basic Attributes**:
      - `gen_ai.request.model`: Model identifier
      - `gen_ai.usage.input_tokens`: Input token count
      - `gen_ai.usage.output_tokens`: Output token count
      - `operation.outcome`: success/error/timeout
    - **Context Propagation**: Extract incoming trace context from inference requests using global tracer
    - **Benefit**: Establishes vLLM visibility in end-to-end traces, essential token usage for cost attribution

  * **Future Enhancement Opportunities**:
    vLLM contributors could add detailed spans for request preprocessing, model execution, and response generation. Enhanced attributes could include TTFT/ITL measurements, cache utilization metrics, and batch processing details.

#### **Component: `Inference Gateway (gateway-api-inference-extension)`**

  * **Instrumentation Focus**: This component serves as the entry point for inference requests, providing
optimized routing and load balancing.

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("gateway-api-inference-extension")` without explicit initialization
    - **Initial Spans**: 
      - `gateway.request`: Main gateway request processing
    - **Basic Attributes**:
      - HTTP method and route attributes (via otelhttp instrumentation)
      - Request/response timing (automatic via span duration)
    - **Context Propagation**: Create root trace context, propagate to EPP and model instances using global tracer
    - **Benefit**: Establishes gateway entry point visibility in end-to-end traces with zero configuration

  * **Future Enhancement Opportunities**:
    Component owners can add detailed spans for request parsing, model instance selection, and request/response transformations. Enhanced attributes could include token usage metrics, routing algorithms, load balancing decisions, and payload sizes.


### Enabling Distributed Tracing

The auto-instrumentation approach eliminates the need for component-specific configuration. Tracing is enabled by
deploying an auto-instrumentation agent or operator that configures the global OpenTelemetry TraceProvider.

**Triggering Auto-instrumentation:**
This implementation supports multiple approaches for enabling tracing:

1. **OpenTelemetry Operator** (Recommended for Kubernetes): Automatically injects instrumentation via annotations
   - Documentation: [OpenTelemetry Operator](https://opentelemetry.io/docs/kubernetes/operator/)

2. **Go Auto-instrumentation Agent**: Manual agent that wraps Go applications at runtime
   - Documentation: [OpenTelemetry Go Auto-instrumentation](https://opentelemetry.io/docs/zero-code/go/)

3. **Programmatic TraceProvider Setup**: Simple global tracer provider initialization for testing
   - Documentation: [OpenTelemetry Go Manual Instrumentation](https://opentelemetry.io/docs/languages/go/getting-started/)

**Auto-instrumentation Benefits:**
- **Zero Configuration**: Components use `otel.Tracer()` calls that work with any auto-instrumentation agent
- **Agent-Driven**: External auto-instrumentation agents provide TraceProvider configuration
- **Platform Agnostic**: Compatible with various observability platforms and deployment methods
- **Lightweight**: Components remain minimal with reduced tracing dependencies


### Trace Context Propagation

**Automatic Context Propagation:**
The auto-instrumentation approach ensures trace context propagation works seamlessly across all llm-d components:

* Components automatically extract incoming trace context from HTTP/gRPC headers
* Trace context is automatically propagated to downstream service calls
* Context is included in outgoing HTTP/gRPC headers without manual intervention

This provides end-to-end trace continuity across the entire llm-d stack when an auto-instrumentation agent is active.

**Performance Impact:**
Auto-instrumentation has minimal overhead when no tracing agent is present:
- Components use `otel.Tracer()` calls that default to no-op implementations
- Context propagation is lightweight and stateless
- Header extraction/injection operations are constant-time
- No spans are created or exported without an active TraceProvider

### Semantic Conventions and Attributes

The implementation follows OpenTelemetry semantic conventions for GenAI operations:

**Core Attributes** (implemented in auto-instrumentation):
- `gen_ai.request.model`: Model identifier
- `gen_ai.usage.input_tokens`: Input token count (where available)
- `gen_ai.usage.output_tokens`: Output token count (where available)  
- `operation.outcome`: success/error/timeout
- Request duration (automatic via span timing)

**llm-d Specific Attributes**:
- `llm_d.kv_cache.hit_ratio`: KV cache hit ratio
- `llm_d.kv_cache.pod_count`: Number of pods considered
- `llm_d.pd.disaggregation_enabled`: P/D disaggregation status
- `llm_d.proxy.connector`: Connector type (nixlv2, lmcache, nixl)

**Enhancement Opportunities**:
Component owners can extend with additional GenAI semantic convention attributes such as model parameters, latency measurements (TTFT/ITL), routing decisions, and detailed performance metrics as needed for their specific use cases.

## Alternatives

### Manual Instrumentation Per Component

Platform operators could manually instrument each llm-d component independently, configuring OpenTelemetry for each service separately.
While this provides maximum flexibility, it significantly increases operational complexity and error surface, particularly for correlating
traces across the distributed serving pipeline.

### Third-party APM Solutions

Commercial APM solutions could provide automatic instrumentation. However, these solutions may lack the GenAI-specific semantic 
conventions needed for LLM workload analysis and introduce vendor lock-in.
