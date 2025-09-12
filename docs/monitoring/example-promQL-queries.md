# Example PromQL Queries for LLM-D Monitoring

This document provides PromQL queries for monitoring LLM-D deployments using Prometheus metrics.
The provided [load generation script](./scripts/generate-load-llmd.sh) will populate error metrics for testing.

## Metrics Overview

### Gateway API Inference Extension (GAIE) Metrics

| Desired Information | PromQL Query |
|---------------------|--------------|
| Request Rate | `sum by(model_name, target_model_name) (rate(inference_model_request_total{}[5m]))` |
| Request Latency P99 | `histogram_quantile(0.99, sum by(le) (rate(inference_model_request_duration_seconds_bucket[5m])))` |
| Request Latency P90 | `histogram_quantile(0.90, sum by(le) (rate(inference_model_request_duration_seconds_bucket[5m])))` |
| Request Latency P50 | `histogram_quantile(0.50, sum by(le) (rate(inference_model_request_duration_seconds_bucket[5m])))` |
| Overall Error Rate | `sum(rate(inference_model_request_error_total[5m])) / sum(rate(inference_model_request_total[5m]))` |
| Error Rate Per Model | `sum by(model_name) (rate(inference_model_request_error_total[5m])) / sum by(model_name) (rate(inference_model_request_total[5m]))` |
| EPP Availability | `up{job="gaie-inference-scheduling-epp"}` |
| EPP E2E Latency P99 | `histogram_quantile(0.99, sum by(le) (rate(inference_extension_scheduler_e2e_duration_seconds_bucket[5m])))` |
| Plugin Processing Latency | `histogram_quantile(0.99, sum by(le, plugin_type) (rate(inference_extension_plugin_duration_seconds_bucket[5m])))` |

### vLLM Metrics

| Desired Information | PromQL Query |
|---------------------|--------------|
| Time to First Token P99 | `histogram_quantile(0.99, sum by(le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))` |
| Time Per Output Token P99 | `histogram_quantile(0.99, sum by(le, model_name) (rate(vllm:time_per_output_token_seconds_bucket[5m])))` |
| KV Cache Transfer Duration P99 | `histogram_quantile(0.99, sum by(le) (rate(vllm:kv_cache_transfer_duration_seconds_bucket[5m])))` |
| KV Cache Usage | `avg by(pod) (vllm:kv_cache_usage_perc)` |
| Queue Utilization | `avg by(pod) (vllm:num_requests_running / vllm:max_concurrent_requests)` |
| Requests Waiting | `sum by(pod) (vllm:num_requests_waiting)` |

### Prefix Caching Metrics

| Desired Information | PromQL Query |
|---------------------|--------------|
| Prefix Cache Hit Rate | `sum(rate(vllm:prefix_cache_hits[5m])) / sum(rate(vllm:prefix_cache_queries[5m]))` |
| Per-Instance Hit Rate | `sum by(pod) (rate(vllm:prefix_cache_hits[5m])) / sum by(pod) (rate(vllm:prefix_cache_queries[5m]))` |
| Cache Memory Usage | `sum by(pod) (vllm:prefix_cache_memory_bytes / 1024 / 1024 / 1024)` |
| Cache Eviction Rate | `sum by(pod) (rate(vllm:prefix_cache_evictions_total[5m]))` |

## Key Notes

### Metric Name Updates
- **GAIE Metrics**: Some deployments may have newer metric names using `inference_objective_*` instead of `inference_model_*`

### Histogram Queries
- Always include `by(le)` grouping when using `histogram_quantile()` with bucket metrics
- Example: `histogram_quantile(0.99, sum by(le) (rate(metric_name_bucket[5m])))`

### Job Labels
- EPP availability queries use job labels like `job="gaie-inference-scheduling-epp"`
- Actual job names depend on your deployment configuration

### Error Metrics
- Error metrics (`*_error_total`) only appear after the first error occurs
- Use the provided [load generation script](./scripts/generate-load-llmd.sh) to populate error metrics for testing
