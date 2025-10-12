#!/bin/bash
# Dashboard Validation Script
# Validates JSON and YAML syntax and structure for Grafana and Perses dashboards
# Usage: ./validate-dashboard.sh <path-to-dashboard-file>

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <path-to-dashboard-file>"
    exit 1
fi

DASHBOARD_FILE="$1"

if [ ! -f "$DASHBOARD_FILE" ]; then
    echo "ERROR: File not found: $DASHBOARD_FILE"
    exit 1
fi

# Detect file type by extension
FILE_EXT="${DASHBOARD_FILE##*.}"

validate_json() {
    echo "Validating JSON syntax..."

    # Try jq first
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$1" 2>/dev/null; then
            echo "ERROR: Invalid JSON syntax in $1"
            return 1
        fi
    # Fallback to python3
    elif command -v python3 >/dev/null 2>&1; then
        if ! python3 -m json.tool "$1" >/dev/null 2>&1; then
            echo "ERROR: Invalid JSON syntax in $1"
            return 1
        fi
    else
        echo "WARNING: Cannot validate JSON - neither jq nor python3 available"
        return 0
    fi

    echo "✓ JSON syntax valid"

    # Validate Grafana dashboard structure
    echo "Validating Grafana dashboard structure..."

    # Check for required top-level fields
    if ! grep -q '"title"' "$1"; then
        echo "WARNING: Missing 'title' field"
    fi

    if ! grep -q '"panels"' "$1"; then
        echo "WARNING: Missing 'panels' field"
    fi

    # Check panels array
    PANEL_COUNT=$(grep -c '"type".*:.*"timeseries\|stat\|gauge\|heatmap"' "$1" 2>/dev/null || echo "0")
    echo "✓ Found approximately $PANEL_COUNT panels"

    # Check for template variables
    TEMPLATE_COUNT=$(grep -c '"name".*:.*"DS_PROMETHEUS\|namespace\|model_name"' "$1" 2>/dev/null || echo "0")
    echo "✓ Found approximately $TEMPLATE_COUNT template variables"

    return 0
}

validate_yaml() {
    echo "Validating YAML syntax..."

    # Check if yq is available
    if command -v yq >/dev/null 2>&1; then
        if ! yq eval '.' "$1" >/dev/null 2>&1; then
            echo "ERROR: Invalid YAML syntax in $1"
            return 1
        fi
        echo "✓ YAML syntax valid"

        # Validate Perses dashboard structure
        echo "Validating Perses dashboard structure..."

        # Check for required fields
        if yq eval '.kind' "$1" 2>/dev/null | grep -q "Dashboard"; then
            echo "✓ Valid Perses Dashboard kind"
        else
            echo "WARNING: Missing or invalid 'kind' field (expected: Dashboard)"
        fi

        if yq eval '.spec.display.name' "$1" >/dev/null 2>&1; then
            DASHBOARD_NAME=$(yq eval '.spec.display.name' "$1")
            echo "✓ Dashboard name: $DASHBOARD_NAME"
        else
            echo "WARNING: Missing dashboard name"
        fi

        # Check panels
        PANEL_COUNT=$(yq eval '.spec.panels | length' "$1" 2>/dev/null || echo "0")
        echo "✓ Found $PANEL_COUNT panels"

        # Check variables
        VAR_COUNT=$(yq eval '.spec.variables | length' "$1" 2>/dev/null || echo "0")
        echo "✓ Found $VAR_COUNT variables"

    else
        # Fallback to basic Python YAML validation
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$1'))" 2>/dev/null; then
                echo "ERROR: Invalid YAML syntax in $1"
                return 1
            fi
            echo "✓ YAML syntax valid"
            echo "NOTE: Install 'yq' for detailed structure validation"
        else
            echo "WARNING: Cannot validate YAML - neither yq nor python3 available"
            return 1
        fi
    fi

    return 0
}

echo "=== Dashboard Validation ==="
echo "File: $DASHBOARD_FILE"
echo "Type: $FILE_EXT"
echo ""

case "$FILE_EXT" in
    json)
        validate_json "$DASHBOARD_FILE"
        EXIT_CODE=$?
        ;;
    yaml|yml)
        validate_yaml "$DASHBOARD_FILE"
        EXIT_CODE=$?
        ;;
    *)
        echo "ERROR: Unsupported file type: $FILE_EXT"
        echo "Supported types: json, yaml, yml"
        exit 1
        ;;
esac

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "=== Validation PASSED ==="
else
    echo "=== Validation FAILED ==="
fi

exit $EXIT_CODE
