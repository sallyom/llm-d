# Distributed Tracing for llm-d

This guide explains how to enable OpenTelemetry distributed tracing across llm-d deployments. Examples use the `precise-prefix-cache-aware` guide deployment, but the same principles apply to all llm-d guides.

## Prerequisites

1. An OpenTelemetry Collector deployed in your cluster
2. A tracing backend (e.g., Jaeger, Tempo, or a managed service)
3. llm-d components built with tracing support

### Component Images with Tracing Support

The following images include distributed tracing instrumentation:

- **Gateway API Inference Extension (GAIE/EPP)**: `quay.io/sallyom/llm-d-inference-scheduler:tracing`
  - Built from: https://github.com/sallyom/llm-d-inference-scheduler branch `tracing`
  - Includes: https://github.com/sallyom/llm-d-kv-cache-manager branch `tracing`
  - Includes: https://github.com/sallyom/gateway-api-inference-extension branch `release-1.2-tracing`

- **P/D Sidecar**: `ghcr.io/llm-d/llm-d-routing-sidecar:v0.4.0-rc.1`
  - Built with OpenTelemetry instrumentation

- **vLLM**: Any vLLM image with `--otlp-traces-endpoint` support
  - Example: `quay.io/sallyom/vllm:tracing`
  - [Dockerfile to build with tracing packages](../../../docker/Dockerfile.cuda-with-otel)

## Overview

llm-d deployments consist of multiple components that support distributed tracing:

1. **Gateway API Inference Extension (GAIE/EPP)** - Routes requests and scores endpoints
2. **KV Cache Manager** - Embedded in the llm-d-inference-scheduler image, provides cache-aware scoring
3. **P/D Sidecar** - Routes prefill/decode requests (embedded in model service pods)
4. **vLLM** - LLM serving engine with built-in tracing support

## Custom Spans

The tracing-enabled images add custom spans to provide detailed observability:

### Gateway API Inference Extension Spans

**Always Present:**
- `llm_d.epp.startup` - Pod startup and initialization
- `llm_d.gateway.request` - Per-request span with HTTP metadata and token counts

**Conditional (based on configuration):**
- `llm_d.epp.pd_prerequest` - Prefill/Decode disaggregation processing

### KV Cache Manager Spans

**Conditional (when precise-prefix-cache-scorer is enabled):**
- `llm_d.kv_cache_manager.initialization` - KV cache indexer setup
- `llm_d.kv_cache_manager.GetPodScores` - Pod scoring with cache awareness
- Additional child spans for cache operations (token finding, block key computation, etc.)

### P/D Sidecar Spans

- `pd_sidecar.request` - Overall request handling
- `pd_sidecar.prefill` - Prefill stage (when P/D disaggregation is active)
- `pd_sidecar.decode` - Decode stage

### vLLM Spans

- `llm_request` - Complete request lifecycle with detailed latency breakdown
- Various internal vLLM operations (queue time, prefill, decode, token generation)

## Tracing Architecture

```
Client Request
    ↓
[gateway.request] ← W3C trace context propagation
    ↓
├── [gateway.director.handle_request]
│   └── [gateway.scheduler.schedule]
│       └── [kvcache.manager.get_scores] (if KV cache scoring enabled)
    ↓
[HTTP Request with traceparent/tracestate headers]
    ↓
[pd_sidecar.request] ← Continues trace from gateway
    ↓
├── [pd_sidecar.prefill]
└── [pd_sidecar.decode]
    ↓
[llm_request] ← Full vLLM request lifecycle
```

## Enabling Tracing

### Step 1: Deploy tracing stack

##### Install OpenTelemetry Operator

```bash
# Add the OpenTelemetry Helm repository
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Create namespace
kubectl create namespace opentelemetry-operator-system

# Install the operator
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace opentelemetry-operator-system \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-k8s" \
  --version 0.93.0

# Verify
kubectl get pods -n opentelemetry-operator-system
```

##### Install Tracing Backend

**Option 1: Jaeger (Simple, All-in-One)**

```bash
# Assumes monitoring namespace exists, if not 'kubectl create ns monitoring'
# Apply Jaeger v2 all-in-one deployment
kubectl apply -f docs/monitoring/tracing/jaeger-all-in-one.yaml -n monitoring

# Verify
kubectl get pods -n monitoring -l app=jaeger
kubectl get svc -n monitoring jaeger
```

**Option 2: Tempo (Production, Long-term Storage)**

```bash
# Install Tempo
helm install tempo grafana/tempo \
  --namespace monitoring \
  --version 1.23.3 \
  --set tempo.searchEnabled=true

# Verify
kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo
kubectl get svc -n monitoring tempo
```

**Note**: You can use either Jaeger or Tempo, or both. Jaeger is simpler for development, while Tempo is better for production with Grafana integration.

##### Deploy OpenTelemetry Collector

```bash
# Apply the collector configuration
kubectl apply -f docs/monitoring/tracing/llm-d-collector.yaml -n monitoring

# Verify
kubectl get pods -n monitoring | grep collector
kubectl logs -n monitoring deployment/llm-d-collector-collector --tail=50
```

The collector will:
- Receive traces via OTLP (gRPC/HTTP on port 4317/4318)
- Filter out `/metrics` endpoint spans (reduces noise)
- Export to your tracing backend (Jaeger, Tempo, or both)

### Step 2: Update GAIE Values

Edit your GAIE/EPP values file (e.g., `guides/precise-prefix-cache-aware/gaie-kv-events/values.yaml`):

```yaml
inferenceExtension:
  ---
  image:
    # Use the tracing-enabled image
    name: llm-d-inference-scheduler
    hub: quay.io/sallyom
    tag: tracing
    pullPolicy: Always

  ---

  flags:
    # Log verbosity (1-5, higher = more verbose)
    v: 4

  --- 

  # OpenTelemetry distributed tracing configuration
  tracing:
    enabled: true
    # OTLP endpoint for trace export
    otelExporterEndpoint: "http://llm-d-collector-collector.monitoring.svc.cluster.local:4317"
    sampling:
      # Parent-based sampling with 100% trace ratio (adjust as needed)
      sampler: "parentbased_traceidratio"
      samplerArg: "1.0"  # Use "0.1" for 10% sampling in production
```

**Note**: The `inferenceExtension.tracing` configuration enables tracing for both:
- Gateway API Inference Extension (GAIE/EPP) - generates `llm_d.gateway.request` spans
- KV Cache Manager (embedded in the llm-d-inference-scheduler image) - generates `llm_d.kv_cache_manager.*` spans

### Step 3: Update Model Service Values

Edit your model service values file (e.g., `guides/precise-prefix-cache-aware/ms-kv-events/values.yaml`):

```yaml
routing:
  servicePort: 8000
  proxy:
    #image: ghcr.io/llm-d/llm-d-routing-sidecar:v0.4.0-rc.1
    image: quay.io/sallyom/llm-d-routing-sidecar:tracing
    connector: nixlv2
    secure: false
    # OpenTelemetry distributed tracing configuration for P/D sidecar
    env:
      - name: OTEL_SERVICE_NAME
        value: "pd-sidecar"
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://llm-d-collector-collector.monitoring.svc.cluster.local:4317"
      - name: OTEL_TRACES_EXPORTER
        value: "otlp"
      - name: OTEL_TRACES_SAMPLER
        value: "parentbased_traceidratio"
      - name: OTEL_TRACES_SAMPLER_ARG
        value: "1.0"  # 100% sampling, use "0.1" for 10% in production
      # Kubernetes resource attributes
      - name: OTEL_RESOURCE_ATTRIBUTES_NODE_NAME
        valueFrom:
          fieldRef:
            apiVersion: v1
            fieldPath: spec.nodeName
      - name: OTEL_RESOURCE_ATTRIBUTES_POD_NAME
        valueFrom:
          fieldRef:
            apiVersion: v1
            fieldPath: metadata.name
      - name: OTEL_RESOURCE_ATTRIBUTES_NAMESPACE
        valueFrom:
          fieldRef:
            apiVersion: v1
            fieldPath: metadata.namespace
      - name: OTEL_RESOURCE_ATTRIBUTES
        value: 'k8s.namespace.name=$(OTEL_RESOURCE_ATTRIBUTES_NAMESPACE),k8s.node.name=$(OTEL_RESOURCE_ATTRIBUTES_NODE_NAME),k8s.pod.name=$(OTEL_RESOURCE_ATTRIBUTES_POD_NAME)'

decode:
  ---
  containers:
  - name: "vllm"
    # built with ../../../docker/Dockerfile.cuda-with-otel
    image: quay.io/sallyom/vllm:tracing
    modelCommand: custom
    command:
      - /bin/sh
      - '-c'
    args:
      - |
        vllm serve Qwen/Qwen3-0.6B \
        --host 0.0.0.0 \
        --port 8200 \
        --block-size 64 \
        --prefix-caching-hash-algo sha256_cbor \
        --kv-transfer-config '{"kv_connector":"NixlConnector", "kv_role":"kv_both"}' \
        --kv-events-config "{\"enable_kv_cache_events\":true,\"publisher\":\"zmq\",\"endpoint\":\"tcp://gaie-${GAIE_RELEASE_NAME_POSTFIX}-epp.${NAMESPACE}.svc.cluster.local:5557\",\"topic\":\"kv@${POD_IP}@Qwen/Qwen3-0.6B\"}" \
        --otlp-traces-endpoint "http://llm-d-collector-collector.monitoring.svc.cluster.local:4317"
    env:
      - name: GAIE_RELEASE_NAME_POSTFIX  # index 0 matters because of set in helmfile
      - name: OTEL_SERVICE_NAME
        value: "vllm"
  ---
```

**Key Configuration Notes:**

1. **Environment Variable Order**: `GAIE_RELEASE_NAME_POSTFIX` must be at env[0] because helmfile dynamically sets it
2. **P/D Sidecar Tracing**: Configured via `routing.proxy.env` with OTEL environment variables
3. **vLLM Tracing**: Enabled via `--otlp-traces-endpoint` flag and `OTEL_SERVICE_NAME` env var
4. **Sampling**: Set to 100% (`samplerArg: "1.0"`) for development/testing, use 10% (`"0.1"`) in production

### Step 4: Deploy with Tracing Enabled

Deploy your chosen guide with the updated values:

```bash
# Example using precise-prefix-cache-aware
export NAMESPACE=llmd
cd guides/precise-prefix-cache-aware
helmfile apply -n ${NAMESPACE}

# Or use any other guide, e.g., inference-scheduling
# cd guides/inference-scheduling
# helmfile apply -n ${NAMESPACE}
```

Wait for all pods to be ready:

```bash
kubectl get pods -n ${NAMESPACE}
kubectl get pods -n monitoring
```

### Step 5: Access Jaeger UI

If using Jaeger, port-forward to access the UI:

```bash
# Port-forward Jaeger UI
kubectl port-forward -n monitoring service/jaeger 16686:16686 &

# If accessing from remote VM (e.g., EC2), bind to all interfaces
kubectl port-forward -n monitoring service/jaeger --address 0.0.0.0 16686:16686 &
```

Open Jaeger UI:
- **Local**: http://localhost:16686
- **Remote VM**: http://<public-ip>:16686 (ensure security group allows inbound traffic on port 16686)

### Step 6: Generate Test Traffic

#### Using the Load Generation Script (Recommended)

The load generation script sends a continuous stream of requests, making it easy to generate multiple traces:

```bash
# Port-forward the gateway (if not already done)
kubectl port-forward -n ${NAMESPACE} service/infra-kv-events-inference-gateway-istio 8000:80 &

# Run the load generator for 5 minutes (default)
./docs/monitoring/scripts/generate-load-llmd.sh

# Or specify a custom duration in minutes
./docs/monitoring/scripts/generate-load-llmd.sh 10
```

The script will:
- Send normal chat completion requests with various prompts
- Inject malformed requests (every 5th request) to test error handling
- Show progress updates every 10 requests
- Display final metrics at the end

Press `Ctrl+C` to stop early.


### Step 7: Verify Traces in Jaeger

1. **Open Jaeger UI** (http://localhost:16686)

2. **Select Service**: Choose `gateway-api-inference-extension` from the dropdown

3. **Click "Find Traces"**: You should see recent traces

4. **Expand a trace**: Click on a trace to see the waterfall view

**Expected Spans:**

When using the precise-prefix-cache-aware guide, you should see traces with approximately **5 spans**:

1. **llm_d.gateway.request** - Top-level span from GAIE with HTTP metadata
2. **llm_d.kv_cache_manager.GetPodScores** - KV cache scoring (if precise-prefix-cache-scorer is enabled)
   - Child spans: `find_tokens`, `tokens_to_block_keys`, etc.
3. **pd_sidecar.request** - P/D sidecar request handling (if P/D sidecar tracing is enabled)
   - Child spans: `pd_sidecar.prefill`, `pd_sidecar.decode` (if P/D disaggregation is active)
4. **llm_request** - vLLM request processing with detailed latency breakdown

**Service Names to Filter By:**
- `gateway-api-inference-extension` - Gateway and KV cache manager spans
- `pd-sidecar` - P/D sidecar spans (if enabled)
- `vllm` or `vllm-precise-prefix` - vLLM model server spans

**Trace Context Propagation:**

All spans should be connected in a single distributed trace, showing proper W3C trace context propagation from gateway → sidecar → vLLM.

## Sampling Configuration

The sampling rate determines what percentage of requests generate traces.

**Recommended Settings:**
- **Development/Testing**: `samplerArg: "1.0"` (100% sampling)
- **Production**: `samplerArg: "0.1"` (10% sampling)
- **High Traffic**: `samplerArg: "0.01"` (1% sampling)

**Configure sampling in two places:**

1. **GAIE/EPP** (`gaie-kv-events/values.yaml`):
```yaml
inferenceExtension:
  tracing:
    sampling:
      sampler: "parentbased_traceidratio"
      samplerArg: "1.0"  # Adjust as needed
```

2. **P/D Sidecar** (`ms-kv-events/values.yaml`):
```yaml
routing:
  proxy:
    env:
      - name: OTEL_TRACES_SAMPLER
        value: "parentbased_traceidratio"
      - name: OTEL_TRACES_SAMPLER_ARG
        value: "1.0"  # Adjust as needed
```

**Parent-Based Sampling Behavior:**
- If a trace is started upstream (e.g., client sends `traceparent` header), all llm-d components will continue that trace
- If no upstream trace exists, llm-d will start a new trace based on the sampling ratio
- All child spans inherit the sampling decision from the parent

## Trace Context Propagation

Traces flow across components using W3C Trace Context headers:

1. **Client → Gateway**: Client can optionally send `traceparent` header to initiate a trace
2. **Gateway → vLLM/Sidecar**: Gateway injects `traceparent` and `tracestate` headers
3. **Sidecar → vLLM**: Sidecar continues the trace context from gateway
4. **vLLM**: Extracts trace context and creates child spans

This creates an end-to-end distributed trace across all components.

## Spans and Attributes

### Gateway Spans

**gateway.request** (SERVER span)
- `gen_ai.request.model`: Model name
- `gateway.target_model`: Target model name
- `gateway.request.size_bytes`: Request body size
- `gateway.response.streaming`: Streaming mode
- `gen_ai.usage.prompt_tokens`: Input tokens
- `gen_ai.usage.completion_tokens`: Output tokens

**gateway.director.handle_request** (INTERNAL span)
- `gateway.admission.candidate_pods`: Number of candidate pods
- `gateway.admission.priority`: Admission priority
- `gateway.admission.result`: "admitted" or "rejected"
- `gateway.target_pod.name`: Selected pod name

**gateway.scheduler.schedule** (INTERNAL span)
- `gateway.scheduler.candidate_pods`: Number of candidates
- `gateway.request.id`: Request ID
- `gateway.scheduler.result`: "scheduled" or error
- `gateway.target_pod.name`: Selected pod
- `gateway.target_pod.namespace`: Pod namespace

### KV Cache Manager Spans

**kvcache.manager.get_scores** (SERVER span)
- `gen_ai.request.model`: Model identifier
- `kvcache.pod_count`: Number of pods scored
- `kvcache.hit_ratio`: Cache hit ratio
- `kvcache.total_blocks_available`: Available KV blocks

### P/D Sidecar Spans

**pd_sidecar.request** (SERVER span)
- `pd_sidecar.connector`: Connector type (nixlv2, lmcache, sglang)
- `pd_sidecar.request.path`: Request path
- `pd_sidecar.disaggregation_enabled`: Whether P/D is active
- `pd_sidecar.prefill_target`: Prefill pod target
- `pd_sidecar.prefill_candidates`: Number of prefill candidates

**pd_sidecar.prefill** (INTERNAL span)
- `pd_sidecar.request_id`: Request UUID
- `pd_sidecar.prefill_target`: Prefill host:port
- `pd_sidecar.connector`: Connector type
- `pd_sidecar.prefill.status_code`: HTTP status
- `pd_sidecar.prefill.duration_ms`: Prefill duration

**pd_sidecar.decode** (INTERNAL span)
- `pd_sidecar.request_id`: Request UUID
- `pd_sidecar.connector`: Connector type
- `pd_sidecar.decode.streaming`: Streaming enabled
- `pd_sidecar.decode.data_parallel`: Data parallel routing used
- `pd_sidecar.decode.target`: Decode target host
- `pd_sidecar.decode.duration_ms`: Decode duration

### vLLM Spans

**llm_request** (SERVER span)
- `gen_ai.request.id`: Request ID
- `gen_ai.request.model`: Model name
- `gen_ai.request.temperature`: Temperature parameter
- `gen_ai.request.top_p`: Top-p parameter
- `gen_ai.request.max_tokens`: Max tokens
- `gen_ai.usage.prompt_tokens`: Input token count
- `gen_ai.usage.completion_tokens`: Output token count
- `gen_ai.latency.time_to_first_token`: TTFT (seconds)
- `gen_ai.latency.e2e`: End-to-end latency (seconds)
- `gen_ai.latency.time_in_queue`: Queue time (seconds)
- `gen_ai.latency.time_in_model_prefill`: Prefill time (seconds)
- `gen_ai.latency.time_in_model_decode`: Decode time (seconds)
- `gen_ai.latency.time_in_model_inference`: Total inference time (seconds)

## Related Files

**Deployment YAMLs:**
- `jaeger-all-in-one.yaml` - Jaeger v2 all-in-one deployment with OTLP support
- `llm-d-otel-collector.yaml` - OpenTelemetry Collector configuration with trace filtering
- `grafana-tempo-datasource.yaml` - Grafana datasource configuration for Tempo (optional)

**Scripts:**
- `../scripts/generate-load-llmd.sh` - Load generation script for testing traces
- `../scripts/install-prometheus-grafana.sh` - Install Prometheus and Grafana monitoring stack

**Example Configurations:**
- `guides/precise-prefix-cache-aware/gaie-kv-events/values.yaml` - Example GAIE configuration with tracing
- `guides/precise-prefix-cache-aware/ms-kv-events/values.yaml` - Example model service configuration with tracing

## Additional Resources

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [llm-d Distributed Tracing Proposal](../../proposals/distributed-tracing.md)
- [GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
