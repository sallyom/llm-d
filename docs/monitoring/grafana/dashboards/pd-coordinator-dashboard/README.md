# P/D Coordinator Metrics Dashboard

This Grafana dashboard visualizes distributed tracing metrics from the llm-d P/D (Prefill/Decode) coordinator (sidecar). It solves the critical observability problem where vLLM instances in P/D mode report inaccurate TTFT and TPOT metrics from their local perspective rather than the true end-to-end client experience.

## The Problem

In P/D disaggregated serving:
- **Prefiller vLLM**: Reports TTFT that doesn't include KV cache transfer time
- **Decoder vLLM**: Reports artificially low TTFT (KV cache already transferred)
- **Neither instance**: Captures the true end-to-end latency from the client's perspective

## The Solution

The P/D sidecar acts as a coordinator with visibility into both prefill and decode stages. It calculates and reports the "true" end-to-end metrics as trace span attributes:

- `llm_d.pd_proxy.true_ttft_ms`: Real client-perceived TTFT (gateway routing + scheduling + prefill + KV transfer overhead)
- `llm_d.pd_proxy.total_duration_ms`: Complete end-to-end request latency
- `llm_d.pd_proxy.prefill_duration_ms`: Prefill stage duration
- `llm_d.pd_proxy.decode_duration_ms`: Decode stage duration
- `llm_d.pd_proxy.kv_transfer_overhead_ms`: Coordination overhead between stages

## Dashboard Panels

### 1. P/D Coordinator Overview
- **True TTFT**: Time series showing the real TTFT from coordinator perspective
- **Total Request Duration**: End-to-end latency for P/D requests

### 2. P/D Component Breakdown
- **Prefill vs Decode Duration**: Comparison of both stages over time
- **KV Transfer Overhead**: Gauge showing coordination overhead (should be very low)

### 3. Coordinator vs vLLM Instance Metrics Comparison
- **TTFT Comparison**: Side-by-side comparison of coordinator true TTFT vs decoder vLLM TTFT
  - Blue line: Coordinator true TTFT (accurate)
  - Red dashed line: Decoder vLLM TTFT (artificially low due to KV already transferred)

### 4. Request Statistics
- **P/D Request Count**: Total number of P/D requests
- **P/D Connector Distribution**: Pie chart showing nixlv2, lmcache, or sglang usage
- **Avg True TTFT**: Average true TTFT across all requests
- **Avg Total Duration**: Average end-to-end duration

### 5. Trace Explorer
- **Recent P/D Traces**: Table of recent traces - click any row to view full trace details

## Key TraceQL Queries

### Get P/D Coordinator Metrics
```traceql
# True TTFT from coordinator
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | select(span.llm_d.pd_proxy.true_ttft_ms)

# Total request duration
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | select(span.llm_d.pd_proxy.total_duration_ms)

# Prefill duration
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | select(span.llm_d.pd_proxy.prefill_duration_ms)

# Decode duration
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | select(span.llm_d.pd_proxy.decode_duration_ms)

# KV transfer overhead
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | select(span.llm_d.pd_proxy.kv_transfer_overhead_ms)
```

### Compare Coordinator vs vLLM Instance Metrics
```traceql
# Coordinator true TTFT (accurate)
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | select(span.llm_d.pd_proxy.true_ttft_ms)

# Decoder vLLM TTFT (artificially low - don't use this!)
{resource.service.name="vllm-decode" && name="llm_request"} | select(span.gen_ai.latency.time_to_first_token * 1000)
```

### Filter by Connector Type
```traceql
# NIXL v2 only
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode" && span.llm_d.pd_proxy.connector="nixlv2"} | select(span.llm_d.pd_proxy.true_ttft_ms)

# LMCache only
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode" && span.llm_d.pd_proxy.connector="lmcache"} | select(span.llm_d.pd_proxy.true_ttft_ms)

# SGLang only (concurrent P/D)
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode" && span.llm_d.pd_proxy.connector="sglang"} | select(span.llm_d.pd_proxy.true_ttft_ms)
```

### Request Rate by Connector
```traceql
{resource.service.name="llm-d-pd-proxy" && name="llm_d.pd_proxy.decode"} | by(span.llm_d.pd_proxy.connector) | rate()
```

## Deployment

### Import JSON Manually
1. Open Grafana UI
2. Go to Dashboards → Import
3. Upload `pd-coordinator-metrics.json`
4. Select your Tempo datasource
5. Click Import

## Prerequisites

1. **Tempo Datasource**: Ensure Tempo is configured as a datasource in Grafana
2. **P/D Tracing Enabled**: Deploy llm-d with P/D sidecar tracing enabled
3. **Trace Collection**: OpenTelemetry collector must be forwarding traces to Tempo

## Understanding the Metrics

### True TTFT vs vLLM TTFT

**Example Scenario:**
- Gateway routing + scheduling: 2ms
- Prefill takes 50ms (vLLM reports this)
- KV transfer + coordination overhead: 3ms
- Decode vLLM reports TTFT of 10ms (artificially low because KV is already transferred)

**What you see in the dashboard:**
- **Coordinator True TTFT**: 55ms (2ms + 50ms + 3ms) ← **Use this value!**
- **Decoder vLLM TTFT**: 10ms ← **Don't use this for P/D analysis**

The coordinator's 55ms is what the client actually experiences - it's the time from gateway request arrival to when the decoder can start generating tokens.

### KV Transfer Overhead

This metric captures the coordination time between prefill completion and decode start. In a well-optimized system, this should be very low (< 5ms). If you see high overhead:
- Check network latency between prefill and decode pods
- Look for resource contention
- Verify KV transfer implementation efficiency

## Customization

### Adjust Time Window
Default: Last 1 hour, refresh every 30s

To change, edit the dashboard JSON:
```json
"time": {
  "from": "now-6h",  // Changed to 6 hours
  "to": "now"
},
"refresh": "1m"  // Changed to 1 minute
```

### Add Model Name Filtering
Add this to templating variables to filter by model:
```json
{
  "name": "model",
  "type": "query",
  "datasource": "tempo",
  "query": "{span.llm_d.pd_proxy.disaggregation_enabled=true} | by(span.gen_ai.request.model)",
  "multi": true,
  "includeAll": true
}
```

Then update queries to include:
```traceql
{span.llm_d.pd_proxy.disaggregation_enabled=true && span.gen_ai.request.model=~"$model"}
```
