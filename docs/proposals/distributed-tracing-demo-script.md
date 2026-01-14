# Distributed Tracing Demo Script for P/D Disaggregation

**Demo Duration**: ~10 minutes
**Setup**: 4 GPUs, Llama-3.1-8B, TCP networking (NIXL connector)

---

## Demo Setup Summary

### Infrastructure
- **Cluster**: 4 GPUs with TCP networking for KV cache transfer
- **Model**: Llama-3.1-8B-Instruct
- **Architecture**:
  - 2 Prefill workers (TP=1 each, 1 GPU each)
  - 1 Decode worker (TP=2, 2 GPUs)
  - Heterogeneous parallelism: replicated prefill for throughput, wider decode for KV cache memory

### Expected Metrics
- **True TTFT (Coordinator)**: 40-150ms
- **vLLM TTFT (Decode)**: 20-70ms
- **KV Transfer Overhead**: 5-20ms (TCP networking, would be 2-8ms with RDMA)
- **Gap Between Coordinator & vLLM**: 20-80ms ← **This is the observability problem we're solving**

---

## 1. Introduction & Setup (30 seconds)

**SAY:**
> "I'm demonstrating distributed tracing for llm-d with prefill-decode disaggregation. I have a 4-GPU deployment running Llama-3.1-8B with:
> - **2 single-GPU prefill workers** for handling concurrent prompt processing
> - **1 decode worker split across 2 GPUs** for larger KV cache capacity
> - **TCP networking via NIXL** for KV cache transfer between prefill and decode
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
> "This dashboard is powered entirely by distributed trace data from OpenTelemetry. Let's walk through the key sections."

### Top Stats Panel

*[Point to the 4 stat panels at the top]*

**SAY:**
> "These four metrics tell the story:
>
> 1. **Avg True TTFT (Coordinator)**: [point to value] - This is the **real TTFT** from the client's perspective. It includes gateway routing, scheduling, prefill, and KV cache transfer coordination.
>
> 2. **Avg vLLM TTFT (Decode)**: [point to value] - Notice this is **significantly lower**. The decode instance doesn't know about the prefill or transfer time.
>
> 3. **Avg KV Transfer Overhead**: [point to value] - With RDMA, this is only 2-8ms. Without RDMA, we'd see 3-5x higher overhead. This validates our networking setup.
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
> - The variation shows different ISL/OSL ratios from our concurrent workers"

*[Scroll to Component Breakdown section]*

**SAY:**
> "This component breakdown is critical for optimization:
> - **Prefill Duration**: Time spent processing the prompt
> - **Decode Duration**: Time spent generating output tokens
> - **KV Transfer Overhead**: RDMA transfer coordination time
>
> If we saw:
> - **High prefill duration** → Add more prefill workers or reduce TP
> - **High decode duration** → Increase TP on decode or add replicas
> - **High KV transfer overhead** → RDMA tuning issue or network contention
>
> This breakdown validates whether our 2P:1D ratio is optimal for this workload."

*[Scroll to Coordinator vs vLLM Metrics Comparison]*

**SAY:**
> "This comparison section directly shows the gap - same requests, different perspectives. The coordinator sees the full picture, vLLM sees only its local work."

---

## 5. Exploring Individual Traces (2 minutes)

*[Open Grafana → Explore → Select Tempo datasource]*

**SAY:**
> "Let's look at an individual trace to see the end-to-end flow."

**RUN TraceQL Query:**
```
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"}
```

*[Select a trace with reasonable duration, click to open]*

**SAY:**
> "In this trace, you can see the complete request lifecycle across all components:
>
> 1. **gateway.request** span - The top-level request entering the system
>
> 2. **llm_d.epp.scorer.prefix_cache** span - Shows KV cache-aware routing decisions
>    - Attributes show which pods had cached blocks for this request
>
> 3. **llm_d.epp.profile_handler.pick** span - The P/D disaggregation decision
>    - Look at attributes: `decision`, `cache_hit_ratio`, `pd_threshold`, `user_input_bytes`
>    - This shows **why** the request chose prefill+decode vs decode-only mode
>
> 4. **llm_d.pd_proxy.request** span - The coordinator's view
>    - Key metrics here: `true_ttft_ms`, `kv_transfer_overhead_ms`, `total_duration_ms`
>    - **This is the source of truth for client-experienced latency**
>
> 5. **llm_d.pd_proxy.prefill** → **vllm:llm_request** (prefill) - Prefill execution
>    - Shows prefill duration and KV cache generation
>
> 6. **llm_d.pd_proxy.decode** → **vllm:llm_request** (decode) - Decode execution
>    - Shows token generation with transferred KV cache
>    - Attributes include token counts: `gen_ai.usage.prompt_tokens`, `completion_tokens`
>
> **This end-to-end visibility is impossible to get from metrics alone** - distributed tracing connects these components across network boundaries and shows the true critical path."

*[Optional: Click on specific spans to show attributes]*

---

## 6. Network Transfer Overhead (30 seconds)

**SAY:**
> "Notice our KV transfer overhead is in the 5-20ms range. This deployment uses **TCP networking** for KV cache transfer via NIXL.
>
> In production deployments with **RDMA (RoCE with GPUDirect)**, this overhead would drop to 2-8ms - about 2-3x lower. RDMA allows GPUs to transfer data directly without CPU involvement, making P/D disaggregation much more efficient.
>
> The tracing data lets us **quantify exactly how much RDMA would improve performance** - this is invaluable for infrastructure planning and optimization decisions."

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
> All of this trace data is now queryable in Grafana with **100% sampling for this demo**. In production, we'd use 10% sampling to reduce overhead while maintaining observability."

---

## 9. Closing: Why This Matters (1 minute)

**SAY:**
> "To summarize, distributed tracing with P/D coordinator metrics provides five critical capabilities:
>
> **1. True Performance Visibility**
> - Real TTFT measurements, not misleading vLLM instance metrics
> - Coordinator-level view that matches client experience
>
> **2. Optimization Guidance**
> - Component breakdown shows exactly where to tune: prefill workers, decode TP, RDMA networking
> - Validates whether xPyD ratios are optimal for your workload
>
> **3. Decision Intelligence**
> - Understand when and why P/D disaggregation is used vs skipped
> - Tune selective P/D thresholds based on actual request characteristics
>
> **4. Cost Attribution**
> - Token usage tracking for per-request, per-application, per-model cost analysis
> - Essential for chargeback and budget optimization
>
> **5. Root Cause Analysis**
> - End-to-end traces for debugging latency issues across distributed components
> - Error attribution showing exact failure points
>
> **For complex distributed architectures like P/D disaggregation, tracing isn't optional - it's essential infrastructure for operating at scale.**
>
> This demo used a 4-GPU, 8B model setup. Production 70B deployments would show the same architecture pattern at larger scale: 4 prefill workers and TP=4 decode, with TTFT in the 50-300ms range and KV transfer overhead of 10-50ms. **The observability problem we're solving is identical** - without coordinator-level metrics, you cannot optimize P/D disaggregation regardless of scale."

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

### Grafana Access
```bash
# Dashboard URL
http://localhost:3000/d/pd-coordinator-metrics

# Tempo Explore for traces
http://localhost:3000/explore
```

### Useful TraceQL Queries
```
# All P/D requests
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"}

# Requests with high KV transfer overhead
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"}
| select(span.llm_d.pd_proxy.kv_transfer_overhead_ms)
| span.llm_d.pd_proxy.kv_transfer_overhead_ms > 10

# Profile handler decisions
{resource.service.name="llm-d-inference-scheduler" && name="llm_d.epp.profile_handler.pick"}

# Gateway requests
{resource.service.name="gateway-api-inference-extension" && name="gateway.request"}
```

---

## Deployment Configuration Summary

**Architecture**: 4 GPUs (2 Prefill + 1 Decode with TP=2)
- Model: `meta-llama/Llama-3.1-8B-Instruct`
- Prefill: 2 replicas, TP=1, 1 GPU each
- Decode: 1 replica, TP=2, 2 GPUs
- Networking: TCP via NIXL connector
- Tracing: OpenTelemetry with 100% sampling (demo mode)

**Key Files**:
- `guides/pd-disaggregation/ms-pd/values.yaml` - Model service config
- `guides/pd-disaggregation/gaie-pd/values.yaml` - Gateway/EPP config
- `docs/monitoring/scripts/generate-load-pd-concurrent.sh` - Load generator
- `docs/monitoring/grafana/dashboards/pd-coordinator-dashboard/pd-coordinator-metrics.json` - Dashboard

---

## Troubleshooting

### No traces showing up
```bash
# Check OpenTelemetry collector is running
kubectl get pods -n observability-hub | grep collector

# Check EPP tracing config
kubectl get cm -n ${NAMESPACE} -o yaml | grep -A10 OTEL

# Check vLLM tracing enabled
kubectl logs -n ${NAMESPACE} -l role=decode | grep -i "otlp\|tracing"
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

### Dashboard shows no data
```bash
# Verify Tempo is receiving traces
kubectl logs -n observability-hub -l app=tempo

# Check time range in Grafana (top right)
# Ensure it covers when load generation ran

# Verify TraceQL query syntax in dashboard panels
```

---

**End of Demo Script**
