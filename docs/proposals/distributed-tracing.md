# Distributed Tracing for llm-d

## Summary

This proposal introduces distributed tracing for llm-d distributed inference framework. Distributed tracing will provide observability into inference
workloads, enabling performance optimization, cost control, and quality validation across the llm-d stack. The solution will be built on OpenTelemetry
and integrated as a unified opt-in feature. 

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

* **Fine-grained Internal Instrumentation**: This proposal focuses on end-to-end visibility through ingress/egress tracing, paving the way for individual
component owners to add more fine-grained spans to cover other internal operations, function calls, and database queries within components.

* **Metrics Collection**: This proposal focuses on distributed tracing, not metrics collection, though OpenTelemetry collectors can export to both.
Note that opentelemetry instrumentation can emit metrics data from instrumented processes, for example, with HTTP servers. Tracing gives users
important RED metrics without direct metrics instrumentation.

* **Log Aggregation**: While OpenTelemetry supports logs, this proposal addresses distributed tracing only.

* **Real-time Alerting**: Tracing data analysis and alerting are out of scope, although the metrics emitted from trace data can feed into alerting systems.

* **SLO and SLA Guarantees**: Initial implementation focuses on observability rather than SLA enforcement, though tracing data
supports SLO and SLA validation.

* **Sensitive Data Exposure**: This proposal does not include request/response payload tracing to prevent inadvertent logging of sensitive LLM inputs/outputs.
Token counts and metadata are captured without exposing actual content.

## Proposal

This proposal introduces distributed tracing as a unified opt-in capability across the llm-d stack,
implemented through OpenTelemetry and configured via the llm-d-infra guided examples. The solution focuses on instrumenting
the critical path of LLM inference requests to provide end-to-end observability from inference gateway to model response.

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

The instrumentation strategy focuses on the critical path of LLM inference requests through llm-d,
covering key components responsible for routing, caching, and serving.

**Implementation Approach:**
Initial implementation will focus on ingress/egress instrumentation to establish end-to-end visibility with minimal complexity.
Implementation prioritizes request entry and exit points from each component rather than internal operation tracing.

**Auto-instrumentation Implementation:**
llm-d will implement distributed tracing using an auto-instrumentation approach with external agents:
- **llm-d-inference-scheduler (EPP)**: Auto-instrumentation support with P/D disaggregation pre-request plugin instrumentation
- **llm-d-kv-cache-manager**: Auto-instrumentation with utility functions for cache scoring and lookup operations
- **P/D Proxy (llm-d-routing-sidecar)**: Auto-instrumentation support with minimal tracing package
- **vLLM v1**: Full tracing support with native instrumentation using `init_tracer()`

**Auto-instrumentation Benefits:**
- **Zero Configuration**: Components use global tracers via `otel.Tracer()`, eliminating need for environment variables or explicit setup
- **Agent Compatibility**: Auto-instrumentation agents provide TraceProvider configuration without requiring application code changes
- **Minimal Implementation**: Adds tracing capability with minimal code footprint and dependencies
- **Operational Consistency**: All components will follow the same auto-instrumentation pattern

### Sampling Strategy

As a subsystem of LLM backend services, llm-d typically receives requests from upstream services that may already be instrumented with distributed tracing.
These incoming requests carry parent span information and sampling decisions that must be properly handled.

**Sampling Approach Options:**

1. **Parent-Based Sampling (Recommended)**: Respect upstream sampling decisions while allowing independent sampling for llm-d-initiated operations
   - **Pros**: Maintains trace continuity with upstream services, respects existing sampling budgets, reduces trace volume coordination complexity
   - **Cons**: Limited control over llm-d-specific sampling rates, potential gaps if upstream has aggressive sampling

2. **Always-Sample**: Sample all llm-d operations regardless of upstream decisions
   - **Pros**: Guaranteed llm-d observability, simplified configuration, complete coverage of LLM inference operations
   - **Cons**: Can create trace volume inconsistencies, may violate upstream sampling budgets, potential performance impact

3. **Kubernetes-Style Span Linking**: Link to upstream span information while maintaining independent sampling decisions
   - **Pros**: Preserves upstream correlation while enabling llm-d-specific sampling control, balances trace continuity with operational needs
   - **Cons**: More complex implementation, requires careful span link management, may complicate trace analysis

**Recommended Implementation:**
- **Default**: Parent-based sampling to maintain ecosystem compatibility
- **Configuration**: Allow operators to override with always-sample or custom sampling rates for critical LLM workloads
- **Span Links**: Implement span linking as enhancement for preserving upstream correlation when using independent sampling

**Auto-instrumentation Sampling:**
Auto-instrumentation agents typically support parent-based sampling by default, making this approach consistent with the zero-configuration design
while enabling customization through agent configuration.

## Implementation Approach

The implementation establishes end-to-end tracing across llm-d components using auto-instrumentation.
The approach progresses from vLLM v1 tracing support to proposed implementations in llm-d components.

**Current Implementation Status:**
- **vLLM v1**: Tracing support with `from vllm.tracing import init_tracer`
- **llm-d Components**: Working branch implementations demonstrate feasibility of auto-instrumentation approach

**Proposed Auto-instrumentation Pattern:**
Based on working branch prototypes, each component implements:
- Auto-instrumentation using `otel.GetTracerProvider().Tracer()` without explicit initialization
- Multiple spans per operation with attributes
- Error tracking and operational outcome recording
- Zero-configuration operation compatible with external auto-instrumentation agents

**Proposed Examples:**
- **llm-d-kv-cache-manager**: Detailed spans for `GetPodScores` with sub-operations (`find_tokens`, `tokens_to_block_keys`, `lookup_pods`, `score_pods`)
- **llm-d-inference-scheduler**: EPP pre-request plugin spans with P/D disaggregation tracking
- **llm-d-routing-sidecar (P/D Proxy)**: HTTP instrumentation via `otelhttp` with custom protocol spans
- **vLLM v1**: Tracer initialization and output processor integration

### Components

#### **`llm-d-inference-scheduler (Endpoint Picker Protocol)`**

  * **Component Architecture**: The llm-d inference scheduler implements the Endpoint Picker Protocol (EPP), operating as a gRPC service that
receives routing requests from the inference gateway and makes intelligent endpoint selection decisions. It functions as an endpoint picker within the broader inference gateway system.

  * **Instrumentation Focus**: This component is responsible for making smart load-balancing and routing decisions,
applying filtering and scoring algorithms based on awareness of P/D, KV-cache, SLA, and load.

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("llm-d-inference-scheduler")` without explicit initialization
    - **Initial Spans**:
      - `llm_d.epp.pd_prerequest`: P/D disaggregation pre-request plugin operation
    - **Basic Attributes**:
      - `llm_d.epp.pd.disaggregation_enabled`: Whether P/D disaggregation is active
      - `llm_d.epp.pd.prefill_pod_address`: Selected prefill pod address (when applicable)
      - `operation.outcome`: success/error
    - **Context Propagation**: Maintains trace context across EPP operations and downstream calls using global tracer
    - **Benefit**: Establishes EPP visibility in end-to-end traces, P/D disaggregation tracking with zero configuration


#### **`llm-d-kv-cache-manager`**

  * **Instrumentation Focus**: This component manages a global view of KV cache states and localities, for optimizing LLM inference by reusing
    computed key/value attention vectors. It interacts with storage to index KV block availability.

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("llm-d-kv-cache-manager")` without explicit initialization
    - **Initial Spans**:
      - `llm_d.kv_cache_manager.GetPodScores`: Main cache scoring operation (entry → response)
      - `llm_d.kv_cache_manager.find_tokens`: Tokenization operation with token count metrics
      - `llm_d.kv_cache_manager.tokens_to_block_keys`: Block key generation from tokens
      - `llm_d.kv_cache_manager.lookup_pods`: Storage lookup operations for KV block availability
      - `llm_d.kv_cache_manager.score_pods`: Pod scoring algorithm execution
    - **Basic Attributes**:
      - `gen_ai.request.model`: Model identifier (all spans)
      - `llm_d.kv_cache_manager.hit_ratio`: Cache hit ratio for the request (GetPodScores span)
      - `llm_d.kv_cache_manager.pod_count`: Number of pods considered (GetPodScores span)
      - `llm_d.kv_cache_manager.tokens_found`: Number of tokens found during tokenization
      - `llm_d.kv_cache_manager.input_tokens`: Input token count for block key generation
      - `llm_d.kv_cache_manager.block_keys_generated`: Number of block keys generated
      - `llm_d.kv_cache_manager.block_keys_count`: Block keys used for lookup/scoring
      - `llm_d.kv_cache_manager.lookup_results`: Number of lookup results from storage
      - `llm_d.kv_cache_manager.scored_pods`: Number of pods that received scores
      - `operation.outcome`: success/error/timeout (all spans)
    - **Context Propagation**: Maintains trace context across cache operations using global tracer
    - **Benefit**: Provides granular performance analysis of KV cache operations with detailed sub-operation visibility for production debugging

#### **`P/D Proxy (llm-d-routing-sidecar)` - Transitional**

  * **Instrumentation Focus**: This component currently acts as a reverse proxy for P/D (Prefill/Decode) disaggregation. However, this component is
    planned for removal as part of the architectural evolution toward direct vLLM disaggregation.

  * **Architectural Transition**:
    **P/D Proxy Removal**: As part of llm-d's architectural evolution, this component will be replaced by native vLLM disaggregation capabilities.
    Future vLLM disaggregation work will move P/D routing logic directly into vLLM components, eliminating the need for external P/D proxies and providing more direct,
    efficient tracing through vLLM's native instrumentation.

#### **`vLLM Instances`**

  * **Current Status**: **Full tracing support in vLLM v1** - vLLM v1 includes tracing infrastructure with `from vllm.tracing import init_tracer` and tracer integration in the LLM engine.

  * **Instrumentation Focus**: llm-d leverages vLLM as its reference LLM inference engine. vLLM v1's tracing support provides essential LLM observability capabilities.

  * **Native Tracing Implementation**:
    - **Built-in Instrumentation**: vLLM uses its own native tracing system, not auto-instrumentation
    - **Tracer Initialization**: `tracer = init_tracer()` in LLMEngine with output processor integration
    - **Spans**: vLLM inference request processing with configurable tracing backend
    - **Attributes**: Model execution metadata and performance characteristics
    - **Context Propagation**: Native trace context handling through vLLM processing pipeline
    - **Integration**: Works directly with OpenTelemetry without requiring external auto-instrumentation agents
    - **Security Compliance**: vLLM's tracing implementation fully aligns with the security goals outlined in this proposal, capturing only performance metrics, token counts, and request parameters while avoiding any prompt or completion content

  * **Enhanced Integration Opportunities**:
    Future vLLM disaggregation work will enable direct tracing through vLLM components, eliminating dependency on P/D proxy patterns and providing native P/D tracing visibility.

#### **`Inference Gateway (gateway-api-inference-extension)`**

  * **Instrumentation Focus**: This component serves as the entry point for inference requests, providing optimized routing and load balancing.

  * **Auto-instrumentation Implementation**:
    - **Tracing Infrastructure**: Auto-instrumentation using `otel.Tracer("gateway-api-inference-extension")` without explicit initialization
    - **Initial Spans**:
      - `llm_d.gateway.request`: Main gateway request processing
    - **Basic Attributes**:
      - HTTP method and route attributes (via otelhttp instrumentation)
      - Request/response timing (automatic via span duration)
    - **Context Propagation**: Create root trace context, propagate to EPP and model instances using global tracer
    - **Benefit**: Establishes gateway entry point visibility in end-to-end traces with zero configuration


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

* Components automatically extract incoming trace context from HTTP/gRPC headers
* Trace context is automatically propagated to downstream service calls
* Context is included in outgoing HTTP/gRPC headers without manual intervention

This provides end-to-end trace continuity across llm-d when an auto-instrumentation agent is active.

**Performance Impact:**
Auto-instrumentation has minimal overhead when no tracing agent is present:
- Components use `otel.Tracer()` calls that default to no-op implementations
- Context propagation is lightweight and stateless
- Header extraction/injection operations are constant-time
- No spans are created or exported without an active TraceProvider

### Semantic Conventions and Attributes

The implementation follows OpenTelemetry semantic conventions for GenAI operations:

**OpenTelemetry Standard Attributes** (implemented across components):
- `gen_ai.request.model`: Model identifier (all components)
- `gen_ai.usage.input_tokens`: Input token count (vLLM only)
- `gen_ai.usage.output_tokens`: Output token count (vLLM only)
- `operation.outcome`: success/error/timeout (all components)
- `http.request.method`: HTTP request method (gateway)
- `http.route`: HTTP request route (gateway)
- `http.response.status_code`: HTTP response status (gateway)
- Request duration (automatic via span timing)

**llm-d Specific Attributes**:

*Inference Scheduler (EPP):*
- `llm_d.epp.pd.disaggregation_enabled`: P/D disaggregation status
- `llm_d.epp.pd.prefill_pod_address`: Selected prefill pod address

*KV Cache Manager:*
- `llm_d.kv_cache_manager.hit_ratio`: Cache hit ratio for the request
- `llm_d.kv_cache_manager.pod_count`: Number of pods considered
- `llm_d.kv_cache_manager.tokens_found`: Number of tokens found during tokenization
- `llm_d.kv_cache_manager.input_tokens`: Input token count for block key generation
- `llm_d.kv_cache_manager.block_keys_generated`: Number of block keys generated
- `llm_d.kv_cache_manager.block_keys_count`: Block keys used for lookup/scoring
- `llm_d.kv_cache_manager.lookup_results`: Number of lookup results from storage
- `llm_d.kv_cache_manager.scored_pods`: Number of pods that received scores

*Routing Sidecar (P/D Proxy):*
- `llm_d.proxy.connector`: Proxy connector type (e.g., "nixlv2")
- `llm_d.prefill.target_host`: Target prefill host for disaggregation
- `llm_d.nixl.stage`: NIXL protocol stage ("prefill" or "decode")

## Alternatives

### Manual Instrumentation Per Component

Platform operators could manually instrument each llm-d component independently, configuring OpenTelemetry for each service separately.
While this provides maximum flexibility, it significantly increases operational complexity and error surface.
In the case where a single component is not instrumented, the ability to correlate trace data between components is lost. In other words, even when
disabling traces for a single component, the trace header should still be propagated.

### Third-party APM Solutions

Commercial APM solutions could provide automatic instrumentation. Note that most vendors already base their agents on otel instrumentation anyways.
However, these solutions may lack the GenAI-specific semantic conventions needed for LLM workload analysis and introduce vendor lock-in.

## Security Considerations

### Data Sensitivity in LLM Inference

LLM inference workloads process highly sensitive data including proprietary prompts, personal information, confidential business data, and intellectual property.
LLM queries and responses frequently contain:

- Confidential communications
- Personal identifiable information (PII) and regulated data
- Proprietary code, algorithms, and technical specifications
- Sensitive healthcare, financial, or legal information

This sensitive data requires specialized handling in observability systems to prevent inadvertent exposure through trace data.

### Tracing Security Model

This proposal implements a **metadata-only tracing approach** that provides operational visibility while protecting sensitive data:

**What is Captured:**
- Request timing and performance metrics (TTFT, ITL, total latency)
- Model identifiers, component routing decisions, and operational metadata
- Error classifications, timeout events, and success/failure states
- Component-to-component communication patterns and trace context
- KV cache hit ratios and pod selection metadata

**What is Explicitly Excluded:**
- Request payloads (prompts, user inputs, system messages)
- Response content (generated text, completions, model outputs)
- Intermediate processing content (embeddings, vector representations)
- Any form of request/response body content or headers containing sensitive data

### Security Goals

* **Data Privacy by Design**: Ensure no sensitive request/response content is captured in trace data, regardless of trace export destination or retention policies.

* **Operational Security**: Provide sufficient observability for performance optimization and debugging without compromising data confidentiality or regulatory compliance.

* **Secure Configuration**: Enable tracing through well-defined, auditable configuration paths that maintain security boundaries across llm-d components.

### Implementation Security Measures

**Auto-instrumentation Security Configuration:**
Since this proposal uses auto-instrumentation via external agents/operators, individual components cannot directly configure HTTP instrumentation options.
Security must be ensured at the auto-instrumentation agent level:

- **OpenTelemetry Operator**: HTTP instrumentation configuration must be set in the `Instrumentation` resource to prevent body capture
- **Go Auto-instrumentation Agent**: Agent configuration must disable HTTP body events and sensitive data capture
- **Environment Variables**: Agents typically support `OTEL_*` environment variables to control instrumentation behavior

**Component-Level Security (Manual Configuration Example):**
When manual instrumentation is needed, use the following for security requirements:

```go
// Manual secure HTTP instrumentation (only when auto-instrumentation insufficient)
handler := otelhttp.NewHandler(
    http.HandlerFunc(yourHandler),
    "operation_name",
    // Omit WithMessageEvents to prevent body capture
    otelhttp.WithFilter(func(r *http.Request) bool {
        return !strings.Contains(r.URL.Path, "/sensitive")
    }),
)
```

**Auto-instrumentation Limitation:**
The auto-instrumentation approach introduces a security dependency on external agent configuration. If auto-instrumentation agents enable HTTP body capture by default,
sensitive data exposure could occur without application-level control.

**Span Attribute Filtering:**
All components implement attribute filtering to ensure no sensitive data enters span attributes. Content hashes, fingerprints, and detailed error messages are explicitly avoided.

**Context Propagation Security:**
Trace context propagation uses standard OpenTelemetry headers (traceparent, tracestate) that contain only trace identifiers and do not carry business data or user content.

**Export Security:**
Trace data export follows OpenTelemetry security best practices including:
- TLS encryption for trace data transmission
- Authentication and authorization for trace collectors
- Configurable retention policies aligned with data governance requirements

**Component Isolation:**
Auto-instrumentation ensures that individual component failures or misconfigurations cannot expose data from other components, maintaining security boundaries across the llm-d stack.

### Operational Security Considerations

**Production Deployment:**
- Trace data should be treated as operationally sensitive metadata requiring appropriate access controls
- Export destinations should implement security controls consistent with organizational data governance policies
- Trace retention policies should align with operational needs while minimizing data exposure duration
