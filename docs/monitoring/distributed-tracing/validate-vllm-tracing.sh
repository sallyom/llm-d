#!/bin/bash

# vLLM OpenTelemetry Instrumentation Validation Script
# This script helps validate that tracing is working correctly

set -e

NAMESPACE=${NAMESPACE:-default}
DEPLOYMENT_NAME=${DEPLOYMENT_NAME:-vllm-server}
SERVICE_NAME=${SERVICE_NAME:-vllm-service}

echo "🔍 Validating vLLM OpenTelemetry Instrumentation Setup"
echo "======================================================"

# Check if OpenTelemetry operator is running
echo "1. Checking OpenTelemetry Operator..."
if kubectl get deployment -n opentelemetry-operator-system opentelemetry-operator >/dev/null 2>&1; then
    echo "✅ OpenTelemetry Operator is running"
else
    echo "❌ OpenTelemetry Operator not found. Install it first:"
    echo "   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml"
    exit 1
fi

# Check if Instrumentation CR exists
echo "2. Checking Instrumentation CR..."
if kubectl get instrumentation vllm-instrumentation -n $NAMESPACE >/dev/null 2>&1; then
    echo "✅ vllm-instrumentation CR found"
else
    echo "❌ vllm-instrumentation CR not found. Apply it first:"
    echo "   kubectl apply -f vllm-instrumentation.yaml"
    exit 1
fi

# Check if deployment has instrumentation annotation
echo "3. Checking deployment annotations..."
ANNOTATION=$(kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE -o jsonpath='{.spec.template.metadata.annotations.instrumentation\.opentelemetry\.io/inject-python}' 2>/dev/null || echo "")
if [ "$ANNOTATION" = "vllm-instrumentation" ]; then
    echo "✅ Deployment has correct instrumentation annotation"
else
    echo "❌ Deployment missing instrumentation annotation. Add this to your deployment:"
    echo "   annotations:"
    echo "     instrumentation.opentelemetry.io/inject-python: vllm-instrumentation"
    exit 1
fi

# Check if pods are running with auto-instrumentation
echo "4. Checking pod instrumentation injection..."
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$POD_NAME" ]; then
    echo "❌ No vLLM pods found"
    exit 1
fi

# Check for OTEL environment variables
OTEL_SERVICE_NAME=$(kubectl exec $POD_NAME -n $NAMESPACE -- printenv OTEL_SERVICE_NAME 2>/dev/null || echo "")
if [ -n "$OTEL_SERVICE_NAME" ]; then
    echo "✅ Auto-instrumentation environment variables detected"
    echo "   Service Name: $OTEL_SERVICE_NAME"
else
    echo "❌ Auto-instrumentation environment variables not found"
    echo "   Check operator logs: kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-operator"
fi

# Check for vLLM tracing initialization
echo "5. Checking vLLM custom tracing initialization..."
TRACING_LOGS=$(kubectl logs $POD_NAME -n $NAMESPACE 2>/dev/null | grep -i "trac\|otel" | head -3 || echo "")
if [ -n "$TRACING_LOGS" ]; then
    echo "✅ vLLM tracing logs found:"
    echo "$TRACING_LOGS" | sed 's/^/   /'
else
    echo "⚠️  No vLLM tracing logs found. Check:"
    echo "   - vLLM started with --otlp-traces-endpoint argument"
    echo "   - OpenTelemetry packages are available in container"
fi

# Test HTTP endpoint accessibility
echo "6. Testing vLLM service accessibility..."
if kubectl get service $SERVICE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "✅ vLLM service found"

    # Port forward and test (in background)
    echo "   Testing health endpoint..."
    kubectl port-forward service/$SERVICE_NAME 8000:8000 -n $NAMESPACE >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3

    if curl -s http://localhost:8000/health >/dev/null 2>&1; then
        echo "✅ vLLM health endpoint accessible"
    else
        echo "⚠️  vLLM health endpoint not accessible"
    fi

    kill $PF_PID 2>/dev/null || true
else
    echo "❌ vLLM service not found"
fi

# Check trace collector connectivity
echo "7. Checking trace collector connectivity..."
TRACE_ENDPOINT=$(kubectl get instrumentation vllm-instrumentation -n $NAMESPACE -o jsonpath='{.spec.exporter.endpoint}' 2>/dev/null || echo "")
if [ -n "$TRACE_ENDPOINT" ]; then
    echo "✅ Trace endpoint configured: $TRACE_ENDPOINT"

    # Test connectivity from pod
    COLLECTOR_HOST=$(echo $TRACE_ENDPOINT | sed 's|http://||' | sed 's|:.*||')
    if kubectl exec $POD_NAME -n $NAMESPACE -- nslookup $COLLECTOR_HOST >/dev/null 2>&1; then
        echo "✅ Trace collector host is resolvable"
    else
        echo "⚠️  Trace collector host not resolvable: $COLLECTOR_HOST"
    fi
else
    echo "❌ No trace endpoint configured"
fi

# Generate test traces
echo ""
echo "🧪 Generating Test Traces"
echo "========================="

echo "Sending test requests to generate traces..."
kubectl port-forward service/$SERVICE_NAME 8000:8000 -n $NAMESPACE >/dev/null 2>&1 &
PF_PID=$!
sleep 3

# Send a few test requests
for i in {1..3}; do
    echo "Sending test request $i..."
    curl -s -X POST http://localhost:8000/v1/completions \
         -H "Content-Type: application/json" \
         -H "traceparent: 00-$(openssl rand -hex 16)-$(openssl rand -hex 8)-01" \
         -d '{
           "model": "facebook/opt-125m",
           "prompt": "Hello, this is a test request",
           "max_tokens": 10,
           "temperature": 0.1
         }' >/dev/null 2>&1 || echo "   Request $i failed"
    sleep 1
done

kill $PF_PID 2>/dev/null || true

echo ""
echo "✨ Validation Complete!"
echo "======================"
echo ""
echo "📊 To view traces:"
echo "   - Jaeger UI: kubectl port-forward svc/jaeger 16686:16686 -n observability"
echo "   - Then open: http://localhost:16686"
echo ""
echo "🔍 To debug further:"
echo "   - Check operator logs: kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-operator"
echo "   - Check vLLM logs: kubectl logs $POD_NAME -n $NAMESPACE"
echo "   - Check collector logs: kubectl logs -n observability deployment/jaeger"
echo ""
echo "🎯 Expected spans in traces:"
echo "   - FastAPI HTTP request spans (from auto-instrumentation)"
echo "   - vLLM custom spans with LLM metrics (from --otlp-traces-endpoint)"
echo "   - Span attributes: gen_ai.*, http.*, otel.*"