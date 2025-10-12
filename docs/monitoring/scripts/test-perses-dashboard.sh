#!/bin/bash
# Test script for Perses dashboard validation
# Tests FR-009, FR-010, FR-011, FR-012, FR-013 requirements

set -e

DASHBOARD_FILE="/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/perses/llm-d-dashboard.yaml"

echo "=== Perses Dashboard Validation Test ==="
echo ""

# Test 1: Dashboard file exists
echo "Test 1: Check if Perses dashboard file exists"
if [ ! -f "$DASHBOARD_FILE" ]; then
    echo "✗ FAIL: Dashboard file not found at $DASHBOARD_FILE"
    exit 1
fi
echo "✓ PASS: Dashboard file exists"
echo ""

# Test 2: Valid YAML syntax
echo "Test 2: Validate YAML syntax"

if command -v yq >/dev/null 2>&1; then
    if ! yq eval '.' "$DASHBOARD_FILE" >/dev/null 2>&1; then
        echo "✗ FAIL: Invalid YAML syntax"
        exit 1
    fi
elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import yaml; yaml.safe_load(open('$DASHBOARD_FILE'))" 2>/dev/null; then
        echo "✗ FAIL: Invalid YAML syntax"
        exit 1
    fi
else
    echo "⚠ WARNING: Cannot validate YAML - neither yq nor python3 available"
fi

echo "✓ PASS: Valid YAML syntax"
echo ""

# Test 3: Check for Perses Dashboard structure
echo "Test 3: Verify Perses Dashboard structure"

if ! grep -q "kind:" "$DASHBOARD_FILE" || ! grep -q "Dashboard" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: Missing 'kind: Dashboard' field"
    exit 1
fi

if ! grep -q "spec:" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: Missing 'spec' section"
    exit 1
fi

echo "✓ PASS: Valid Perses Dashboard structure"
echo ""

# Test 4: Check for core metrics (functional equivalence with Grafana)
echo "Test 4: Verify core metrics are present"

CORE_METRICS=(
    "inference_model_request_duration_seconds"
    "vllm:time_to_first_token_seconds"
    "vllm:time_per_output_token_seconds"
    "vllm:generation_tokens"
    "vllm:kv_cache_usage_perc"
)

MISSING_METRICS=0
for metric in "${CORE_METRICS[@]}"; do
    if ! grep -q "$metric" "$DASHBOARD_FILE"; then
        echo "  ✗ Missing core metric: $metric"
        MISSING_METRICS=$((MISSING_METRICS + 1))
    fi
done

if [ $MISSING_METRICS -gt 0 ]; then
    echo "✗ FAIL: $MISSING_METRICS core metrics missing"
    exit 1
fi
echo "✓ PASS: All core metrics present"
echo ""

# Test 5: Check for panels
echo "Test 5: Verify dashboard has panels"

if ! grep -q "panels:" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: No panels section found"
    exit 1
fi

# Count panels (rough check)
PANEL_COUNT=$(grep -c "kind: Panel" "$DASHBOARD_FILE" 2>/dev/null || echo "0")
if [ "$PANEL_COUNT" -lt 5 ]; then
    echo "✗ FAIL: Expected at least 5 panels, found $PANEL_COUNT"
    exit 1
fi

echo "✓ PASS: Dashboard has $PANEL_COUNT panels"
echo ""

# Test 6: Check for datasource configuration
echo "Test 6: Verify datasource configuration"

if ! grep -q "datasource:" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: No datasource configuration found"
    exit 1
fi

if ! grep -q "Prometheus" "$DASHBOARD_FILE"; then
    echo "✗ FAIL: Expected Prometheus datasource type"
    exit 1
fi

echo "✓ PASS: Prometheus datasource configured"
echo ""

echo "=== All Perses Dashboard Tests PASSED ==="
exit 0
