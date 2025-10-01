#!/bin/bash

# EPP (Endpoint Picker) OpenTelemetry Instrumentation Validation Script
# This script helps validate that tracing is working correctly for llm-d-inference-scheduler EPP

set -e

NAMESPACE=${NAMESPACE:-default}
EPP_NAME=${EPP_NAME:-llm-d-epp}
SERVICE_NAME=${SERVICE_NAME:-llm-d-epp-service}

echo "🔍 Validating EPP OpenTelemetry Instrumentation Setup"
echo "====================================================="

# Check if OpenTelemetry operator is running
echo "1. Checking OpenTelemetry Operator..."
if kubectl get deployment -n opentelemetry-operator-system opentelemetry-operator >/dev/null 2>&1; then
    echo "✅ OpenTelemetry Operator is running"
else
    echo "❌ OpenTelemetry Operator not found. Install it first:"
    echo "   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml"
    exit 1
fi

# Check if EPP Instrumentation CR exists
echo "2. Checking EPP Instrumentation CR..."
if kubectl get instrumentation epp-instrumentation -n $NAMESPACE >/dev/null 2>&1; then
    echo "✅ epp-instrumentation CR found"
else
    echo "❌ epp-instrumentation CR not found. Apply it first:"
    echo "   kubectl apply -f epp-instrumentation.yaml"
    exit 1
fi

# Check if EPP deployment exists and has instrumentation annotation
echo "3. Checking EPP deployment annotations..."
if kubectl get deployment $EPP_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "✅ EPP deployment found: $EPP_NAME"

    ANNOTATION=$(kubectl get deployment $EPP_NAME -n $NAMESPACE -o jsonpath='{.spec.template.metadata.annotations.instrumentation\.opentelemetry\.io/inject-go}' 2>/dev/null || echo "")
    if [ "$ANNOTATION" = "epp-instrumentation" ]; then
        echo "✅ Deployment has correct Go instrumentation annotation"
    else
        echo "❌ Deployment missing Go instrumentation annotation. Add this to your deployment:"
        echo "   annotations:"
        echo "     instrumentation.opentelemetry.io/inject-go: epp-instrumentation"
        exit 1
    fi
else
    echo "❌ EPP deployment not found: $EPP_NAME"
    echo "   Available deployments:"
    kubectl get deployments -n $NAMESPACE | grep -E "(epp|inference)" || echo "   None found"
    exit 1
fi

# Check if pods are running with Go auto-instrumentation
echo "4. Checking EPP pod instrumentation injection..."
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=$EPP_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$POD_NAME" ]; then
    echo "❌ No EPP pods found with label app=$EPP_NAME"
    echo "   Available pods:"
    kubectl get pods -n $NAMESPACE | grep -E "(epp|inference)" || echo "   None found"
    exit 1
fi

echo "   Found EPP pod: $POD_NAME"

# Check for OTEL environment variables
OTEL_SERVICE_NAME=$(kubectl exec $POD_NAME -n $NAMESPACE -c epp -- printenv OTEL_SERVICE_NAME 2>/dev/null || echo "")
if [ -n "$OTEL_SERVICE_NAME" ]; then
    echo "✅ Go auto-instrumentation environment variables detected"
    echo "   Service Name: $OTEL_SERVICE_NAME"
else
    echo "❌ Go auto-instrumentation environment variables not found"
    echo "   Check operator logs: kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-operator"
fi

# Check for EPP binary and auto-instrumentation
echo "5. Checking EPP binary and auto-instrumentation..."
BINARY_PATH=$(kubectl exec $POD_NAME -n $NAMESPACE -c epp -- ls -la /app/epp 2>/dev/null || echo "")
if [ -n "$BINARY_PATH" ]; then
    echo "✅ EPP binary found at /app/epp"
    echo "   $BINARY_PATH"
else
    echo "❌ EPP binary not found at expected path /app/epp"
fi

# Check for existing OpenTelemetry in Go dependencies
OTEL_VERSION=$(kubectl exec $POD_NAME -n $NAMESPACE -c epp -- /app/epp --version 2>/dev/null | grep -i otel || echo "")
if [ -n "$OTEL_VERSION" ]; then
    echo "✅ OpenTelemetry detected in EPP binary"
else
    echo "⚠️  Could not detect OpenTelemetry version in EPP binary"
    echo "   This is expected if OTEL is statically linked"
fi

# Test EPP service accessibility
echo "6. Testing EPP service accessibility..."
if kubectl get service $SERVICE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "✅ EPP service found: $SERVICE_NAME"

    # Test gRPC health endpoint
    echo "   Testing gRPC health endpoint..."
    kubectl port-forward service/$SERVICE_NAME 9003:9003 -n $NAMESPACE >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3

    # Use grpcurl if available, otherwise just check port connectivity
    if command -v grpcurl >/dev/null 2>&1; then
        if grpcurl -plaintext localhost:9003 envoy.service.ext_proc.v3.ExternalProcessor/Process >/dev/null 2>&1; then
            echo "✅ EPP gRPC health endpoint accessible"
        else
            echo "⚠️  EPP gRPC health endpoint not responding (normal if no active requests)"
        fi
    else
        if nc -z localhost 9003 >/dev/null 2>&1; then
            echo "✅ EPP gRPC port accessible"
        else
            echo "⚠️  EPP gRPC port not accessible"
        fi
    fi

    kill $PF_PID 2>/dev/null || true
else
    echo "❌ EPP service not found: $SERVICE_NAME"
fi

# Check trace collector connectivity
echo "7. Checking trace collector connectivity..."
TRACE_ENDPOINT=$(kubectl get instrumentation epp-instrumentation -n $NAMESPACE -o jsonpath='{.spec.exporter.endpoint}' 2>/dev/null || echo "")
if [ -n "$TRACE_ENDPOINT" ]; then
    echo "✅ Trace endpoint configured: $TRACE_ENDPOINT"

    # Test connectivity from pod
    COLLECTOR_HOST=$(echo $TRACE_ENDPOINT | sed 's|http://||' | sed 's|:.*||')
    if kubectl exec $POD_NAME -n $NAMESPACE -c epp -- nslookup $COLLECTOR_HOST >/dev/null 2>&1; then
        echo "✅ Trace collector host is resolvable"
    else
        echo "⚠️  Trace collector host not resolvable: $COLLECTOR_HOST"
    fi
else
    echo "❌ No trace endpoint configured"
fi

# Check EPP configuration and custom spans
echo "8. Checking EPP custom spans and configuration..."
EPP_LOGS=$(kubectl logs $POD_NAME -n $NAMESPACE -c epp --tail=50 2>/dev/null | grep -i "trace\|span\|otel" | head -5 || echo "")
if [ -n "$EPP_LOGS" ]; then
    echo "✅ EPP tracing logs found:"
    echo "$EPP_LOGS" | sed 's/^/   /'
else
    echo "⚠️  No EPP tracing logs found. This might be normal if no requests have been processed."
fi

# Check for ZMQ port (EPP-specific)
echo "9. Checking EPP-specific ports..."
ZMQ_PORT=$(kubectl exec $POD_NAME -n $NAMESPACE -c epp -- netstat -ln 2>/dev/null | grep ":5557" || echo "")
if [ -n "$ZMQ_PORT" ]; then
    echo "✅ ZMQ port (5557) is listening"
else
    echo "⚠️  ZMQ port (5557) not found - check EPP configuration"
fi

echo ""
echo "🧪 Generating Test Spans"
echo "========================"

echo "EPP is a gRPC service that processes requests via Envoy External Processor."
echo "To generate traces, you need to send requests through the configured gateway/ingress."
echo ""
echo "If you have a gateway configured, try sending a request:"
echo "curl -X POST http://your-gateway-endpoint/v1/completions \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -H \"traceparent: 00-\$(openssl rand -hex 16)-\$(openssl rand -hex 8)-01\" \\"
echo "     -d '{\"model\": \"test-model\", \"prompt\": \"Hello\", \"max_tokens\": 10}'"

echo ""
echo "✨ Validation Complete!"
echo "======================"
echo ""
echo "📊 To view traces:"
echo "   - Jaeger UI: kubectl port-forward svc/jaeger 16686:16686 -n observability"
echo "   - Then open: http://localhost:16686"
echo "   - Search for service: llm-d-epp"
echo ""
echo "🔍 To debug further:"
echo "   - Check operator logs: kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-operator"
echo "   - Check EPP logs: kubectl logs $POD_NAME -n $NAMESPACE -c epp"
echo "   - Check collector logs: kubectl logs -n observability deployment/jaeger"
echo ""
echo "🎯 Expected spans in traces:"
echo "   - gRPC server spans (from auto-instrumentation)"
echo "     └── /envoy.service.ext_proc.v3.ExternalProcessor/Process"
echo "   - EPP custom spans (from your Go code)"
echo "     └── llm_d.epp.pd_prerequest"
echo "     └── Other custom EPP spans you've added"
echo "   - HTTP client spans (if EPP makes external calls)"
echo "   - Span attributes: llm_d.epp.*, rpc.*, http.*"