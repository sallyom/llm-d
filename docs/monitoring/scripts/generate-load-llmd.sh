#!/bin/bash

# Load generation script with P/D disaggregation tracing focus
# Generates requests optimized for testing distributed tracing spans
#
# Usage: ./generate-load-llmd.sh [duration_minutes]
#
# This script is designed to generate comprehensive trace data for P/D disaggregation,
# focusing on the spans added to llm-d-inference-scheduler sidecar:
#
# KEY FEATURES FOR P/D TRACING:
# 1. Variable prompt lengths (short/medium/long) to test:
#    - Selective P/D threshold behavior (short prompts may bypass P/D)
#    - KV cache transfer with different input sizes
# 2. Streaming and non-streaming requests to capture both modes
# 3. Variable max_tokens to test different decode durations
# 4. Mix of request types to generate complete distributed traces
#
# SPANS THAT WILL BE GENERATED:
# - llm_d.pd_proxy.request (all requests through sidecar)
# - llm_d.pd_proxy.prefill (when P/D disaggregation is active)
# - llm_d.pd_proxy.decode (when P/D disaggregation is active)
# - gateway.request, gateway.director.handle_request, gateway.scheduler.schedule
# - llm_d.epp.prerequest.pd_disaggregation (P/D header setup)
# - vllm.llm_request (on both prefill and decode instances)
#
# TRUE TTFT/TPOT METRICS:
# The sidecar spans include end-to-end P/D metrics that solve the observability
# gap where vLLM instances report TTFT/TPOT from their local perspective:
# - llm_d.pd_proxy.true_ttft_ms: True TTFT from client perspective
# - llm_d.pd_proxy.total_duration_ms: Complete request latency
# - llm_d.pd_proxy.prefill_duration_ms: Prefill stage duration
# - llm_d.pd_proxy.decode_duration_ms: Decode stage duration
# - llm_d.pd_proxy.kv_transfer_overhead_ms: Coordination overhead

set -e

ENDPOINT="http://localhost:8000/v1"
DURATION_MINUTES=${1:-5}
MODEL_NAME="Qwen/Qwen3-0.6B"

echo "Load Generator with P/D Disaggregation Tracing Focus"
echo "===================================================="
echo "Endpoint: $ENDPOINT"
echo "Model: $MODEL_NAME"
echo "Duration: $DURATION_MINUTES minutes"
echo ""
echo "This script generates requests to trigger P/D disaggregation spans:"
echo "  - llm_d.pd_proxy.request (all requests)"
echo "  - llm_d.pd_proxy.prefill (P/D active)"
echo "  - llm_d.pd_proxy.decode (P/D active)"
echo "  - Varying prompt lengths to test selective P/D threshold"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# First, check if the model is available
echo "Checking model availability..."
echo "------------------------------"
curl -s "$ENDPOINT/models" | jq . || echo "Failed to get models"
echo ""

# Function to send a normal request
send_request() {
    local request_num=$1
    local prompt=$2
    local max_tokens=${3:-50}
    local stream=${4:-false}
    local temperature=${5:-0.7}

    local stream_label=""
    if [ "$stream" = "true" ]; then
        stream_label=" [STREAMING]"
    fi

    echo "Request #$request_num (NORMAL)${stream_label}"
    echo "Prompt length: ${#prompt} chars | Max tokens: $max_tokens"
    echo "Sending..."

    local start_time=$(date +%s)

    local response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL_NAME\",
            \"messages\": [
                {\"role\": \"user\", \"content\": \"$prompt\"}
            ],
            \"max_tokens\": $max_tokens,
            \"temperature\": $temperature,
            \"stream\": $stream
        }")

    local end_time=$(date +%s)
    local duration_ms=$(( (end_time - start_time) * 1000 ))

    if [ -n "$response" ]; then
        echo "Response (${duration_ms}ms):"
        # For streaming responses, show first line only
        if [ "$stream" = "true" ]; then
            echo "$response" | head -n 1
            echo "... (streaming response truncated)"
        else
            echo "$response" | jq -c '{usage, model}' 2>/dev/null || echo "$response"
        fi
    else
        echo "ERROR: Empty response after ${duration_ms}ms"
    fi

    echo "----------------------------------------"
    echo ""
}

# Function to send malformed requests to trigger errors
send_malformed_request() {
    local request_num=$1
    local error_type=$2

    echo "Request #$request_num (MALFORMED - $error_type)"
    echo "Sending..."

    local start_time=$(date +%s)
    local response=""

    case $error_type in
        "invalid_model")
            # Request with non-existent model
            response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"nonexistent-model-123\",
                    \"messages\": [
                        {\"role\": \"user\", \"content\": \"Hello\"}
                    ],
                    \"max_tokens\": 50
                }")
            ;;
        "malformed_json")
            # Invalid JSON syntax
            response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL_NAME\",
                    \"messages\": [
                        {\"role\": \"user\", \"content\": \"Hello\"
                    ],
                    \"max_tokens\": 50
                }" 2>&1)
            ;;
        "missing_required_field")
            # Missing required 'messages' field
            response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL_NAME\",
                    \"max_tokens\": 50
                }")
            ;;
        "invalid_temperature")
            # Invalid temperature value (out of range)
            response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL_NAME\",
                    \"messages\": [
                        {\"role\": \"user\", \"content\": \"Hello\"}
                    ],
                    \"max_tokens\": 50,
                    \"temperature\": 5.0
                }")
            ;;
        "invalid_max_tokens")
            # Negative max_tokens
            response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL_NAME\",
                    \"messages\": [
                        {\"role\": \"user\", \"content\": \"Hello\"}
                    ],
                    \"max_tokens\": -10
                }")
            ;;
        "wrong_endpoint")
            # Non-existent endpoint
            response=$(curl -s -X POST "$ENDPOINT/nonexistent/endpoint" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL_NAME\",
                    \"messages\": [
                        {\"role\": \"user\", \"content\": \"Hello\"}
                    ]
                }")
            ;;
        "no_content_type")
            # Missing Content-Type header
            response=$(curl -s -X POST "$ENDPOINT/chat/completions" \
                -d "{
                    \"model\": \"$MODEL_NAME\",
                    \"messages\": [
                        {\"role\": \"user\", \"content\": \"Hello\"}
                    ],
                    \"max_tokens\": 50
                }")
            ;;
    esac

    local end_time=$(date +%s)
    local duration_ms=$(( (end_time - start_time) * 1000 ))

    echo "Error Response (${duration_ms}ms):"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    echo "----------------------------------------"
    echo ""
}

# Prompts designed to trigger different P/D behaviors
# Short prompts - may bypass P/D disaggregation if selective P/D threshold is set
short_prompts=(
    "Hello!"
    "What is 2+2?"
    "Hi there"
)

# Medium prompts - likely to trigger P/D disaggregation
medium_prompts=(
    "Tell me a detailed story about a journey through the mountains and what you might encounter along the way."
    "Explain how distributed systems work and what challenges they face in production environments."
    "What are the main differences between supervised and unsupervised machine learning approaches?"
)

# Long prompts - guaranteed to trigger P/D disaggregation and test KV cache transfer
long_prompts=(
    "I need a comprehensive explanation of how large language models work, including the architecture, training process, inference optimization techniques like KV cache, prefix caching, and disaggregated serving. Please cover the mathematical foundations, attention mechanisms, and practical deployment considerations for production systems at scale."
    "Write a detailed technical analysis of Kubernetes scheduling mechanisms, including the default scheduler, custom schedulers, admission controllers, and how they interact with different workload types. Discuss performance implications, best practices for high-scale deployments, and optimization strategies for GPU workloads."
    "Explain the concept of distributed tracing in microservices architectures. Cover OpenTelemetry, trace context propagation, sampling strategies, span hierarchies, and how to use tracing data to optimize performance in complex distributed systems with multiple components and services."
)

# Combine all prompts for variety
all_prompts=("${short_prompts[@]}" "${medium_prompts[@]}" "${long_prompts[@]}")

# Error types to cycle through
# NOTE: "invalid_model" is commented out because it causes hangs with
# precise-prefix-cache-scorer plugin (tries to download non-existent tokenizer)
error_types=(
    # "invalid_model"
    "malformed_json"
    "missing_required_field"
    "invalid_temperature"
    "invalid_max_tokens"
    "wrong_endpoint"
    "no_content_type"
)

# Trap SIGINT to handle graceful shutdown
trap 'echo -e "\n\nShutting down gracefully..."; show_final_metrics; exit 0' INT

show_final_metrics() {
    echo ""
    echo "Final metrics check..."
    echo "======================="
    echo "Looking for error metrics:"
    curl -s http://localhost:8000/metrics | grep -E "inference.*error" || echo "No error metrics found yet"
    echo ""
    echo "Request metrics:"
    curl -s http://localhost:8000/metrics | grep -E "inference.*request_total" || echo "No request metrics found"
    echo ""
    echo "All inference metrics:"
    curl -s http://localhost:8000/metrics | grep -E "inference_" | grep -v "#" | head -10
}

# Calculate end time
start_time=$(date +%s)
end_time=$((start_time + DURATION_MINUTES * 60))
request_count=0
error_count=0

echo "Starting load generation with error injection..."
echo "Start time: $(date)"
echo ""

# Send requests continuously until duration expires
while [ $(date +%s) -lt $end_time ]; do
    request_count=$((request_count + 1))

    # Request pattern to maximize P/D tracing coverage:
    # - 60% normal requests with varying lengths (trigger P/D spans)
    # - 20% streaming requests (test streaming with P/D)
    # - 10% varied token lengths (test different decode durations)
    # - 10% error requests (maintain error tracking)

    request_type=$((request_count % 10))

    if [ $request_type -eq 9 ]; then
        # Every 10th request is malformed to generate errors
        error_count=$((error_count + 1))
        error_index=$(( (error_count - 1) % ${#error_types[@]} ))
        error_type="${error_types[$error_index]}"
        send_malformed_request "$request_count" "$error_type"

    elif [ $request_type -eq 7 ] || [ $request_type -eq 8 ]; then
        # 20% streaming requests - these will show streaming behavior in P/D spans
        prompt_index=$(( request_count % ${#all_prompts[@]} ))
        prompt="${all_prompts[$prompt_index]}"
        send_request "$request_count" "$prompt" 100 true 0.7

    elif [ $request_type -eq 6 ]; then
        # 10% high token count - tests longer decode duration in traces
        prompt_index=$(( request_count % ${#long_prompts[@]} ))
        prompt="${long_prompts[$prompt_index]}"
        send_request "$request_count" "$prompt" 200 false 0.7

    elif [ $request_type -eq 1 ] || [ $request_type -eq 2 ]; then
        # Focus on long prompts to ensure P/D disaggregation is triggered
        prompt_index=$(( request_count % ${#long_prompts[@]} ))
        prompt="${long_prompts[$prompt_index]}"
        send_request "$request_count" "$prompt" 50 false 0.7

    elif [ $request_type -eq 3 ]; then
        # Test short prompts - may bypass P/D if selective threshold is set
        prompt_index=$(( request_count % ${#short_prompts[@]} ))
        prompt="${short_prompts[$prompt_index]}"
        send_request "$request_count" "$prompt" 30 false 0.7

    else
        # Medium prompts - balanced workload
        prompt_index=$(( request_count % ${#medium_prompts[@]} ))
        prompt="${medium_prompts[$prompt_index]}"
        send_request "$request_count" "$prompt" 50 false 0.7
    fi

    # Small delay between requests
    sleep 2

    # Show progress every 10 requests
    if [ $((request_count % 10)) -eq 0 ]; then
        current_time=$(date +%s)
        elapsed_seconds=$((current_time - start_time))
        remaining_seconds=$((end_time - current_time))
        elapsed_minutes=$((elapsed_seconds / 60))
        remaining_minutes=$((remaining_seconds / 60))
        echo ">>> Requests: $request_count (Errors: $error_count) | Elapsed: ${elapsed_minutes}m | Remaining: ${remaining_minutes}m"
        echo ""
    fi
done

echo ""
echo "Load generation complete!"
echo "========================="
echo "Total requests sent: $request_count"
echo "Error requests sent: $error_count"
echo ""
echo "Request Distribution (for P/D Tracing):"
echo "  - Long prompts: ~20% (guaranteed P/D disaggregation)"
echo "  - Medium prompts: ~40% (likely P/D disaggregation)"
echo "  - Short prompts: ~10% (may bypass P/D if selective threshold set)"
echo "  - Streaming: ~20% (P/D with streaming)"
echo "  - High token decode: ~10% (extended decode duration)"
echo "  - Errors: ~10%"
echo ""
echo "Expected Trace Spans Generated:"
echo "  - llm_d.pd_proxy.request: $request_count (all requests)"
echo "  - llm_d.pd_proxy.prefill: ~$((request_count * 90 / 100)) (when P/D active)"
echo "  - llm_d.pd_proxy.decode: ~$((request_count * 90 / 100)) (when P/D active)"
echo "  - gateway.request: $request_count"
echo "  - vllm.llm_request (prefill): ~$((request_count * 90 / 100))"
echo "  - vllm.llm_request (decode): ~$((request_count * 90 / 100))"
echo ""
echo "End time: $(date)"

show_final_metrics
