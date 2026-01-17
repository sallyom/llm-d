#!/bin/bash

# Concurrent Load Generator for NIXL KV Cache Transfer Metrics
#
# This script generates high-concurrency load optimized to showcase NIXL KV cache
# transfer metrics with precise prefix caching across multiple decode pods.
#
# Usage: ./generate-load-nixl-transfers.sh [concurrent_workers] [duration_minutes] [endpoint]
#
# KEY FEATURES:
# 1. CONCURRENT WORKERS: Multiple parallel request streams to distribute across pods
# 2. PREFIX REPETITION: Reuses common prefixes to trigger cache hits on different pods
# 3. VARIED PROMPT LENGTHS: Different ISL to show varying KV cache transfer sizes
# 4. HIGH REQUEST RATE: Minimal delays to maximize NIXL transfer opportunities
#
# EXPECTED OUTCOMES IN GRAFANA:
# - vllm:nixl_xfer_time_seconds: KV cache transfer duration (5-20ms with TCP)
# - vllm:nixl_bytes_transferred: Amount of KV cache data moved between pods
# - vllm:nixl_post_time_seconds: Post-transfer processing time
# - vllm:nixl_num_descriptors: NIXL descriptors used for transfers
# - Prefix cache hit rates showing cache reuse across the 4 decode pods

set -e

# Configuration
ENDPOINT="${ENDPOINT:-http://localhost:8000/v1}"
CONCURRENT_WORKERS=${1:-8}
DURATION_MINUTES=${2:-5}
MODEL_NAME="${MODEL_NAME:-meta-llama/Llama-3.1-8B-Instruct}"

# Shared counter for statistics (macOS-compatible)
STATS_DIR="/tmp/nixl_load_gen_stats_$$"
mkdir -p "$STATS_DIR"
echo "0" > "$STATS_DIR/total"
echo "0" > "$STATS_DIR/success"
echo "0" > "$STATS_DIR/fail"

increment_stat() {
    local stat_type=$1  # total, success, or failure

    # Simple file-based counter (no flock needed - atomic on most filesystems)
    case $stat_type in
        success)
            echo "1" >> "$STATS_DIR/success"
            echo "1" >> "$STATS_DIR/total"
            ;;
        failure)
            echo "1" >> "$STATS_DIR/fail"
            echo "1" >> "$STATS_DIR/total"
            ;;
        total)
            echo "1" >> "$STATS_DIR/total"
            ;;
    esac
}

get_stats() {
    local total=$(cat "$STATS_DIR/total" 2>/dev/null | wc -l | tr -d ' ')
    local success=$(cat "$STATS_DIR/success" 2>/dev/null | wc -l | tr -d ' ')
    local fail=$(cat "$STATS_DIR/fail" 2>/dev/null | wc -l | tr -d ' ')
    echo "$total $success $fail"
}

echo "============================================================"
echo "   NIXL KV Cache Transfer Load Generator"
echo "============================================================"
echo "Endpoint:     $ENDPOINT"
echo "Model:        $MODEL_NAME"
echo "Workers:      $CONCURRENT_WORKERS"
echo "Duration:     $DURATION_MINUTES minutes"
echo ""
echo "This script creates sustained concurrent load to showcase:"
echo "  ✓ NIXL KV cache transfers between decode pods"
echo "  ✓ vllm:nixl_xfer_time_seconds (transfer duration)"
echo "  ✓ vllm:nixl_bytes_transferred (KV cache data size)"
echo "  ✓ Prefix cache hit rates across 4 decode replicas"
echo "  ✓ EPP routing based on prefix cache scoring"
echo ""
echo "============================================================"
echo ""

# Verify endpoint is accessible
echo "Checking endpoint availability..."
if ! curl -s -f "$ENDPOINT/models" > /dev/null 2>&1; then
    echo "ERROR: Cannot reach endpoint $ENDPOINT"
    echo "Make sure the llm-d gateway/service is running and accessible"
    exit 1
fi
echo "✓ Endpoint accessible"
echo ""

# Prompt templates with SHARED PREFIXES to maximize cache reuse
# The key to triggering NIXL transfers is:
# 1. Request A hits Pod 1 with prefix "Explain Kubernetes..."
# 2. Request B with same prefix hits Pod 2 (routed by EPP)
# 3. Pod 2 fetches KV cache from Pod 1 via NIXL
#
# We use common prefixes with variations to trigger cache hits

# Kubernetes-focused prompts (shared prefix: "Explain Kubernetes")
KUBERNETES_PROMPTS=(
    "Explain Kubernetes architecture and how pods, services, and deployments work together in a cluster."
    "Explain Kubernetes networking model including CNI plugins, service discovery, and how pods communicate across nodes."
    "Explain Kubernetes scheduling mechanisms, node affinity, taints and tolerations, and how the scheduler makes placement decisions."
    "Explain Kubernetes storage with persistent volumes, storage classes, and how stateful applications manage data in containers."
    "Explain Kubernetes security best practices including RBAC, pod security policies, network policies, and secrets management."
)

# Machine learning prompts (shared prefix: "Describe how machine learning")
ML_PROMPTS=(
    "Describe how machine learning models are trained, including gradient descent, backpropagation, and optimization techniques used in neural networks."
    "Describe how machine learning inference works at scale, covering batch processing, online serving, and model optimization for production deployments."
    "Describe how machine learning pipelines handle data preprocessing, feature engineering, model training, evaluation, and deployment automation."
    "Describe how machine learning models handle overfitting through regularization, dropout, early stopping, and cross-validation techniques."
    "Describe how machine learning frameworks like PyTorch and TensorFlow implement automatic differentiation and GPU acceleration for training."
)

# Distributed systems prompts (shared prefix: "What are the key concepts")
DISTRIBUTED_SYSTEMS_PROMPTS=(
    "What are the key concepts in distributed systems design, including consistency models, partition tolerance, and the CAP theorem implications?"
    "What are the key concepts in distributed consensus algorithms like Paxos and Raft, and how do they ensure agreement across replicas?"
    "What are the key concepts in distributed tracing for microservices, covering span hierarchies, trace context propagation, and sampling strategies?"
    "What are the key concepts in distributed caching systems, including cache invalidation, consistency guarantees, and replication strategies?"
    "What are the key concepts in distributed message queues and event streaming platforms like Kafka for building scalable data pipelines?"
)

# LLM serving prompts (shared prefix: "Provide details about")
LLM_SERVING_PROMPTS=(
    "Provide details about large language model serving architectures, including batching strategies, KV cache management, and memory optimization techniques."
    "Provide details about transformer model inference optimization through techniques like quantization, pruning, and efficient attention implementations."
    "Provide details about distributed LLM inference with tensor parallelism, pipeline parallelism, and how they scale models across multiple GPUs."
    "Provide details about prefix caching in LLM serving, including hash algorithms, cache hit detection, and latency reduction for repeated prompts."
    "Provide details about KV cache transfer mechanisms in disaggregated LLM serving, covering NIXL connectors, RDMA, and network transfer optimization."
)

# Shorter prompts for variety (different transfer sizes)
SHORT_PROMPTS=(
    "What is Kubernetes?"
    "Explain machine learning."
    "What is distributed tracing?"
    "How does caching work?"
)

# Function to send a request and capture timing
send_request() {
    local worker_id=$1
    local request_num=$2
    local prompt=$3
    local max_tokens=$4

    local start_time=$(date +%s%N)

    # Generate unique request ID for tracing
    local request_id="nixl-w${worker_id}-req${request_num}-$(date +%s%N | tail -c 8)"

    local response=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Request-ID: $request_id" \
        -d "{
            \"model\": \"$MODEL_NAME\",
            \"messages\": [
                {\"role\": \"user\", \"content\": $(echo "$prompt" | jq -Rs .)}
            ],
            \"max_tokens\": $max_tokens,
            \"temperature\": 0.7,
            \"stream\": false
        }" 2>&1)

    local end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))

    local http_code=$(echo "$response" | tail -n1)
    local prompt_length=${#prompt}

    if [ "$http_code" = "200" ]; then
        increment_stat success
        echo "[$(date '+%H:%M:%S')] W${worker_id}-${request_num} | ${prompt_length}ch/${max_tokens}t | ${duration_ms}ms | ✓"
    else
        increment_stat failure
        echo "[$(date '+%H:%M:%S')] W${worker_id}-${request_num} | ${prompt_length}ch/${max_tokens}t | ${duration_ms}ms | ✗ HTTP${http_code}"
    fi
}

# Worker function with prefix-focused load pattern
worker_load_generator() {
    local worker_id=$1
    local pattern=$2
    local end_time=$3

    local request_count=0

    echo "[Worker $worker_id] Started with pattern: $pattern"

    while [ $(date +%s) -lt $end_time ]; do
        request_count=$((request_count + 1))

        # Select prompt and parameters based on pattern
        # Each pattern focuses on different prompt sets to maximize prefix reuse
        case $pattern in
            "kubernetes_focused")
                # Focus on Kubernetes prompts - same prefix "Explain Kubernetes"
                # This maximizes cache hits when distributed across pods
                idx=$(( RANDOM % ${#KUBERNETES_PROMPTS[@]} ))
                prompt="${KUBERNETES_PROMPTS[$idx]}"
                max_tokens=100
                sleep_time=0.3
                ;;

            "ml_focused")
                # Focus on ML prompts - same prefix "Describe how machine learning"
                idx=$(( RANDOM % ${#ML_PROMPTS[@]} ))
                prompt="${ML_PROMPTS[$idx]}"
                max_tokens=100
                sleep_time=0.3
                ;;

            "distributed_systems_focused")
                # Focus on distributed systems - same prefix "What are the key concepts"
                idx=$(( RANDOM % ${#DISTRIBUTED_SYSTEMS_PROMPTS[@]} ))
                prompt="${DISTRIBUTED_SYSTEMS_PROMPTS[$idx]}"
                max_tokens=100
                sleep_time=0.3
                ;;

            "llm_serving_focused")
                # Focus on LLM serving - same prefix "Provide details about"
                idx=$(( RANDOM % ${#LLM_SERVING_PROMPTS[@]} ))
                prompt="${LLM_SERVING_PROMPTS[$idx]}"
                max_tokens=100
                sleep_time=0.3
                ;;

            "prefix_rotation")
                # Rotate through all prompt sets to test different prefixes
                case $((request_count % 4)) in
                    0)
                        idx=$(( RANDOM % ${#KUBERNETES_PROMPTS[@]} ))
                        prompt="${KUBERNETES_PROMPTS[$idx]}"
                        ;;
                    1)
                        idx=$(( RANDOM % ${#ML_PROMPTS[@]} ))
                        prompt="${ML_PROMPTS[$idx]}"
                        ;;
                    2)
                        idx=$(( RANDOM % ${#DISTRIBUTED_SYSTEMS_PROMPTS[@]} ))
                        prompt="${DISTRIBUTED_SYSTEMS_PROMPTS[$idx]}"
                        ;;
                    3)
                        idx=$(( RANDOM % ${#LLM_SERVING_PROMPTS[@]} ))
                        prompt="${LLM_SERVING_PROMPTS[$idx]}"
                        ;;
                esac
                max_tokens=100
                sleep_time=0.3
                ;;

            "mixed_lengths")
                # Mix short and long prompts to vary KV cache transfer sizes
                if [ $((request_count % 3)) -eq 0 ]; then
                    idx=$(( RANDOM % ${#SHORT_PROMPTS[@]} ))
                    prompt="${SHORT_PROMPTS[$idx]}"
                    max_tokens=50
                else
                    # Pick from any long prompt set
                    set_choice=$((RANDOM % 4))
                    case $set_choice in
                        0) idx=$(( RANDOM % ${#KUBERNETES_PROMPTS[@]} )); prompt="${KUBERNETES_PROMPTS[$idx]}" ;;
                        1) idx=$(( RANDOM % ${#ML_PROMPTS[@]} )); prompt="${ML_PROMPTS[$idx]}" ;;
                        2) idx=$(( RANDOM % ${#DISTRIBUTED_SYSTEMS_PROMPTS[@]} )); prompt="${DISTRIBUTED_SYSTEMS_PROMPTS[$idx]}" ;;
                        3) idx=$(( RANDOM % ${#LLM_SERVING_PROMPTS[@]} )); prompt="${LLM_SERVING_PROMPTS[$idx]}" ;;
                    esac
                    max_tokens=100
                fi
                sleep_time=0.3
                ;;

            "rapid_fire_kubernetes")
                # Rapid-fire same prefix to maximize cache hits in short time
                idx=$(( RANDOM % ${#KUBERNETES_PROMPTS[@]} ))
                prompt="${KUBERNETES_PROMPTS[$idx]}"
                max_tokens=50
                sleep_time=0.1  # Very short delay
                ;;

            "rapid_fire_ml")
                # Rapid-fire ML prompts
                idx=$(( RANDOM % ${#ML_PROMPTS[@]} ))
                prompt="${ML_PROMPTS[$idx]}"
                max_tokens=50
                sleep_time=0.1  # Very short delay
                ;;

            *)
                # Default: rotate through all prompts
                set_choice=$((request_count % 4))
                case $set_choice in
                    0) idx=$(( RANDOM % ${#KUBERNETES_PROMPTS[@]} )); prompt="${KUBERNETES_PROMPTS[$idx]}" ;;
                    1) idx=$(( RANDOM % ${#ML_PROMPTS[@]} )); prompt="${ML_PROMPTS[$idx]}" ;;
                    2) idx=$(( RANDOM % ${#DISTRIBUTED_SYSTEMS_PROMPTS[@]} )); prompt="${DISTRIBUTED_SYSTEMS_PROMPTS[$idx]}" ;;
                    3) idx=$(( RANDOM % ${#LLM_SERVING_PROMPTS[@]} )); prompt="${LLM_SERVING_PROMPTS[$idx]}" ;;
                esac
                max_tokens=100
                sleep_time=0.3
                ;;
        esac

        send_request "$worker_id" "$request_count" "$prompt" "$max_tokens"
        sleep "$sleep_time"
    done

    echo "[Worker $worker_id] Completed with $request_count requests"
}

# Distribute workers across different patterns
# This creates optimal load for NIXL cache transfers
patterns=(
    "kubernetes_focused"         # Worker 1: Focus on Kubernetes prefix
    "ml_focused"                 # Worker 2: Focus on ML prefix
    "distributed_systems_focused"# Worker 3: Focus on distributed systems prefix
    "llm_serving_focused"        # Worker 4: Focus on LLM serving prefix
    "prefix_rotation"            # Worker 5: Rotate through all prefixes
    "mixed_lengths"              # Worker 6: Vary transfer sizes
    "rapid_fire_kubernetes"      # Worker 7: Rapid Kubernetes requests
    "rapid_fire_ml"              # Worker 8: Rapid ML requests
)

# Start workers in background
end_time=$(($(date +%s) + DURATION_MINUTES * 60))

echo "Starting $CONCURRENT_WORKERS concurrent workers..."
echo ""

for i in $(seq 1 $CONCURRENT_WORKERS); do
    pattern_idx=$(( (i - 1) % ${#patterns[@]} ))
    pattern="${patterns[$pattern_idx]}"
    worker_load_generator "$i" "$pattern" "$end_time" &

    # Stagger worker starts slightly to avoid thundering herd
    sleep 0.2
done

# Monitor progress
start_time=$(date +%s)
echo "============================================================"
echo "Load generation in progress... (Ctrl+C to stop)"
echo "============================================================"
echo ""

# Show periodic statistics
while [ $(date +%s) -lt $end_time ]; do
    sleep 10
    read total success fail <<< "$(get_stats)"
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    remaining=$((end_time - current_time))

    if [ $total -gt 0 ]; then
        success_rate=$((success * 100 / total))
        throughput=$(awk "BEGIN {printf \"%.1f\", $total / $elapsed}")
    else
        success_rate=0
        throughput=0.0
    fi

    echo "[$(date '+%H:%M:%S')] Progress: ${total} total | ${success} success | ${fail} failed | ${success_rate}% success | ${throughput} req/s | Remaining: ${remaining}s"
done

# Wait for all workers to complete
wait

# Final statistics
read total success fail <<< "$(get_stats)"
duration=$(($(date +%s) - start_time))
throughput=$(awk "BEGIN {printf \"%.2f\", $total / $duration}")

echo ""
echo "============================================================"
echo "   Load Generation Complete"
echo "============================================================"
echo "Duration:        ${duration}s (${DURATION_MINUTES} minutes)"
echo "Total Requests:  $total"
echo "Successful:      $success"
echo "Failed:          $fail"
echo "Success Rate:    $(awk "BEGIN {printf \"%.1f\", $success * 100 / $total}")%"
echo "Avg Throughput:  ${throughput} req/s"
echo ""
echo "Worker Distribution (optimized for NIXL transfers):"
echo "  - Kubernetes-focused: Workers using 'Explain Kubernetes...' prefix"
echo "  - ML-focused: Workers using 'Describe how machine learning...' prefix"
echo "  - Distributed Systems: Workers using 'What are the key concepts...' prefix"
echo "  - LLM Serving: Workers using 'Provide details about...' prefix"
echo "  - Prefix Rotation: Workers cycling through all prefix sets"
echo "  - Mixed Lengths: Workers varying prompt lengths (different transfer sizes)"
echo "  - Rapid Fire: Workers with minimal delays to maximize cache hits"
echo ""
echo "Expected NIXL KV Cache Transfer Metrics:"
echo "  - Total requests distributed across 4 decode pods: ~$total"
echo "  - Expected NIXL transfers when prefix cache hits occur on different pods"
echo "  - vllm:nixl_xfer_time_seconds: ~5-20ms per transfer (TCP)"
echo "  - vllm:nixl_bytes_transferred: Varies by prompt length (KV cache size)"
echo "  - vllm:nixl_post_time_seconds: Post-transfer processing time"
echo "  - vllm:nixl_num_descriptors: NIXL descriptors allocated for transfers"
echo ""
echo "Next Steps:"
echo "============================================================"
echo "1. Open Grafana Dashboard:"
echo "   http://localhost:3000/d/pd-coordinator-metrics"
echo ""
echo "2. Check NIXL KV Cache Transfer Metrics section:"
echo "   • Avg KV Transfer Time (should be 5-20ms with TCP)"
echo "   • Avg MB per Transfer (varies by prompt length)"
echo "   • Total KV Transfers (increases when prefix cache hits on different pods)"
echo "   • KV Transfer Time Percentiles (p50, p95, p99)"
echo "   • Bytes Transferred Over Time"
echo ""
echo "3. Verify metrics directly from vLLM pods:"
echo "   kubectl port-forward <decode-pod> 8200:8200"
echo "   curl http://localhost:8200/metrics | grep nixl"
echo ""
echo "4. Check EPP metrics for prefix cache scoring:"
echo "   kubectl port-forward <epp-pod> 9090:9090"
echo "   curl http://localhost:9090/metrics | grep prefix_cache"
echo ""
echo "5. How NIXL transfers work:"
echo "   • Request A: 'Explain Kubernetes...' → Pod 1 (generates KV cache)"
echo "   • Request B: 'Explain Kubernetes networking...' → Pod 2 (routed by EPP)"
echo "   • Pod 2 detects prefix match, fetches KV cache from Pod 1 via NIXL"
echo "   • vllm:nixl_xfer_time_seconds and vllm:nixl_bytes_transferred populate"
echo ""
echo "============================================================"

# Cleanup
rm -rf "$STATS_DIR"
