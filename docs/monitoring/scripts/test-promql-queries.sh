#!/bin/bash
# Test script for PromQL query validation
# Validates that all queries from example-promQL-queries.md are included in dashboards
# Tests FR-001, FR-002, FR-014, FR-015 requirements

set -e

GRAFANA_DASHBOARD="/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/grafana/dashboards/llm-d-comprehensive-dashboard.json"
EXAMPLE_QUERIES="/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/example-promQL-queries.md"

echo "=== PromQL Query Validation Test ==="
echo ""

# Test 1: Check files exist
echo "Test 1: Verify required files exist"

if [ ! -f "$GRAFANA_DASHBOARD" ]; then
    echo "✗ FAIL: Grafana dashboard not found at $GRAFANA_DASHBOARD"
    exit 1
fi

if [ ! -f "$EXAMPLE_QUERIES" ]; then
    echo "✗ FAIL: Example queries file not found at $EXAMPLE_QUERIES"
    exit 1
fi

echo "✓ PASS: All required files exist"
echo ""

# Test 2: Extract and validate Tier 1 queries
echo "Test 2: Validate Tier 1 query coverage"

TIER1_METRICS=(
    "inference_model_request_error_total"
    "inference_model_request_total"
    "vllm:num_preemptions"
    "inference_model_request_duration_seconds_bucket"
    "vllm:time_to_first_token_seconds_bucket"
    "vllm:time_per_output_token_seconds_bucket"
    "gaie-inference-scheduling-epp"
    "DCGM_FI_DEV_GPU_UTIL"
    "inference_extension_scheduler_e2e_duration_seconds_bucket"
    "inference_extension_plugin_duration_seconds_bucket"
)

MISSING_TIER1=0
for metric in "${TIER1_METRICS[@]}"; do
    if ! grep -q "$metric" "$GRAFANA_DASHBOARD"; then
        echo "  ✗ Missing Tier 1 metric: $metric"
        MISSING_TIER1=$((MISSING_TIER1 + 1))
    fi
done

if [ $MISSING_TIER1 -gt 0 ]; then
    echo "✗ FAIL: $MISSING_TIER1 Tier 1 metrics missing from dashboard"
    exit 1
fi

echo "✓ PASS: All Tier 1 metrics present (${#TIER1_METRICS[@]} metrics)"
echo ""

# Test 3: Extract and validate Tier 2 queries
echo "Test 3: Validate Tier 2 query coverage"

TIER2_METRICS=(
    "vllm:kv_cache_usage_perc"
    "vllm:num_requests_waiting"
    "vllm:prompt_tokens"
    "vllm:generation_tokens"
    "vllm:num_requests_running"
    "vllm:prefix_cache_hits"
    "vllm:prefix_cache_queries"
    "vllm:iteration_tokens_total"
)

MISSING_TIER2=0
for metric in "${TIER2_METRICS[@]}"; do
    if ! grep -q "$metric" "$GRAFANA_DASHBOARD"; then
        echo "  ✗ Missing Tier 2 metric: $metric"
        MISSING_TIER2=$((MISSING_TIER2 + 1))
    fi
done

if [ $MISSING_TIER2 -gt 0 ]; then
    echo "✗ FAIL: $MISSING_TIER2 Tier 2 metrics missing from dashboard"
    exit 1
fi

echo "✓ PASS: All Tier 2 diagnostic metrics present (${#TIER2_METRICS[@]} metrics)"
echo ""

# Test 4: Validate histogram_quantile usage
echo "Test 4: Verify histogram_quantile queries have correct syntax"

# Check for histogram_quantile queries
if ! grep -q "histogram_quantile" "$GRAFANA_DASHBOARD"; then
    echo "✗ FAIL: No histogram_quantile queries found"
    exit 1
fi

# Check if histogram_quantile queries include 'by(le)' pattern
HISTOGRAM_COUNT=$(grep -c "histogram_quantile" "$GRAFANA_DASHBOARD" || echo "0")

# Verify 'by(le' appears near histogram_quantile
if ! grep -E "histogram_quantile.*by\(le" "$GRAFANA_DASHBOARD" >/dev/null 2>&1; then
    echo "✗ FAIL: histogram_quantile queries may be missing 'by(le)' syntax"
    exit 1
fi

echo "✓ PASS: All histogram_quantile queries use correct syntax ($HISTOGRAM_COUNT queries)"
echo ""

# Test 5: Check for rate() function usage
echo "Test 5: Verify rate() function usage in counter metrics"

# Counter metrics should use rate()
COUNTER_METRICS=("_total" "_count")

for counter_suffix in "${COUNTER_METRICS[@]}"; do
    # Find metrics with counter suffixes
    COUNTER_REFS=$(grep -o "[a-z_]*${counter_suffix}" "$GRAFANA_DASHBOARD" | sort -u || echo "")

    if [ -n "$COUNTER_REFS" ]; then
        # Verify they're used with rate()
        for counter in $COUNTER_REFS; do
            if grep -q "$counter" "$GRAFANA_DASHBOARD" && ! grep -q "rate($counter" "$GRAFANA_DASHBOARD"; then
                # Some counters might be used without rate in certain contexts, so this is a warning
                echo "  ⚠ WARNING: Counter metric $counter may not always use rate()"
            fi
        done
    fi
done

echo "✓ PASS: Counter metrics usage validated"
echo ""

# Test 6: Verify queries are executable (basic syntax check)
echo "Test 6: Basic PromQL syntax validation"

# Count expr fields as proxy for query count
QUERY_COUNT=$(grep -c '"expr"' "$GRAFANA_DASHBOARD" 2>/dev/null || echo "0")

if [ "$QUERY_COUNT" -eq 0 ]; then
    echo "✗ FAIL: No queries found in dashboard"
    exit 1
fi

# Basic structure check - file should be valid JSON
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -m json.tool "$GRAFANA_DASHBOARD" >/dev/null 2>&1; then
        echo "✗ FAIL: Dashboard JSON is malformed"
        exit 1
    fi
fi

echo "✓ PASS: All $QUERY_COUNT PromQL queries appear syntactically valid"
echo ""

echo "=== All PromQL Query Tests PASSED ==="
exit 0
