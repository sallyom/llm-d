# Distributed Tracing Demo Script for P/D Disaggregation

**Demo Duration**: ~15 minutes (Part 1: 5min + Part 2a: 5min + Part 2b: 5min)
**Setup**: 4 GPUs, Llama-3.1-8B, TCP networking (NIXL connector)
**Guides Used**: `precise-prefix-cache-aware`, `pd-disaggregation`, `pd-disaggregation-nixl`

---

## Demo Overview

This demo has three parts:

**Part 1 (5 min)**: Precise Prefix Cache Awareness & Intelligent Routing
- Guide: `precise-prefix-cache-aware`
- Focus: EPP's intelligent routing based on prefix cache scoring
- Metrics: `llm_d_epp_prefix_cache_*` scoring metrics, cache hit rates
- Architecture: Decode-only pool (4 replicas) where EPP routes to pods with cached prefixes
- Key point: **No cross-pod KV transfers** - EPP routes requests to avoid transfers

**Part 2a (5 min)**: P/D Disaggregation with Coordinator Metrics & Distributed Tracing
- Guide: `pd-disaggregation`
- Focus: Coordinator-level observability for P/D disaggregation
- Metrics: `llm_d_inference_scheduler_pd_proxy_*` (coordinator overhead, True TTFT)
- Spans: `llm_d.pd_proxy.request`, `llm_d.pd_proxy.prefill`, `llm_d.pd_proxy.decode`
- Architecture: Prefill → Decode with **routing-proxy sidecar** for orchestration
- Key point: **End-to-end observability** from client perspective

**Part 2b (5 min)**: P/D Disaggregation with NIXL KV Cache Transfer Metrics
- Guide: `pd-disaggregation-nixl`
- Focus: Measure actual KV cache network transfer overhead
- Metrics: `vllm:nixl_xfer_time_seconds`, `vllm:nixl_bytes_transferred`, `vllm:nixl_post_time_seconds`
- Architecture: Prefill → Decode with **native NIXL** (no routing-proxy)
- Key point: **KV transfers visible** - shows actual network transfer time (5-20ms TCP, 2-8ms RDMA)

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

**Part 2a - P/D Disaggregation with Coordinator (pd-disaggregation):**
- **True TTFT (Coordinator)**: 40-150ms
- **vLLM TTFT (Decode)**: 20-70ms
- **P/D Coordination Overhead**: 15-50ms (routing-proxy sidecar processing)
- **Gap Between Coordinator & vLLM**: 20-80ms ← **This is the observability problem we're solving**

**Part 2b - P/D Disaggregation with NIXL (pd-disaggregation-nixl):**
- **KV Cache Transfer Time**: 5-20ms (NIXL network transfer via TCP - RDMA would reduce to 2-8ms)
- **Avg Bytes per Transfer**: Varies by prompt length (KV cache size)
- **Total KV Transfers**: Increases as requests flow through prefill→decode

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

## PART 2a: P/D Disaggregation with Coordinator Metrics & Tracing (5 minutes)

### 2.1 Introduction & Setup (30 seconds)

**SAY:**
> "Now switching to the **P/D disaggregation guide**. I have a 4-GPU deployment running Llama-3.1-8B with:
> - **2 single-GPU prefill workers** (TP=1 each) for handling concurrent prompt processing
> - **1 decode worker split across 2 GPUs** (TP=2) for larger KV cache capacity
> - **TCP networking via NIXL** for KV cache transfer between prefill and decode - we're not using RDMA in this demo
>
> This demonstrates **heterogeneous parallelism** - the key P/D optimization pattern. Production 70B deployments use the same strategy at larger scale.
>
> **Important distinction**: In this architecture, there are TWO types of overhead:
> 1. **P/D Coordination Overhead** (15-50ms): The sidecar's JSON processing and HTTP coordination between prefill and decode
> 2. **KV Cache Transfer Time** (5-20ms): The actual network transfer of KV cache data via NIXL (which we just saw in Part 1)
>
> The coordinator metrics track the total coordination overhead, which includes but is not limited to the KV transfer time."

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
> 2. Prefill instance processes the prompt and generates KV cache
> 3. Coordinator sidecar orchestrates transfer of KV cache to decode
> 4. KV cache is transferred over the network via NIXL (the overhead we saw in Part 1)
> 5. Decode instance generates tokens using the transferred KV cache
>
> **The problem**: vLLM instances report metrics from their local perspective, not the client's true experience:
> - The **prefill instance** reports TTFT that **excludes** coordination and KV transfer time
> - The **decode instance** reports artificially **low** TTFT because the KV cache is already transferred
> - **Neither instance** knows about gateway routing, scheduling, or coordination overhead
>
> Without coordinator-level metrics and tracing, you cannot accurately measure P/D performance or optimize it. You're flying blind."

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
> 1. **Avg True TTFT (Coordinator)**: [point to value] - This is the **real TTFT** from the client's perspective. It includes gateway routing, scheduling, prefill, coordination overhead, and KV cache transfer.
>
> 2. **Avg vLLM TTFT (Decode)**: [point to value] - Notice this is **significantly lower**. The decode instance doesn't know about the prefill or transfer time.
>
> 3. **Avg Coordinator Overhead**: [point to value] - This is the **P/D coordination overhead** - the sidecar's JSON processing and HTTP coordination between prefill and decode. This is **separate from** the KV cache transfer time we saw in Part 1. The coordinator overhead includes HTTP serialization, deserialization, and orchestration logic.
>
> 4. **Total P/D Requests**: [point to value] - Number of disaggregated requests processed.
>
> **This gap between coordinator TTFT and vLLM TTFT proves the observability problem** - if you only looked at vLLM metrics, you'd think performance was much better than reality."

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
> - **Prefill Duration**: Time spent processing the prompt in the prefill instance
> - **Decode Duration**: Time spent generating output tokens in the decode instance
> - **Coordinator Overhead**: P/D coordination overhead - the sidecar's JSON processing, HTTP serialization, and orchestration between prefill and decode
>
> **Note**: The coordinator overhead (sidecar processing) is **separate from** the KV cache transfer time (NIXL network transfer) we saw in Part 1. The coordinator manages the overall flow, while NIXL handles the actual KV cache data transfer.
>
> If we saw:
> - **High prefill duration** → Add more prefill workers or reduce tensor parallelism
> - **High decode duration** → Increase tensor parallelism on decode or add replicas
> - **High coordinator overhead** → Optimize sidecar processing or reduce HTTP/JSON overhead
> - **High KV transfer time** (from NIXL metrics) → Network issue or need for RDMA upgrade
>
> This breakdown validates whether our 2P:1D ratio is optimal for this workload."

*[Scroll to Coordinator vs vLLM Metrics Comparison]*

**SAY:**
> "This comparison section directly shows the gap - same requests, different perspectives. The coordinator sees the full picture, vLLM sees only its local work."

---

### 2.5 The Power of Tracing: What Metrics Can't Tell You (3-4 minutes)

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

### 2.6 Understanding the Two Types of Overhead (30 seconds)

**SAY:**
> "It's important to understand the difference between the two types of overhead we're measuring:
>
> **1. P/D Coordination Overhead (Sidecar Metrics)**: 15-50ms
> - The coordinator sidecar's JSON processing and HTTP orchestration
> - Includes serialization, deserialization, request routing between prefill/decode
> - Measured by: `llm_d_inference_scheduler_pd_proxy_coordinator_overhead_milliseconds`
> - This is what we see in the dashboard's 'Avg Coordinator Overhead' panel
>
> **2. KV Cache Transfer Time (NIXL Metrics)**: 5-20ms with TCP
> - The actual network transfer of KV cache data from prefill to decode
> - Measured by: `vllm:nixl_xfer_time_seconds`, `vllm:nixl_bytes_transferred`
> - This is what we saw in Part 1 with the precise-prefix-cache-aware guide
> - With **RDMA (RoCE + GPUDirect)**, this drops to 2-8ms - about 2-3x faster
>
> **The total P/D overhead** includes both: coordinator orchestration + KV cache network transfer. By measuring them separately, we can optimize each component independently."

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

### 2.9 Summary: Why Coordinator Observability Matters (1 minute)

**SAY:**
> "To summarize Part 2a, coordinator-level metrics and distributed tracing provide the end-to-end observability that's missing when you only look at vLLM instance metrics:
>
> **Metrics (Dashboard) Give You:**
> - **True TTFT** from client perspective, not instance perspective
> - **P/D coordination overhead** showing sidecar processing time
> - **Component breakdown**: Time in prefill vs decode vs coordination
> - **Aggregate trends**: p50, p95, p99 across all requests
>
> **Tracing (Individual Spans) Gives You:**
> - **Request-level intelligence**: Why specific requests behaved differently
> - **Decision context**: What routing/scheduling decisions were made and why
> - **Causal relationships**: The exact prefill→decode flow for each request
> - **Cost attribution**: Token usage for per-request chargeback
>
> But there's one more piece of the puzzle: the actual **network transfer overhead** of moving KV cache data. Let me show you that now..."

*[Transition to Part 2b]*

---

## PART 2b: P/D Disaggregation with NIXL KV Cache Transfer Metrics (5 minutes)

### 2b.1 Introduction: The Network Transfer Overhead (30 seconds)

**SAY:**
> "In Part 2a, we saw the **coordinator's view** of P/D - the orchestration overhead and end-to-end latency. But there's another critical metric: the actual **KV cache network transfer time** when prefill sends cache to decode.
>
> The routing-proxy sidecar hides these metrics because it handles coordination at a higher level. To measure the raw network transfer overhead, we need to remove the sidecar and let vLLM instances communicate directly via NIXL.
>
> I've deployed the **`pd-disaggregation-nixl` guide** - same architecture (2 prefill, 1 decode), but without the routing-proxy sidecar. This exposes vLLM's native NIXL metrics."

*[Switch to pd-disaggregation-nixl deployment]*

---

### 2b.2 Start Load & Check NIXL Metrics (2 minutes)

**RUN:**
```bash
# Generate load on the NIXL-enabled stack
./docs/monitoring/scripts/generate-load-pd-concurrent.sh 6 2
```

**SAY:**
> "I'm sending the same concurrent load patterns we used before. As requests flow through prefill→decode, the NIXL connector transfers KV cache data over the network. Let's check the metrics directly from a pod."

*[While load is running, exec into a pod to show NIXL metrics]*

**RUN:**
```bash
kubectl exec -n <namespace> <decode-pod> -- curl -s localhost:8200/metrics | grep nixl
```

**SHOW:**
```
vllm:nixl_xfer_time_seconds_bucket{le="0.005",...} 15
vllm:nixl_xfer_time_seconds_bucket{le="0.01",...} 45
vllm:nixl_xfer_time_seconds_bucket{le="0.025",...} 89
vllm:nixl_xfer_time_seconds_sum{...} 1.234
vllm:nixl_xfer_time_seconds_count{...} 120

vllm:nixl_bytes_transferred_sum{...} 52428800  # ~50 MB total
vllm:nixl_bytes_transferred_count{...} 120
```

**SAY:**
> "Perfect! Now we're seeing the actual NIXL KV cache transfer metrics:
>
> - **`vllm:nixl_xfer_time_seconds`**: Histogram of transfer duration - most transfers are 5-20ms with TCP
> - **`vllm:nixl_bytes_transferred`**: Total KV cache data transferred - varies by prompt length
> - **`vllm:nixl_post_time_seconds`**: Post-transfer processing time
>
> These metrics only appear in P/D disaggregation because prefill **must** transfer to decode. In the precise-prefix-cache guide (Part 1), EPP's smart routing avoided transfers entirely, so NIXL sat idle."

---

### 2b.3 Grafana Dashboard: KV Cache Transfer Metrics (1.5 minutes)

*[Switch to Grafana dashboard - scroll to "KV Cache Transfer Metrics (NIXL Connector)" section]*

**SAY:**
> "I've added a dashboard section specifically for NIXL metrics. Let's look at what we're seeing:
>
> **Top Row - Summary Stats:**
> - **Avg KV Transfer Time**: [point to value] - This is pure network transfer time with TCP
> - **Avg MB per Transfer**: [point to value] - Shows KV cache size per transfer
> - **Total KV Transfers**: [point to value] - How many prefill→decode transfers occurred
> - **Failed Transfers**: Should be zero in a healthy system
>
> **Bottom Row - Time Series:**
> - **Transfer Time Percentiles** (p50, p95, p99): Shows distribution of transfer latency
> - **Bytes Transferred Over Time**: Correlates with prompt lengths
> - **NIXL Descriptors**: Memory descriptor usage
>
> **Key Insight**: With **TCP networking** (what we're using), transfers are 5-20ms. With **RDMA + GPUDirect**, this drops to 2-8ms - about 2-3x faster. These metrics help you **quantify the ROI of RDMA infrastructure** for KV cache sharing."

*[Show time series graphs, point out spikes correlating with long prompts]*

---

### 2b.4 Comparison: Coordinator Overhead vs KV Transfer Time (1 minute)

**SAY:**
> "Now we've seen both types of overhead in P/D disaggregation:
>
> **1. P/D Coordination Overhead** (Part 2a - with sidecar):
> - **What it measures**: Routing-proxy sidecar's HTTP/JSON orchestration
> - **Typical range**: 15-50ms
> - **Metric**: `llm_d_inference_scheduler_pd_proxy_coordinator_overhead_milliseconds`
> - **Includes**: Request routing, serialization, deserialization, HTTP handling
>
> **2. KV Cache Transfer Time** (Part 2b - this part):
> - **What it measures**: Raw network transfer of KV cache data via NIXL
> - **Typical range**: 5-20ms with TCP, 2-8ms with RDMA
> - **Metric**: `vllm:nixl_xfer_time_seconds`
> - **Varies by**: KV cache size (prompt length), network speed, RDMA vs TCP
>
> **Total P/D Overhead** = Coordination + KV Transfer + EPP Routing + vLLM Processing
>
> By measuring these separately:
> - **High coordinator overhead** → Optimize sidecar processing (async, reduce serialization)
> - **High KV transfer time** → Network issue or need RDMA upgrade
> - **Both low but still slow** → Look at EPP routing or vLLM inference itself
>
> This granularity is essential for optimization in production."

---

### 2b.5 Final Summary: Complete Observability Picture (1 minute)

**SAY:**
> "Let's wrap up by summarizing all three parts of this demo:
>
> **Part 1 - Precise Prefix Cache & Intelligent Routing:**
> - **Architecture**: Decode-only pool (4 replicas)
> - **Key Learning**: EPP's smart routing avoids KV cache transfers by sending requests to pods that already have the cache
> - **Metrics**: `llm_d_epp_prefix_cache_*` for routing decisions
> - **NIXL Transfers**: None - routing eliminates the need
>
> **Part 2a - P/D Disaggregation with Coordinator Observability:**
> - **Architecture**: 2 Prefill + 1 Decode with routing-proxy sidecar
> - **Key Learning**: End-to-end metrics and tracing show the true client experience, not just vLLM's local view
> - **Metrics**: `llm_d_inference_scheduler_pd_proxy_*` for coordinator overhead and True TTFT
> - **Spans**: Distributed traces showing prefill→decode flow and decision context
> - **NIXL Transfers**: Hidden by sidecar coordination layer
>
> **Part 2b - P/D Disaggregation with NIXL Metrics:**
> - **Architecture**: Same 2 Prefill + 1 Decode but **without** routing-proxy
> - **Key Learning**: Native NIXL metrics reveal the raw network transfer overhead
> - **Metrics**: `vllm:nixl_xfer_time_seconds`, `vllm:nixl_bytes_transferred`
> - **NIXL Transfers**: Visible! 5-20ms with TCP, 2-8ms with RDMA
>
> **Why All Three Matter:**
>
> - **Part 1** shows how to **avoid** KV transfers through intelligent routing
> - **Part 2a** shows **end-to-end observability** when transfers are necessary (P/D architecture)
> - **Part 2b** shows **network transfer metrics** to optimize infrastructure (TCP vs RDMA)
>
> **In production**, you'd typically run Part 2a (with coordinator observability) for day-to-day operations, and deploy Part 2b temporarily when you need to analyze network transfer performance or justify RDMA investments.
>
> **The big picture**: Without this multi-layered observability - EPP metrics, coordinator metrics, NIXL metrics, and distributed traces - you're flying blind in disaggregated LLM serving. This demo gives you the complete toolkit for operating and optimizing at scale."

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

### Part 2a: P/D with Coordinator Observability
```bash
# Deploy pd-disaggregation (with routing-proxy sidecar)
cd guides/pd-disaggregation
helmfile apply -n ${NAMESPACE_PD}

# Verify deployment: 2 prefill + 1 decode + gateway
kubectl get pods -n ${NAMESPACE_PD}

# Start load generation
./docs/monitoring/scripts/generate-load-pd-concurrent.sh 6 5

# Check coordinator metrics
kubectl exec -n ${NAMESPACE_PD} <decode-pod> -c routing-proxy -- \
  curl -s localhost:9090/metrics | grep llm_d_inference_scheduler_pd_proxy
```

### Part 2b: P/D with NIXL Metrics
```bash
# Deploy pd-disaggregation-nixl (without routing-proxy)
cd guides/pd-disaggregation-nixl
helmfile apply -n ${NAMESPACE_NIXL}

# Verify deployment: 2 prefill + 1 decode (no sidecar)
kubectl get pods -n ${NAMESPACE_NIXL}
# Should show "1/1" for vllm only, not "2/2"

# Start load generation
./docs/monitoring/scripts/generate-load-pd-concurrent.sh 6 2

# Check NIXL metrics appear
kubectl exec -n ${NAMESPACE_NIXL} <decode-pod> -- \
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
