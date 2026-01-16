# Distributed Tracing Demo Script for P/D Disaggregation

**Demo Duration**: ~10 minutes
**Setup**: 4 GPUs, Llama-3.1-8B, TCP networking (NIXL connector)

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
- **True TTFT (Coordinator)**: 40-150ms
- **vLLM TTFT (Decode)**: 20-70ms
- **KV Transfer Overhead**: 5-20ms (using TCP networking - RDMA would reduce this to 2-8ms)
- **Gap Between Coordinator & vLLM**: 20-80ms ← **This is the observability problem we're solving**

---

## 1. Introduction & Setup (30 seconds)

**SAY:**
> "I'm demonstrating distributed tracing for llm-d with prefill-decode disaggregation. I have a 4-GPU deployment running Llama-3.1-8B with:
> - **2 single-GPU prefill workers** (TP=1 each) for handling concurrent prompt processing
> - **1 decode worker split across 2 GPUs** (TP=2) for larger KV cache capacity
> - **TCP networking via NIXL** for KV cache transfer between prefill and decode - we're not using RDMA in this demo
>
> This demonstrates **heterogeneous parallelism** - the key P/D optimization pattern. Production 70B deployments use the same strategy at larger scale."

---

## 2. Start Load Generation (show terminal)

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

## 3. The Observability Problem (1 minute)

**SAY:**
> "While that's running, let's discuss the critical observability gap in P/D mode:
>
> In prefill-decode disaggregation, a single inference request flows through multiple components:
> 1. Gateway routes the request
> 2. Prefill instance processes the prompt and generates KV cache
> 3. KV cache is transferred over RDMA to the decode instance
> 4. Decode instance generates tokens using the transferred KV cache
>
> **The problem**: vLLM instances report metrics from their local perspective, not the client's true experience:
> - The **prefill instance** reports TTFT that **excludes** KV cache transfer time
> - The **decode instance** reports artificially **low** TTFT because the KV cache is already transferred
> - **Neither instance** knows about gateway routing or scheduling overhead
>
> Without coordinator-level tracing, you cannot accurately measure P/D performance or optimize it. You're flying blind."

*[Optional: Show diagram from proposal if available]*

---

## 4. Dashboard Overview (2-3 minutes)

*[Switch to Grafana P/D Coordinator Dashboard at http://localhost:3000/d/pd-coordinator-metrics]*

**SAY:**
> "This dashboard shows P/D coordinator metrics from Prometheus - these metrics are being added in an open PR. Let's walk through the key sections to see aggregate performance."

### Top Stats Panel

*[Point to the 4 stat panels at the top]*

**SAY:**
> "These four metrics tell the story:
>
> 1. **Avg True TTFT (Coordinator)**: [point to value] - This is the **real TTFT** from the client's perspective. It includes gateway routing, scheduling, prefill, and KV cache transfer coordination.
>
> 2. **Avg vLLM TTFT (Decode)**: [point to value] - Notice this is **significantly lower**. The decode instance doesn't know about the prefill or transfer time.
>
> 3. **Avg KV Transfer Overhead**: [point to value] - We're using TCP networking via NIXL, so we see 5-20ms overhead. With RDMA (RoCE + GPUDirect), this would drop to 2-8ms - about 2-3x lower. This metric helps quantify the value of RDMA upgrades.
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
> - **Prefill Duration**: Time spent processing the prompt
> - **Decode Duration**: Time spent generating output tokens
> - **KV Transfer Overhead**: Network transfer and coordination time (TCP in this demo)
>
> If we saw:
> - **High prefill duration** → Add more prefill workers or reduce tensor parallelism
> - **High decode duration** → Increase tensor parallelism on decode or add replicas
> - **High KV transfer overhead** → Network issue or need for RDMA upgrade
>
> This breakdown validates whether our 2P:1D ratio is optimal for this workload."

*[Scroll to Coordinator vs vLLM Metrics Comparison]*

**SAY:**
> "This comparison section directly shows the gap - same requests, different perspectives. The coordinator sees the full picture, vLLM sees only its local work."

---

## 5. The Power of Tracing: What Metrics Can't Tell You (3-4 minutes)

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
> - Attributes: `true_ttft_ms`, `kv_transfer_overhead_ms`, `total_duration_ms`
> - Shows the **parent-child relationship** between prefill and decode operations
> - **Metrics show**: Average overhead across all requests
> - **Traces show**: The exact sequence and timing for this specific request
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

## 6. Network Transfer Overhead (30 seconds)

**SAY:**
> "Notice our KV transfer overhead is in the 5-20ms range. This demo deployment uses **TCP networking** for KV cache transfer via NIXL - **we're not using RDMA**.
>
> In production deployments with **RDMA (RoCE with GPUDirect)**, this overhead would drop to 2-8ms - about 2-3x lower. RDMA allows GPUs to transfer data directly without CPU involvement, making P/D disaggregation much more efficient.
>
> The coordinator metrics let us **quantify exactly how much RDMA would improve performance** - this is invaluable for infrastructure planning and optimization decisions."

---

## 7. Cost Attribution (30 seconds)

*[Show a vLLM span's attributes in the trace]*

**SAY:**
> "The vLLM spans include token usage via OpenTelemetry GenAI semantic conventions:
> - `gen_ai.usage.prompt_tokens`
> - `gen_ai.usage.completion_tokens`
> - Cached tokens when applicable
>
> Combined with coordinator timing metrics, we can calculate the **true cost per request** and attribute it back to applications or users for chargeback. This is essential for managing the high computational costs of running LLMs at scale."

---

## 8. Load Generation Results (30 seconds)

*[Return to terminal showing completed script output]*

**SAY:**
> "Our load generation has completed. The script shows:
> - Total requests generated: [read from output]
> - Success rate: [read from output]
> - Expected trace spans created across all components
>
> All of this trace data is now available in the OpenShift distributed tracing console with **100% sampling for this demo**. The metrics are aggregated in Prometheus and visualized in the Grafana dashboard. In production, we'd use 10% trace sampling to reduce overhead while maintaining observability."

---

## 9. Closing: Why This Matters (1 minute)

**SAY:**
> "To summarize, combining metrics and distributed tracing provides comprehensive observability for P/D disaggregation:
>
> **Metrics (Dashboard) Give You:**
> - **Aggregate performance**: p50, p95, p99 latencies across all requests
> - **Trend analysis**: How performance evolves over time
> - **System health**: Overall throughput and error rates
> - **Component breakdown**: Average time in prefill, decode, KV transfer
>
> **Tracing (Individual Spans) Gives You:**
> - **Request-level intelligence**: Why specific requests behaved differently
> - **Decision context**: What routing/scheduling decisions were made and why
> - **Causal relationships**: The exact sequence and parent-child flow of operations
> - **Root cause analysis**: Drill into problematic requests to find exact failure points
> - **Cost attribution**: Token usage for per-request chargeback
>
> **Why You Need Both:**
> - Metrics tell you **'what'** is happening (we're seeing high p95 latency)
> - Traces tell you **'why'** it's happening (these requests are slow because cache misses trigger full prefill)
> - Together, they enable both **monitoring** (aggregate health) and **debugging** (individual behavior)
>
> **For complex distributed architectures like P/D disaggregation, this combination isn't optional - it's essential infrastructure for operating at scale.**
>
> This demo used a 4-GPU, 8B model setup with TCP networking. Production 70B deployments would show the same architecture pattern at larger scale: 4 prefill workers and TP=4 decode with RDMA networking, achieving TTFT in the 50-300ms range and KV transfer overhead of 10-50ms (2-8ms with RDMA). **The observability problem we're solving is identical** - without both coordinator-level metrics and distributed traces, you cannot effectively optimize P/D disaggregation regardless of scale."

---

## Quick Reference Commands

### Start Demo
```bash
# Deploy the P/D stack
cd guides/pd-disaggregation
helmfile apply -n ${NAMESPACE}

# Verify deployment
kubectl get pods -n ${NAMESPACE}
# Expect: 2 prefill pods, 1 decode pod, 1 gateway pod

# Check pods are ready and running
kubectl get pods -n ${NAMESPACE} -w

# Start load generation
./docs/monitoring/scripts/generate-load-pd-concurrent.sh 6 5
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
