#!/bin/bash
# Test script for enhanced Grafana dashboard validation
# This test MUST FAIL initially as the dashboard doesn't exist yet
# Tests FR-001, FR-002, FR-003, FR-004 requirements

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_FILE="/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/grafana/dashboards/llm-d-comprehensive-dashboard.json"

echo "=== Enhanced Grafana Dashboard Validation Test ==="
echo ""

# Test 1: Dashboard file exists
echo "Test 1: Check if dashboard file exists"
if [ ! -f "$DASHBOARD_FILE" ]; then
    echo "✗ FAIL: Dashboard file not found at $DASHBOARD_FILE"
    exit 1
fi
echo "✓ PASS: Dashboard file exists"
echo ""

# Test 2: Valid JSON syntax
echo "Test 2: Validate JSON syntax"
if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$DASHBOARD_FILE" 2>/dev/null; then
        echo "✗ FAIL: Invalid JSON syntax"
        exit 1
    fi
elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -m json.tool "$DASHBOARD_FILE" >/dev/null 2>&1; then
        echo "✗ FAIL: Invalid JSON syntax"
        exit 1
    fi
else
    echo "⚠ WARNING: Cannot validate JSON - neither jq nor python3 available"
fi
echo "✓ PASS: Valid JSON syntax"
echo ""

# Test 3: Check for required Tier 1 queries
echo "Test 3: Verify Tier 1 PromQL queries are present"

TIER1_QUERIES=(
    "inference_model_request_error_total"
    "vllm:num_preemptions"
    "histogram_quantile.*inference_model_request_duration_seconds_bucket"
    "vllm:time_to_first_token_seconds_bucket"
    "vllm:time_per_output_token_seconds_bucket"
    "gaie-inference-scheduling-epp"
    "DCGM_FI_DEV_GPU_UTIL"
    "inference_model_request_total"
    "inference_extension_scheduler_e2e_duration_seconds_bucket"
    "inference_extension_plugin_duration_seconds_bucket"
)

MISSING_QUERIES=0
for query in "${TIER1_QUERIES[@]}"; do
    if ! grep -qE "$query" "$DASHBOARD_FILE"; then
        echo "  ✗ Missing Tier 1 query: $query"
        MISSING_QUERIES=$((MISSING_QUERIES + 1))
    fi
done

if [ $MISSING_QUERIES -gt 0 ]; then
    echo "✗ FAIL: $MISSING_QUERIES Tier 1 queries missing"
    exit 1
fi
echo "✓ PASS: All Tier 1 queries present"
echo ""

# Test 4: Check for Tier 2 diagnostic queries
echo "Test 4: Verify Tier 2 diagnostic queries are present"

TIER2_QUERIES=(
    "vllm:kv_cache_usage_perc"
    "vllm:num_requests_waiting"
    "vllm:prompt_tokens"
    "vllm:generation_tokens"
    "vllm:prefix_cache_hits"
    "vllm:prefix_cache_queries"
)

MISSING_TIER2=0
for query in "${TIER2_QUERIES[@]}"; do
    if ! grep -q "$query" "$DASHBOARD_FILE"; then
        echo "  ✗ Missing Tier 2 query: $query"
        MISSING_TIER2=$((MISSING_TIER2 + 1))
    fi
done

if [ $MISSING_TIER2 -gt 0 ]; then
    echo "✗ FAIL: $MISSING_TIER2 Tier 2 queries missing"
    exit 1
fi
echo "✓ PASS: All Tier 2 diagnostic queries present"
echo ""

# Test 5: Verify dashboard can be imported
echo "Test 5: Check dashboard structure for import compatibility"

# Check for required Grafana fields
if ! grep -q '"title"' "$DASHBOARD_FILE" || ! grep -q '"panels"' "$DASHBOARD_FILE"; then
    echo "✗ FAIL: Missing required fields (title or panels)"
    exit 1
fi

# Check panel count (rough estimate using grep)
PANEL_COUNT=$(grep -c '"type".*:.*"timeseries\|stat\|gauge\|heatmap"' "$DASHBOARD_FILE" 2>/dev/null || echo "0")
if [ "$PANEL_COUNT" -lt 20 ]; then
    echo "✗ FAIL: Expected at least 20 panels (Tier 1 + Tier 2), found approximately $PANEL_COUNT"
    exit 1
fi

echo "✓ PASS: Dashboard structure valid with approximately $PANEL_COUNT panels"
echo ""

# Test 6: Check for panel organization (rows)
echo "Test 6: Verify logical panel organization"

if ! grep -q "Tier 1" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: Missing Tier 1 organization structure"
    exit 1
fi

if ! grep -q "Tier 2" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: Missing Tier 2 organization structure"
    exit 1
fi

echo "✓ PASS: Dashboard has logical organization"
echo ""

echo "=== All Enhanced Grafana Dashboard Tests PASSED ==="
exit 0
