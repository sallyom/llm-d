# Observability Implementation Plan for Issue #347

## Overview

This document outlines the implementation plan for observability metrics to support the PD (Prefill/Decode) Disaggregation and WideEP (Wide Expert Parallelism) guides in llm-d.

**Related Issue:** https://github.com/llm-d/llm-d/issues/347

**Goal:** Understanding what's happening in the system through comprehensive observability metrics across different parallel processing approaches.

**⚠️ IMPORTANT:** llm-d uses **vLLM v1 engine** (`vllm/vllm/v1`). All metrics implementations must be compatible with the v1 architecture, NOT v0.

---

## Current State Summary

### Existing Infrastructure ✅

- **Prometheus metrics framework:** `vllm/v1/metrics/loggers.py` (v1 engine compatible)
- **KV connector stats framework:** `vllm/distributed/kv_transfer/kv_connector/v1/metrics.py` (v1 connector)
- **NIXL transfer telemetry:** Tracks bytes transferred in `NixlKVConnectorStats`
- **Prefix cache stats:** Both local and connector-based tracking exists
- **EPLB configuration:** Algorithms in `vllm/distributed/eplb/` (shared, v1 compatible)
- **V1 Engine Core:** `vllm/v1/engine/core.py` - Main execution engine
- **V1 Stats:** `vllm/v1/metrics/stats.py` - Stats dataclasses (`SchedulerStats`, `IterationStats`)

---

## PD (Prefill/Decode) Disaggregation Metrics

### 1. Tokens Transferred via NIXL

**Status:** ✓ Infrastructure exists, needs extension

**Current State:**
- File: `vllm/distributed/kv_transfer/kv_connector/v1/nixl_connector.py:1877-1970`
- `NixlKVConnectorStats` currently tracks `bytes_transferred`

**Implementation Needed:**
1. Add `num_tokens_transferred` field to `NixlKVConnectorStats.data` dictionary
2. Calculate tokens from blocks: `num_blocks × block_size`
3. Update `record_transfer()` method (line ~1897) to accept and record token count
4. Expose in `reduce()` method (line ~1956) for CLI logging
5. Add Prometheus counter in `PrometheusStatLogger`

**Implementation Details:**
```python
# In NixlKVConnectorStats.reset() - line 1888
self.data: dict[str, list[float]] = {
    # ... existing fields ...
    "num_tokens_transferred": [],
}

# In record_transfer() - line 1897
def record_transfer(self, res: nixlXferTelemetry, num_tokens: int = 0):
    # ... existing code ...
    self.data["num_tokens_transferred"].append(float(num_tokens))

# In reduce() - line 1956
return {
    # ... existing metrics ...
    "Total tokens transferred": int(tokens.sum()),
    "Avg tokens per transfer": round(tokens.mean(), 1),
}
```

**Call Site Updates:**
- Line ~1540: `self.xfer_stats.record_transfer(res, num_tokens=len(block_ids) * self.block_size)`
- Pass `local_block_ids` information from `_read_blocks()` to `record_transfer()`

**Prometheus Metrics to Add:**
```python
counter_nixl_tokens_transferred = Counter(
    name="vllm:nixl_tokens_transferred_total",
    documentation="Total number of tokens transferred via NIXL",
    labelnames=["model_name", "engine"]
)
```

---

### 2. vLLM Prompt Token Metrics Accuracy

**Status:** ⚠️ Needs validation

**Current State:**
- File: `vllm/v1/metrics/loggers.py:535-542`
- Metric: `vllm:prompt_tokens` counter
- Updated in: `vllm/v1/metrics/stats.py:252` via `iteration_stats.num_prompt_tokens`
- V1 engine tracks this in `IterationStats` class

**Investigation Needed:**
1. Verify if `num_prompt_tokens` accounts for KV-transferred tokens on decode workers
2. Check if decode workers receiving pre-computed KV caches count those tokens
3. Determine if we need separate counters:
   - `vllm:prompt_tokens_computed` (actually processed locally)
   - `vllm:prompt_tokens_received` (transferred via NIXL)

**Questions to Answer:**
- When a decode worker receives KV cache for 1000 tokens via NIXL, does it increment `num_prompt_tokens` by 1000?
- Should transferred tokens count toward throughput metrics?
- How does this affect reported TTFT (Time To First Token)?

**Code Locations to Review:**
- `vllm/v1/metrics/stats.py:252` - Where `num_prompt_tokens` is incremented
- `vllm/v1/engine/core.py` - V1 engine core that processes prefill/decode
- `vllm/v1/worker/kv_connector_model_runner_mixin.py` - KV connector integration with v1 workers
- NIXL connector receive path - Where transferred tokens arrive

**Recommended Approach:**
1. Add debug logging to track token counting in both paths
2. Run PD guide example and verify metrics match expected behavior
3. If needed, add distinct metrics for local vs transferred tokens

---

### 3. Prefix Cache Hit/Miss on Transferred Tokens

**Status:** ✅ Partially implemented

**Current State:**
- File: `vllm/v1/metrics/loggers.py:473-495`
- Existing Prometheus metrics:
  - `vllm:external_prefix_cache_queries` - Tokens queried from external cache
  - `vllm:external_prefix_cache_hits` - Tokens found in external cache

**Already Implemented:**
```python
# Line 473-495 in loggers.py
counter_connector_prefix_cache_queries = Counter(...)
counter_connector_prefix_cache_hits = Counter(...)

# Line 924-929 - Recording logic
if scheduler_stats.connector_prefix_cache_stats is not None:
    self.counter_connector_prefix_cache_queries[engine_idx].inc(
        scheduler_stats.connector_prefix_cache_stats.queries
    )
    self.counter_connector_prefix_cache_hits[engine_idx].inc(
        scheduler_stats.connector_prefix_cache_stats.hits
    )
```

**May Need:**
1. Verify these metrics are properly exposed in Prometheus endpoint
2. Add hit rate gauge for easier monitoring:
```python
gauge_external_prefix_cache_hit_rate = Gauge(
    name="vllm:external_prefix_cache_hit_rate",
    documentation="External prefix cache hit rate (0-1)",
    labelnames=["model_name", "engine"]
)
```

**Validation Steps:**
1. Run PD guide with prefix caching enabled
2. Check Prometheus `/metrics` endpoint for these counters
3. Verify non-zero values when cache hits occur
4. Add to monitoring dashboards

---

### 4. Interleaved Batch Execution Percentage

**Status:** ❌ Not implemented

**Goal:** Track what percentage of time decode/prefill workers spend executing interleaved batches (both prefill and decode work in same batch).

**V1 Context:**
- V1 engine processes batches in `vllm/v1/engine/core.py`
- Batch composition determined in v1 scheduler
- Stats tracked via `IterationStats` class

**Implementation Needed:**

**Step 1: Track Batch Type in IterationStats**

File: `vllm/v1/metrics/stats.py`

```python
# Around line 216-234
class IterationStats:
    """Stats associated with a single set of EngineCoreOutputs."""

    def __init__(self):
        self.iteration_timestamp = time.time()
        self.num_generation_tokens = 0
        self.num_prompt_tokens = 0
        # ... existing fields ...

        # Add batch type tracking
        self.batch_type: str = "unknown"  # "prefill", "decode", "interleaved", "empty"
```

**Step 2: Determine Batch Type in V1 Engine**

File: `vllm/v1/engine/core.py` or where batches are formed

Add logic to classify batch type when creating `IterationStats`:
```python
def _classify_batch_type(num_prompt_tokens: int, num_generation_tokens: int) -> str:
    """Classify the type of batch based on work performed."""
    if num_prompt_tokens > 0 and num_generation_tokens > 0:
        return "interleaved"
    elif num_prompt_tokens > 0:
        return "prefill"
    elif num_generation_tokens > 0:
        return "decode"
    else:
        return "empty"

# In batch processing logic, set batch type:
iteration_stats.batch_type = _classify_batch_type(
    iteration_stats.num_prompt_tokens,
    iteration_stats.num_generation_tokens
)
```

**Step 3: Add Prometheus Counters**

File: `vllm/v1/metrics/loggers.py`

```python
# In PrometheusStatLogger.__init__() around line 550
counter_batch_prefill = self._counter_cls(
    name="vllm:batch_executions_prefill_total",
    documentation="Number of pure prefill batch executions",
    labelnames=labelnames,
)
self.counter_batch_prefill = make_per_engine(counter_batch_prefill, engine_indexes, model_name)

counter_batch_decode = self._counter_cls(
    name="vllm:batch_executions_decode_total",
    documentation="Number of pure decode batch executions",
    labelnames=labelnames,
)
self.counter_batch_decode = make_per_engine(counter_batch_decode, engine_indexes, model_name)

counter_batch_interleaved = self._counter_cls(
    name="vllm:batch_executions_interleaved_total",
    documentation="Number of interleaved batch executions (both prefill and decode)",
    labelnames=labelnames,
)
self.counter_batch_interleaved = make_per_engine(counter_batch_interleaved, engine_indexes, model_name)

# Optional: Add gauge for percentage
gauge_interleaved_percentage = self._gauge_cls(
    name="vllm:batch_interleaved_percentage",
    documentation="Percentage of batches that were interleaved (0-100)",
    multiprocess_mode="mostrecent",
    labelnames=labelnames,
)
self.gauge_interleaved_percentage = make_per_engine(gauge_interleaved_percentage, engine_indexes, model_name)
```

**Step 4: Record Metrics**

In `PrometheusStatLogger.record()` around line 940:
```python
if iteration_stats is None:
    return

# Track batch type
if hasattr(iteration_stats, 'batch_type'):
    if iteration_stats.batch_type == "prefill":
        self.counter_batch_prefill[engine_idx].inc()
    elif iteration_stats.batch_type == "decode":
        self.counter_batch_decode[engine_idx].inc()
    elif iteration_stats.batch_type == "interleaved":
        self.counter_batch_interleaved[engine_idx].inc()
```

**Calculation for Percentage:**
Use PromQL in Grafana:
```promql
100 * rate(vllm:batch_executions_interleaved_total[5m]) /
  (rate(vllm:batch_executions_prefill_total[5m]) +
   rate(vllm:batch_executions_decode_total[5m]) +
   rate(vllm:batch_executions_interleaved_total[5m]))
```

**Files to Modify:**
1. `vllm/v1/metrics/stats.py` - Add batch_type to IterationStats
2. `vllm/v1/engine/core.py` - Set batch_type when creating/updating IterationStats
3. `vllm/v1/metrics/loggers.py` - Add counters and recording logic

---

## WideEP (Expert Parallelism) Metrics

**V1 Compatibility Note:** EPLB is in `vllm/distributed/eplb/` which is shared infrastructure used by both v0 and v1. Metrics need to be integrated into the v1 metrics framework via `SchedulerStats`.

### 5. EPLB Balancedness Metric

**Status:** ❌ Not implemented

**Current State:**
- File: `vllm/distributed/eplb/rebalance_algo.py`
- Config flag exists: `eplb_config.log_balancedness` (in `vllm/config/parallel.py:294`)
- EPLB state tracked in: `vllm/distributed/eplb/eplb_state.py`

**V1 Integration:**
- EPLB metrics need to flow through v1's `SchedulerStats` or similar mechanism
- May need to add EPLB stats dataclass similar to `PrefixCacheStats`

**Implementation Needed:**

**Step 1: Calculate Balancedness**

Add to `rebalance_algo.py`:
```python
def calculate_balancedness(expert_loads: torch.Tensor) -> float:
    """
    Calculate load balancedness metric.

    Returns coefficient of variation (lower is better, 0 = perfect balance).
    CV = std / mean
    """
    if expert_loads.numel() == 0:
        return 0.0

    mean_load = expert_loads.float().mean()
    if mean_load == 0:
        return 0.0

    std_load = expert_loads.float().std()
    return (std_load / mean_load).item()
```

**Step 2: Track Expert Loads**

In the EPLB worker or scheduler:
```python
# Track tokens processed by each expert
self.expert_token_counts = torch.zeros(num_experts, dtype=torch.long)

# After routing decisions
for expert_id, num_tokens in expert_assignments:
    self.expert_token_counts[expert_id] += num_tokens
```

**Step 3: Add Prometheus Metrics**

In `vllm/v1/metrics/loggers.py`:
```python
gauge_eplb_balancedness = self._gauge_cls(
    name="vllm:eplb_balancedness",
    documentation="EPLB load balancedness (coefficient of variation, lower is better)",
    multiprocess_mode="mostrecent",
    labelnames=labelnames,
)

histogram_expert_load = self._histogram_cls(
    name="vllm:expert_load_tokens",
    documentation="Token load distribution across experts",
    buckets=[100, 500, 1000, 5000, 10000, 50000, 100000],
    labelnames=labelnames + ["expert_id"],
)
```

**Integration Point:**
- Call after rebalancing in `rebalance_experts_hierarchical()` (line 95+)
- Log if `eplb_config.log_balancedness == True`

---

### 6. Rebalance Count and Time

**Status:** ❌ Not implemented

**Current State:**
- File: `vllm/distributed/eplb/rebalance_execute.py`
- Rebalancing happens at `step_interval` from `EPLBConfig`

**Implementation Needed:**

**Step 1: Add Timing to Rebalance**

Wrap rebalancing operations with timing:
```python
import time

def rebalance_experts(...):
    start_time = time.time()

    # ... existing rebalance logic ...

    duration = time.time() - start_time
    return result, duration
```

**Step 2: Add Prometheus Metrics**

In `vllm/v1/metrics/loggers.py`:
```python
counter_expert_rebalances = self._counter_cls(
    name="vllm:expert_rebalances_total",
    documentation="Total number of expert load rebalances performed",
    labelnames=labelnames,
)

histogram_rebalance_duration = self._histogram_cls(
    name="vllm:expert_rebalance_duration_seconds",
    documentation="Time spent rebalancing experts",
    buckets=[0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0, 30.0],
    labelnames=labelnames,
)

gauge_last_rebalance_timestamp = self._gauge_cls(
    name="vllm:expert_last_rebalance_timestamp",
    documentation="Unix timestamp of last expert rebalance",
    multiprocess_mode="mostrecent",
    labelnames=labelnames,
)
```

**Step 3: Record Metrics**

After rebalancing:
```python
self.counter_expert_rebalances[engine_idx].inc()
self.histogram_rebalance_duration[engine_idx].observe(duration)
self.gauge_last_rebalance_timestamp[engine_idx].set(time.time())
```

---

### 7. Hot Expert Distribution

**Status:** ❌ Not implemented

**Goal:** Track which experts are "hot" (processing the most tokens) and their distribution.

**Implementation Needed:**

**Step 1: Track Expert Usage**

Maintain sliding window of expert usage:
```python
class ExpertLoadTracker:
    def __init__(self, num_experts: int, window_size: int = 1000):
        self.expert_loads = deque(maxlen=window_size)
        self.num_experts = num_experts

    def record_batch(self, expert_assignments: dict[int, int]):
        """Record expert token assignments for a batch."""
        self.expert_loads.append(expert_assignments)

    def get_hot_experts(self, top_k: int = 10) -> list[tuple[int, int]]:
        """Return top-k experts by total tokens processed."""
        total_per_expert = defaultdict(int)
        for batch in self.expert_loads:
            for expert_id, tokens in batch.items():
                total_per_expert[expert_id] += tokens

        sorted_experts = sorted(
            total_per_expert.items(),
            key=lambda x: x[1],
            reverse=True
        )
        return sorted_experts[:top_k]
```

**Step 2: Add Prometheus Metrics**

```python
# Per-expert token counter
counter_expert_tokens = self._counter_cls(
    name="vllm:expert_tokens_processed_total",
    documentation="Total tokens processed by each expert",
    labelnames=labelnames + ["expert_id"],
)

# Hot expert gauge (top-K)
gauge_hot_expert_load = self._gauge_cls(
    name="vllm:hot_expert_load",
    documentation="Token load for hot experts",
    multiprocess_mode="sum",
    labelnames=labelnames + ["expert_id", "rank"],  # rank = 1st, 2nd, 3rd hottest
)
```

**Step 3: Periodic Updates**

Update hot expert metrics every N batches:
```python
if batch_count % update_interval == 0:
    hot_experts = tracker.get_hot_experts(top_k=10)
    for rank, (expert_id, token_count) in enumerate(hot_experts, 1):
        self.gauge_hot_expert_load.labels(
            model_name, str(engine_idx), str(expert_id), str(rank)
        ).set(token_count)
```

---

### 8. Static Expert Config Metrics

**Status:** ❌ Not implemented

**Current State:**
- Config exists in: `vllm/config/parallel.py:293-301` (`EPLBConfig`)

**Implementation Needed:**

**Add Info Gauge**

Similar to `cache_config_info` (line 862-884 in `loggers.py`):

```python
def log_expert_config_info(self):
    """Log static EPLB configuration as Prometheus info metric."""
    if not self.vllm_config.parallel_config.enable_eplb:
        return

    eplb_config = self.vllm_config.parallel_config.eplb_config

    expert_info_gauge = self._gauge_cls(
        name="vllm:expert_config_info",
        documentation="Static EPLB configuration information",
        multiprocess_mode="mostrecent",
        labelnames=[
            "model_name",
            "engine",
            "total_experts",
            "redundant_experts",
            "window_size",
            "step_interval",
        ],
    )

    for engine_index in self.engine_indexes:
        expert_info_gauge.labels(
            self.vllm_config.model_config.served_model_name,
            str(engine_index),
            str(self.vllm_config.parallel_config.total_num_experts),
            str(eplb_config.num_redundant_experts),
            str(eplb_config.window_size),
            str(eplb_config.step_interval),
        ).set(1)
```

**Call in `log_engine_initialized()`:**
```python
def log_engine_initialized(self):
    self.log_metrics_info("cache_config", self.vllm_config.cache_config)
    self.log_expert_config_info()  # Add this
```

---

## Implementation Priority

### Phase 1: High Priority PD Metrics (Critical for PD Guide)
1. ✅ **Tokens transferred via NIXL** - Core PD metric
2. ✅ **Interleaved batch percentage** - Understanding PD behavior
3. ⚠️ **Validate prompt token metrics** - Ensure accuracy

### Phase 2: Verification (Existing Features)
4. ✅ **Prefix cache transfer hit/miss** - Verify Prometheus export works

### Phase 3: High Priority WideEP Metrics (Critical for WideEP Guide)
5. ✅ **EPLB balancedness** - Core EPLB metric
6. ✅ **Rebalance count/time** - EPLB performance
7. ✅ **Static expert config** - At-a-glance understanding

### Phase 4: Nice to Have
8. ✅ **Hot expert distribution** - Debugging and optimization

---

## Testing Strategy

### For PD Metrics:
1. Deploy PD guide example (`guides/pd-disaggregation`)
2. Generate inference traffic with varying prompt lengths
3. Verify metrics appear in Prometheus `/metrics` endpoint
4. Check that token counts match expected values (blocks × block_size)
5. Validate interleaved batch percentage makes sense for workload
6. Test with both pure prefill and pure decode scenarios

### For WideEP Metrics:
1. Deploy WideEP guide example (`guides/wide-ep-lws`)
2. Send requests to MoE model (DeepSeek-R1)
3. Trigger expert rebalancing (wait for step_interval)
4. Verify EPLB metrics are recorded
5. Check hot expert distribution matches routing behavior
6. Validate balancedness metric decreases after rebalancing

### V1-Specific Testing:
1. Test with DP (Data Parallel) mode enabled
2. Verify multiprocess prometheus registry works correctly
3. Check metrics across multiple engine indexes
4. Test metric aggregation in DP mode

### Integration Testing:
1. Add metrics to Grafana dashboards
2. Run load tests and observe metric behavior
3. Verify metrics align with guide documentation
4. Update monitoring documentation
5. Ensure no performance regression from metrics collection

---

## V1-Specific Considerations

### Key V1 Files:
- **Engine Core:** `vllm/v1/engine/core.py` - Main execution loop
- **Stats Framework:** `vllm/v1/metrics/stats.py` - Stats dataclasses
- **Metrics Logger:** `vllm/v1/metrics/loggers.py` - Prometheus integration
- **Workers:** `vllm/v1/worker/` - Model runners and execution
- **KV Connector Integration:** `vllm/v1/worker/kv_connector_model_runner_mixin.py`

### Integration Points:
1. **Stats Collection:** All metrics flow through `SchedulerStats` and `IterationStats`
2. **Prometheus Export:** Unified in `PrometheusStatLogger` class
3. **Multiprocessing:** V1 uses prometheus multiprocessing for DP mode
4. **EPLB Integration:** Shared `vllm/distributed/eplb/` needs to populate v1 stats

### V1 Data Flow:
```
Engine Core (v1/engine/core.py)
  ↓
Scheduler Stats (v1/metrics/stats.py)
  ↓
Stat Logger Manager (v1/metrics/loggers.py)
  ↓
Prometheus Registry
```

---

## Files to Modify

### PD Metrics:
- `vllm/distributed/kv_transfer/kv_connector/v1/nixl_connector.py` - NIXL token tracking
- `vllm/v1/metrics/stats.py` - Batch type tracking, EPLB stats dataclass
- `vllm/v1/metrics/loggers.py` - Prometheus metrics for all PD features
- `vllm/v1/engine/core.py` - Determine and set batch types
- `vllm/v1/worker/kv_connector_model_runner_mixin.py` - Token counting validation

### WideEP Metrics:
- `vllm/distributed/eplb/rebalance_algo.py` - Balancedness calculation
- `vllm/distributed/eplb/rebalance_execute.py` - Timing and counting
- `vllm/distributed/eplb/eplb_state.py` - Expert load tracking
- `vllm/v1/metrics/stats.py` - EPLBStats dataclass
- `vllm/v1/metrics/loggers.py` - Prometheus metrics for EPLB
- `vllm/config/parallel.py` - Config info export (read-only)

---

## Documentation Updates

After implementation, update:
1. `llm-d/guides/pd-disaggregation/README.md` - Document PD metrics
2. `llm-d/guides/wide-ep-lws/README.md` - Document WideEP metrics
3. `llm-d/docs/monitoring/README.md` - Add new metrics to monitoring guide
4. Create Grafana dashboard JSON for PD and WideEP metrics
5. Update observability troubleshooting guides

---

## Success Criteria

### PD Metrics:
- [ ] NIXL token transfer metrics visible in Prometheus
- [ ] Token counts accurate (matches blocks × block_size)
- [ ] Interleaved batch percentage calculated correctly
- [ ] Metrics work in both single-engine and DP modes
- [ ] Prompt token metrics validated for accuracy
- [ ] Prefix cache hit rate shows expected behavior

### WideEP Metrics:
- [ ] EPLB balancedness metric tracks load distribution
- [ ] Balancedness improves (decreases) after rebalancing
- [ ] Rebalance events counted and timed
- [ ] Hot experts identified correctly
- [ ] Static config visible at startup
- [ ] Expert metrics work with MoE models

### Overall:
- [ ] All metrics documented in guides
- [ ] Grafana dashboards created
- [ ] Integration tests passing
- [ ] No performance regression from metrics collection
- [ ] Metrics compatible with v1 engine architecture
- [ ] Multiprocess prometheus working in DP mode

---

## Notes

- All metrics follow vLLM naming conventions (`vllm:` prefix)
- Use appropriate Prometheus metric types (Counter, Gauge, Histogram)
- Ensure metrics are multiprocess-safe for DP mode (use correct `multiprocess_mode`)
- Keep performance overhead minimal
- Add metrics conditionally based on configuration (e.g., only EPLB metrics when enabled)
- **V1 Compatibility:** All implementations must work with v1 engine architecture
- **Shared Infrastructure:** EPLB code is shared between v0 and v1, metrics must integrate properly
- **Stats Flow:** All new stats must flow through v1's `SchedulerStats` or `IterationStats`

---

**Last Updated:** 2025-10-23
**Authors:** Claude Code + llm-d team
**Status:** Planning → Implementation
**vLLM Version:** v1 (vllm/vllm/v1)
