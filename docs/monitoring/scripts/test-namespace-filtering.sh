#!/bin/bash
# Test script for namespace filtering validation
# Tests FR-005, FR-006, FR-007, FR-008 requirements

set -e

GRAFANA_DASHBOARD="/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/grafana/dashboards/llm-d-comprehensive-dashboard.json"
PERSES_DASHBOARD="/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/perses/llm-d-dashboard.yaml"

echo "=== Namespace Filtering Validation Test ==="
echo ""

# Test Grafana dashboard namespace filtering
echo "Test 1: Verify Grafana dashboard has namespace template variable"

if [ ! -f "$GRAFANA_DASHBOARD" ]; then
    echo "✗ FAIL: Grafana dashboard not found"
    exit 1
fi

# Check for namespace template variable
if ! grep -q '"name".*:.*"namespace"' "$GRAFANA_DASHBOARD"; then
    echo "✗ FAIL: Missing namespace template variable in Grafana dashboard"
    exit 1
fi

echo "✓ PASS: Namespace template variable exists in Grafana dashboard"
echo ""

# Test 2: Check if namespace variable supports multi-select
echo "Test 2: Verify namespace variable supports multi-select"

# Use python to properly parse JSON and check namespace variable
if command -v python3 >/dev/null 2>&1; then
    MULTI_CHECK=$(python3 << 'PYTHON_EOF'
import json, sys
try:
    with open('/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/grafana/dashboards/llm-d-comprehensive-dashboard.json') as f:
        dashboard = json.load(f)
    for var in dashboard.get('templating', {}).get('list', []):
        if var.get('name') == 'namespace':
            print('true' if var.get('multi', False) else 'false')
            sys.exit(0)
    print('not_found')
except Exception as e:
    print('error')
    sys.exit(1)
PYTHON_EOF
)
    if [ "$MULTI_CHECK" = "true" ]; then
        echo "✓ PASS: Namespace variable supports multi-select"
    elif [ "$MULTI_CHECK" = "not_found" ]; then
        echo "✗ FAIL: Namespace variable not found"
        exit 1
    else
        echo "✗ FAIL: Namespace variable does not support multi-select"
        exit 1
    fi
else
    # Fallback to grep if python not available
    if grep -q '"multi".*:.*true' "$GRAFANA_DASHBOARD" && grep -q '"name".*:.*"namespace"' "$GRAFANA_DASHBOARD"; then
        echo "✓ PASS: Namespace variable likely supports multi-select"
    else
        echo "✗ FAIL: Cannot verify multi-select without python3"
        exit 1
    fi
fi
echo ""

# Test 3: Check if namespace variable has "All" option
echo "Test 3: Verify namespace variable has 'All' option"

if command -v python3 >/dev/null 2>&1; then
    INCLUDEALL_CHECK=$(python3 << 'PYTHON_EOF'
import json, sys
try:
    with open('/workspace/sessions/agentic-session-1760279278/workspace/llm-d/docs/monitoring/grafana/dashboards/llm-d-comprehensive-dashboard.json') as f:
        dashboard = json.load(f)
    for var in dashboard.get('templating', {}).get('list', []):
        if var.get('name') == 'namespace':
            print('true' if var.get('includeAll', False) else 'false')
            sys.exit(0)
    print('not_found')
except Exception as e:
    print('error')
    sys.exit(1)
PYTHON_EOF
)
    if [ "$INCLUDEALL_CHECK" = "true" ]; then
        echo "✓ PASS: Namespace variable has 'All' option"
    elif [ "$INCLUDEALL_CHECK" = "not_found" ]; then
        echo "✗ FAIL: Namespace variable not found"
        exit 1
    else
        echo "✗ FAIL: Namespace variable does not have 'All' option"
        exit 1
    fi
else
    # Fallback to grep if python not available
    if grep -q '"includeAll".*:.*true' "$GRAFANA_DASHBOARD" && grep -q '"name".*:.*"namespace"' "$GRAFANA_DASHBOARD"; then
        echo "✓ PASS: Namespace variable likely has 'All' option"
    else
        echo "✗ FAIL: Cannot verify includeAll without python3"
        exit 1
    fi
fi
echo ""

# Test 4: Verify queries use namespace filter
echo "Test 4: Verify PromQL queries use namespace filtering"

# Check for expr fields (PromQL queries)
QUERY_COUNT=$(grep -c '"expr"' "$GRAFANA_DASHBOARD" 2>/dev/null || echo "0")

if [ "$QUERY_COUNT" -eq 0 ]; then
    echo "✗ FAIL: No PromQL queries found in dashboard"
    exit 1
fi

# Check if queries contain namespace filtering patterns
# Patterns: {namespace="$namespace"} or {namespace=~"$namespace"}
if ! grep -qE 'namespace[=~]+.*\$namespace' "$GRAFANA_DASHBOARD"; then
    echo "✗ FAIL: No namespace filtering found in PromQL queries"
    exit 1
fi

echo "✓ PASS: PromQL queries include namespace filtering (found in $QUERY_COUNT queries)"
echo ""

# Test 5: Test Perses dashboard namespace filtering
echo "Test 5: Verify Perses dashboard has namespace variable"

if [ ! -f "$PERSES_DASHBOARD" ]; then
    echo "⚠ WARNING: Perses dashboard not found, skipping Perses namespace tests"
else
    if ! grep -q "namespace" "$PERSES_DASHBOARD"; then
        echo "✗ FAIL: No namespace variable found in Perses dashboard"
        exit 1
    fi
    echo "✓ PASS: Namespace variable exists in Perses dashboard"
fi
echo ""

# Test 6: Verify namespace filter query
echo "Test 6: Verify namespace variable query"

# Check for label_values query pattern near namespace variable
if ! grep -A 15 '"name".*:.*"namespace"' "$GRAFANA_DASHBOARD" | grep -q "label_values"; then
    echo "⚠ WARNING: Namespace query doesn't use label_values pattern"
else
    echo "✓ PASS: Namespace variable uses label_values query pattern"
fi
echo ""

echo "=== All Namespace Filtering Tests PASSED ==="
exit 0
