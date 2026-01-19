# Distributed Tracing Demo Script for P/D Disaggregation

**Demo Duration**: ~12 minutes (Part 1: 5min + Part 2: 7min)
**Setup**: 4 GPUs, Llama-3.1-8B, TCP networking (NIXL connector)
**Guides Used**: `precise-prefix-cache-aware`, `pd-disaggregation`

---

## Demo Overview

This demo has two parts:

**Part 1 (5 min)**: Precise Prefix Cache Awareness & Intelligent Routing
- Guide: `precise-prefix-cache-aware`
- Focus: EPP's intelligent routing based on prefix cache scoring
- Metrics: `llm_d_epp_prefix_cache_*` scoring metrics, cache hit rates
- Architecture: Decode-only pool (4 replicas) where EPP routes to pods with cached prefixes
- Key point: **No cross-pod KV transfers** - EPP routes requests to avoid transfers

**Part 2 (7 min)**: P/D Disaggregation with Full Observability
- Guide: `pd-disaggregation`
- Focus: End-to-end observability including coordinator metrics, NIXL KV transfers, and distributed tracing
- Metrics:
  - Coordinator: `llm_d_inference_scheduler_pd_proxy_*` (overhead, True TTFT)
  - NIXL: `vllm:nixl_xfer_time_seconds`, `vllm:nixl_bytes_transferred`, `vllm:nixl_post_time_seconds`
- Spans: `llm_d.pd_proxy.request`, `llm_d.pd_proxy.prefill`, `llm_d.pd_proxy.decode`
- Architecture: Prefill → Decode with **routing-proxy sidecar** orchestrating NIXL KV transfers
- Key point: **Complete observability stack** - coordinator, NIXL transfers, and distributed tracing in one deployment

---

## Demo Setup Summary

### Infrastructure
- **Cluster**: 4 GPUs with TCP networking for KV cache transfer
- **Model**: Llama-3.1-8B-Instruct
- **Architecture**:
  - 2 Prefill workers (TP=1 each, 1 GPU each) - TP = Tensor Parallelism
  - 1 Decode worker (TP=2, 2 GPUs) - model split across 2 GPUs
  - Heterogeneous parallelism: replicated prefill for throughput, wider decode for KV cache memory

### Expected Metrics

**Part 2 - P/D Disaggregation with Full Observability (pd-disaggregation):**

**Coordinator Metrics:**
- **True TTFT (End-to-End)**: 60-70ms
- **vLLM TTFT (Decode only)**: 45-55ms
- **vLLM TTFT (Prefill only)**: 12-18ms
- **P/D Coordination Overhead**: 0.5-1ms (pure CPU - sidecar JSON/routing logic)
- **Prefill Duration**: 12-18ms (HTTP roundtrip to prefill pod)
- **Decode Duration**: 500-700ms (HTTP roundtrip for full generation)

**True TTFT Breakdown:**
```
True TTFT (62.7ms) = Prefill Duration (15.1ms) + Coordinator Overhead (0.5ms) + vLLM Decode TTFT (47.5ms)
```

**NIXL KV Cache Transfer Metrics:**
- **Avg KV Transfer Time**: 50-60ms (TCP network transfer - RDMA would reduce to 15-25ms)
- **Avg MB per Transfer**: 5-8 MB (varies by prompt length/KV cache size)
- **Total KV Transfers**: Should match number of P/D requests
- **Failed Transfers**: 0 in healthy system
- **Transfer Time p95**: 60-80ms
- **NIXL Descriptors**: 150-200 per transfer (memory descriptors for KV blocks)

**Key Insight**: The coordinator overhead (0.5ms) is **pure CPU processing time**. The actual network overhead is in:
- Prefill HTTP roundtrip: ~15ms
- NIXL KV transfer: ~50-60ms (TCP)
- Decode HTTP roundtrip: ~500-700ms (includes generation)

---

## PART 1: Precise Prefix Cache & Intelligent Routing (5 minutes)

### 1.1 Introduction to Intelligent Routing with Prefix Cache (1 minute)

**SAY:**
> "Before we dive into P/D disaggregation, I want to show you how the **Gateway API Inference Extension (EPP)** uses intelligent routing to maximize prefix cache hits and avoid expensive KV cache transfers.
>
> This deployment uses a **decode-only pool** with 4 replicas. When multiple pods have overlapping cached prefixes, EPP's prefix cache scorer routes requests to the pod with the highest cache hit - avoiding the need to transfer KV cache data between pods.
>
> This is a critical optimization: **routing to avoid transfers** is faster than transferring cache. Let me show you how it works."

*[Switch to precise-prefix-cache-aware deployment]*

### 1.2 EPP Prefix Cache Scoring & Routing (2 minutes)

*[Open terminal or Grafana showing EPP metrics]*

**SAY:**
> "The EPP uses a **precise-prefix-cache-scorer** plugin that:
>
> 1. **Receives KV cache events** from all 4 decode pods via ZMQ (published by vLLM's `--kv-events-config`)
> 2. **Indexes cached prefixes** using the same hash algorithm as vLLM (`sha256_cbor` with block size 64)
> 3. **Scores each pod** based on how many KV cache blocks match the incoming request's prefix
> 4. **Routes to the highest-scoring pod** - the one with the most cached blocks
>
> **The result**: Requests with similar prefixes land on the same pod, maximizing cache reuse without network transfers.
>
> **Key EPP metrics to monitor:**
> - `llm_d_epp_prefix_cache_hits_total`: How many requests hit cached prefixes
> - `llm_d_epp_prefix_cache_scorer_matched_blocks`: Distribution of matched KV cache blocks
> - `llm_d_epp_routing_decision_duration`: How long scoring and routing takes
>
> This intelligent routing is transparent to vLLM - from vLLM's perspective, requests just arrive at the right pod. **No cross-pod KV transfers needed** because EPP ensures requests go where the cache already lives."

*[Show EPP pod logs or metrics showing prefix cache scoring in action]*

### 1.3 Architecture: Routing to Avoid Transfers (1 minute)

**SAY:**
> "Here's the key architectural difference between this guide and P/D disaggregation:
>
> **Precise-Prefix-Cache (this guide)**:
> - Architecture: **Decode-only pool** (4 replicas)
> - Routing: **EPP routes to pods with cached prefixes**
> - KV transfers: **Avoided** - requests go directly to the right pod
> - Optimization: Smart routing minimizes cache misses
>
> **P/D Disaggregation (next part)**:
> - Architecture: **Separate prefill and decode pools**
> - Routing: **Prefill MUST transfer cache to decode**
> - KV transfers: **Required** - measured by NIXL metrics
> - Optimization: Specialized hardware for each phase
>
> In this Part 1 setup, NIXL is available but idle - EPP's routing is so effective that cross-pod transfers rarely happen. When we switch to Part 2, we'll see NIXL actively transferring cache because P/D disaggregation forces transfers by design.
>
> Now let's switch to the P/D disaggregation guide where we'll see actual KV cache transfers, NIXL metrics, and coordinator-level observability..."

*[Transition to Part 2]*

---

## PART 2: P/D Disaggregation with Full Observability (7 minutes)

### 2.1 Introduction & Setup (30 seconds)

**SAY:**
> "Now switching to the **P/D disaggregation guide**. I have a 4-GPU deployment running Llama-3.1-8B with:
> - **2 single-GPU prefill workers** (TP=1 each) for handling concurrent prompt processing
> - **1 decode worker split across 2 GPUs** (TP=2) for larger KV cache capacity
> - **TCP networking via NIXL** for KV cache transfer between prefill and decode - we're not using RDMA in this demo
>
> This demonstrates **heterogeneous parallelism** - the key P/D optimization pattern. Production 70B deployments use the same strategy at larger scale.
>
> **Important distinction**: In this architecture, we can observe three distinct types of overhead:
> 1. **P/D Coordination Overhead** (~0.5ms): The sidecar's pure CPU time for JSON processing and routing logic
> 2. **HTTP Roundtrip Time** (~15ms prefill, ~500ms decode): Network and HTTP processing for inter-service calls
> 3. **NIXL KV Cache Transfer Time** (~50-60ms): The actual network transfer of KV cache data from prefill to decode
>
> The dashboard breaks down all three components so we can optimize each independently."

---

### 2.2 Start Load Generation (show terminal)

**RUN:**
```bash
cd /path/to/llm-d
./docs/monitoring/scripts/generate-load-pd-concurrent.sh 6 5
```

**SAY:**
> "I'm generating concurrent load with 6 workers running different traffic patterns for 5 minutes:
> - **Workers 1 & 6**: Long prompts + short outputs → maximizes the True TTFT vs vLLM TTFT gap
> - **Worker 2**: Long prompts + long outputs → shows prefill/decode breakdown
> - **Worker 3**: Mixed realistic traffic → production-like patterns
> - **Worker 4**: Bursty long requests → reveals queueing and coordination overhead
> - **Worker 5**: Streaming requests → tests streaming behavior in P/D mode
>
> These patterns exercise the full range of P/D scenarios and generate rich trace data."

*[Show the script running with real-time request logs for ~10 seconds]*

---

### 2.3 The Observability Problem (1 minute)

**SAY:**
> "While that's running, let's discuss the critical observability gap in P/D mode:
>
> In prefill-decode disaggregation, a single inference request flows through multiple components:
> 1. Gateway routes the request
> 2. **Coordinator sidecar** orchestrates P/D flow (~0.5ms CPU overhead)
> 3. **Prefill instance** processes the prompt and generates KV cache
> 4. **NIXL transfers KV cache** from prefill to decode over the network (~50-60ms with TCP)
> 5. **Decode instance** generates tokens using the transferred KV cache
>
> **The problem**: vLLM instances report metrics from their local perspective, not the client's true experience:
> - The **prefill instance** reports TTFT of ~15ms, which is just prompt processing
> - The **decode instance** reports TTFT of ~50ms, which seems fast but hides the full story
> - **Neither instance** knows about the 50-60ms NIXL KV transfer time or the overall flow
> - If you average prefill and decode TTFT, you get ~47ms - but the **true client TTFT is ~63ms**!
>
> This **15-16ms gap** is the observability problem we're solving with coordinator-level metrics, NIXL metrics, and distributed tracing."

*[Optional: Show diagram from proposal if available]*

---

### 2.4 Dashboard Overview (2-3 minutes)

*[Switch to Grafana P/D Coordinator Dashboard at http://localhost:3000/d/pd-coordinator-metrics]*

**SAY:**
> "This dashboard shows P/D coordinator metrics from Prometheus - these metrics are being added in an open PR. Let's walk through the key sections to see aggregate performance."

### Top Stats Panel

*[Point to the 4 stat panels at the top]*

**SAY:**
> "These four metrics tell the story:
>
> 1. **Avg Coordinator Overhead**: [point to value showing ~0.5ms] - This is **pure CPU time** for the sidecar's JSON processing and routing logic. Sub-millisecond! This proves the coordinator itself is extremely efficient.
>
> 2. **Avg True TTFT (End-to-End)**: [point to value showing ~63ms] - This is the **real TTFT** from the client's perspective. It includes prefill HTTP roundtrip, coordinator CPU overhead, and decode TTFT.
>
> 3. **Avg vLLM TTFT (Decode)**: [point to value showing ~47-50ms] - This shows only the decode instance's local view. Notice it's lower than True TTFT because it doesn't include the prefill phase.
>
> 4. **Total P/D Requests**: [point to value showing 61] - Number of disaggregated requests processed.
>
> **The key insight**: True TTFT (63ms) = Prefill Duration (15ms) + Coordinator Overhead (0.5ms) + vLLM Decode TTFT (47.5ms). The coordinator overhead is negligible - most time is in HTTP network roundtrips and NIXL KV transfers, which we'll see in the NIXL metrics below."

### Time Series Graphs

*[Scroll to the True TTFT and Total Duration graphs]*

**SAY:**
> "The time series shows how metrics evolve as we send varied load patterns:
> - **True TTFT spikes** when long prompts arrive from Workers 1, 2, 4, and 6
> - **Total Duration** shows end-to-end request latency including decode
> - The variation shows different ISL/OSL ratios from our concurrent workers - that's Input Sequence Length (prompt length) vs Output Sequence Length (generated tokens). Different workers send different prompt/output combinations to exercise various P/D scenarios."

*[Scroll to Component Breakdown section]*

**SAY:**
> "This component breakdown is critical for optimization:
> - **Prefill Duration**: ~15ms - HTTP roundtrip to prefill pod including prompt processing
> - **Coordinator Overhead**: ~0.5ms - Pure CPU time for sidecar JSON/routing logic (negligible!)
> - **Decode Duration**: ~500-700ms - HTTP roundtrip to decode pod for full token generation
>
> **Key distinction**: The coordinator overhead (~0.5ms) is **only CPU processing time**. The actual network time is in:
> - Prefill HTTP roundtrip (~15ms)
> - NIXL KV transfer (~50-60ms) - which we'll see in the NIXL metrics section below
> - Decode HTTP roundtrip (~500-700ms)
>
> If we saw performance issues:
> - **High prefill duration** → Add more prefill workers or reduce tensor parallelism
> - **High decode duration** → Increase tensor parallelism on decode or add replicas
> - **High coordinator overhead** → This is rarely the issue (it's sub-millisecond!)
> - **High NIXL transfer time** (from metrics below) → Network issue or need for RDMA upgrade
>
> This breakdown validates whether our 2P:1D ratio is optimal for this workload."

*[Scroll to Coordinator vs vLLM Metrics Comparison]*

**SAY:**
> "This comparison section directly shows the gap - same requests, different perspectives. The coordinator sees the full picture, vLLM sees only its local work."

---

### 2.5 NIXL KV Cache Transfer Metrics (1.5 minutes)

*[Scroll down to "KV Cache Transfer Metrics (NIXL Connector)" section in the same dashboard]*

**SAY:**
> "Now let's look at the **NIXL KV cache transfer metrics** - this is where we measure the actual network transfer overhead when prefill sends KV cache to decode.
>
> **Top Row - Summary Stats:**
> - **Avg KV Transfer Time**: [point to value showing ~58ms] - This is pure network transfer time with TCP. With RDMA, this would drop to 15-25ms - about 2-3x faster.
> - **Avg MB per Transfer**: [point to value showing ~8 MB] - Shows KV cache size per transfer, varies by prompt length
> - **Total KV Transfers**: [point to value showing ~2k] - Should match the number of P/D requests
> - **Failed Transfers**: [point to value showing 0] - Should be zero in a healthy system
>
> **Bottom Row - Time Series:**
> - **Transfer Time Percentiles** (p50, p95, p99): Shows distribution of transfer latency - p50 is ~52ms, p95 is ~141ms
> - **Transfer Post Time**: Post-transfer processing time after KV cache arrives
> - **Bytes Transferred Over Time**: Varies by prompt length - longer prompts = larger KV cache = more bytes
> - **NIXL Descriptors**: ~150-200 memory descriptors used per transfer
>
> **Key Insights:**
> 1. The **NIXL transfer time (~58ms)** is the dominant network overhead in P/D disaggregation
> 2. This is **much larger than coordinator overhead (~0.5ms)** - optimizing the sidecar won't help performance
> 3. **RDMA would reduce this to ~15-25ms** - these metrics help you quantify the ROI of RDMA infrastructure
> 4. Transfer size correlates with prompt length - longer prompts from Workers 1, 2, 4, 6 show larger transfers"

*[Show time series graphs, point out spikes correlating with long prompts]*

---

### 2.6 The Power of Tracing: What Metrics Can't Tell You (2 minutes)

**SAY:**
> "The metrics dashboard shows us **aggregate performance** - p50, p95, averages across all requests. But here's what metrics **cannot** tell us:
>
> - **Why** a specific request was slow
> - **Which exact path** a request took through the system
> - **What decisions** were made for individual requests
> - **The causal relationships** between operations
> - **Request-level context** like cache hits, routing decisions, user attributes
>
> This is where distributed tracing becomes essential. Let me show you an actual trace."

*[Switch to OpenShift Console → Observe → Traces]*

**SAY:**
> "I'm using the OpenShift Distributed Tracing console plugin to explore individual traces. While Grafana can query traces with TraceQL, the OpenShift console provides a better UI for exploring individual spans and their attributes. This gives us request-level visibility that aggregated metrics simply cannot provide."

*[Search for or select a P/D trace with reasonable duration]*

**SAY:**
> "Looking at this individual trace, we can see the complete story of a single request:
>
> ### 1. **gateway.request** span - Entry point
> - Shows the request entering the system with full context
>
> ### 2. **llm_d.epp.scorer.prefix_cache** span - Intelligent routing
> - **Attributes reveal**: Which pods had cached KV blocks for this specific prompt
> - Metrics can tell you average cache hit rate, but **only traces show cache decisions per request**
>
> ### 3. **llm_d.epp.profile_handler.pick** span - The P/D decision
> - **Critical attributes**: `decision`, `cache_hit_ratio`, `pd_threshold`, `user_input_bytes`
> - **This is the 'why'** - explains exactly why this request used P/D disaggregation vs decode-only
> - **Metrics cannot answer**: 'Why was request X routed differently than request Y?'
> - **Traces show**: The exact context and logic behind each routing decision
>
> ### 4. **llm_d.pd_proxy.request** span - Coordinator orchestration
> - Attributes: `true_ttft_ms`, `coordinator_overhead_ms`, `total_duration_ms`
> - Shows the **parent-child relationship** between prefill and decode operations
> - **Metrics show**: Average coordinator overhead across all requests
> - **Traces show**: The exact sequence and timing for this specific request
> - **Note**: The coordinator_overhead_ms is the sidecar processing time, separate from the KV cache network transfer measured by NIXL
>
> ### 5. **llm_d.pd_proxy.prefill** → **vllm:llm_request** (prefill)
> - Cross-service correlation: coordinator → vLLM instance
> - Shows prefill execution and KV cache generation
> - **Traces reveal**: The exact prefill instance selected and why
>
> ### 6. **llm_d.pd_proxy.decode** → **vllm:llm_request** (decode)
> - Token generation with transferred KV cache
> - Attributes: `gen_ai.usage.prompt_tokens`, `completion_tokens`
> - **Metrics show**: Average token counts
> - **Traces show**: Exact token usage for cost attribution to this user/application
>
> **The Key Difference:**
> - **Metrics answer**: 'What is our p95 latency?' (aggregate statistics)
> - **Traces answer**: 'Why was this request slow? What path did it take? What decisions were made?' (individual behavior and causality)
>
> For complex distributed systems like P/D disaggregation, you need **both**: metrics for monitoring overall health, and traces for understanding individual request behavior, debugging anomalies, and optimizing decision logic."

*[Click through spans to show attributes and parent-child relationships]*

---


### 2.7 Cost Attribution (30 seconds)

*[Show a vLLM span's attributes in the trace]*

**SAY:**
> "The vLLM spans include token usage via OpenTelemetry GenAI semantic conventions:
> - `gen_ai.usage.prompt_tokens`
> - `gen_ai.usage.completion_tokens`
> - Cached tokens when applicable
>
> Combined with coordinator timing metrics, we can calculate the **true cost per request** and attribute it back to applications or users for chargeback. This is essential for managing the high computational costs of running LLMs at scale."

---

### 2.8 Load Generation Results (30 seconds)

*[Return to terminal showing completed script output]*

**SAY:**
> "Our load generation has completed. The script shows:
> - Total requests generated: [read from output]
> - Success rate: [read from output]
> - Expected trace spans created across all components
>
> All of this trace data is now available in the OpenShift distributed tracing console with **100% sampling for this demo**. The metrics are aggregated in Prometheus and visualized in the Grafana dashboard. In production, we'd use 10% trace sampling to reduce overhead while maintaining observability."

---

### 2.9 Summary: Complete Observability Stack (1 minute)

**SAY:**
> "To summarize, the P/D coordinator dashboard provides complete observability across three layers:
>
> **1. Coordinator Metrics - End-to-End View:**
> - **True TTFT** (~63ms): Client perspective including all components
> - **Coordinator Overhead** (~0.5ms): Pure CPU time - proves sidecar is efficient
> - **Component Breakdown**: Prefill (~15ms), Decode (~500-700ms), Coordinator (~0.5ms)
> - **Aggregate Trends**: p50, p95, p99 across all requests
>
> **2. NIXL Transfer Metrics - Network Overhead:**
> - **KV Transfer Time** (~58ms with TCP): The dominant network overhead
> - **Transfer Size** (~8 MB): Varies by prompt length
> - **Transfer Percentiles**: p50, p95, p99 showing distribution
> - **RDMA ROI**: Quantifies how much RDMA would improve performance (2-3x faster)
>
> **3. Distributed Tracing - Request-Level Intelligence:**
> - **Why specific requests behaved differently**: Cache hits, routing decisions
> - **Decision context**: What routing/scheduling logic was applied
> - **Causal relationships**: The exact prefill→decode flow for each request
> - **Cost attribution**: Token usage for per-request chargeback
>
> **The Complete Picture**: Coordinator overhead is negligible (~0.5ms). The real overhead is NIXL KV transfer (~58ms) and HTTP roundtrips (~15ms prefill, ~500-700ms decode). This breakdown tells you exactly where to optimize."

---

## Quick Reference Commands
### Part 1: Precise Prefix Cache
```bash
# Deploy precise-prefix-cache-aware
cd guides/precise-prefix-cache-aware
helmfile apply -n ${NAMESPACE_PPCA}

# Verify 4 decode pods + EPP
kubectl get pods -n ${NAMESPACE_PPCA}

# Check EPP metrics for prefix cache scoring
kubectl logs -n ${NAMESPACE_PPCA} <epp-pod> | grep "prefix_cache"
```

### Part 2: P/D with Full Observability
```bash
# Deploy pd-disaggregation (with routing-proxy sidecar + NIXL metrics)
cd guides/pd-disaggregation
helmfile apply -n ${NAMESPACE_PD}

# Verify deployment: 2 prefill + 1 decode (each with routing-proxy sidecar)
kubectl get pods -n ${NAMESPACE_PD}
# Should show "2/2" for containers: vllm + routing-proxy

# Start load generation
./docs/monitoring/scripts/generate-load-pd-concurrent.sh 6 5

# Check coordinator metrics (from routing-proxy sidecar)
kubectl exec -n ${NAMESPACE_PD} <decode-pod> -c routing-proxy -- \
  curl -s localhost:9090/metrics | grep llm_d_inference_scheduler_pd_proxy

# Check NIXL metrics (from vLLM container)
kubectl exec -n ${NAMESPACE_PD} <decode-pod> -c vllm -- \
  curl -s localhost:8200/metrics | grep nixl
```

### Observability Access
```bash
# Metrics Dashboard (Grafana)
http://localhost:3000/d/pd-coordinator-metrics

# Distributed Traces (OpenShift Console)
# Navigate to: Observe → Traces
# Look for spans from:
# - llm-d-pd-proxy (coordinator spans)
# - llm-d-inference-scheduler (EPP/routing spans)
# - gateway-api-inference-extension (gateway spans)
# - vLLM instances (inference spans)
```

---

## Deployment Configuration Summary

**Architecture**: 4 GPUs (2 Prefill + 1 Decode with TP=2)
- Model: `meta-llama/Llama-3.1-8B-Instruct`
- Prefill: 2 replicas, TP=1 (Tensor Parallelism = 1), 1 GPU each
- Decode: 1 replica, TP=2 (model split across 2 GPUs)
- Networking: TCP via NIXL connector (not using RDMA)
- Tracing: OpenTelemetry with 100% sampling (demo mode)

**Key Files**:
- `guides/pd-disaggregation/ms-pd/values.yaml` - Model service config
- `guides/pd-disaggregation/gaie-pd/values.yaml` - Gateway/EPP config
- `docs/monitoring/scripts/generate-load-pd-concurrent.sh` - Load generator
- `docs/monitoring/grafana/dashboards/pd-coordinator-dashboard/pd-coordinator-metrics.json` - Dashboard

---

## Troubleshooting

### No traces showing up in OpenShift Console
```bash
# Check OpenTelemetry collector is running
kubectl get pods -n observability-hub | grep collector

# Check EPP tracing config
kubectl get cm -n ${NAMESPACE} -o yaml | grep -A10 OTEL

# Check vLLM tracing enabled
kubectl logs -n ${NAMESPACE} -l role=decode | grep -i "otlp\|tracing"

# Verify traces are being sent (check collector logs)
kubectl logs -n observability-hub -l app=opentelemetry-collector
```

### Load generation fails
```bash
# Check endpoint is accessible
curl http://localhost:8000/v1/models

# Check pods are ready
kubectl get pods -n ${NAMESPACE}

# Review load generation errors
# Script will show HTTP status codes for failures
```

### Metrics dashboard shows no data
```bash
# Verify Prometheus is scraping metrics
kubectl logs -n observability-hub -l app=prometheus

# Check that metrics are being exported
kubectl exec -n ${NAMESPACE} <pod-name> -- curl localhost:8000/metrics | grep llm_d_inference_scheduler

# Check time range in Grafana (top right)
# Ensure it covers when load generation ran

# Verify Prometheus queries in dashboard panels match metric names
```

---

**End of Demo Script**
