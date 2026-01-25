#!/bin/bash

# Traffic Generator for Precise Prefix Cache Awareness Tracing
#
# This script generates traffic optimized to showcase precise prefix cache-aware
# routing and the tracing insights it provides for understanding cache hit behavior.
#
# Usage: ./generate-traffic-precise-cache.sh [concurrent_workers] [duration_minutes] [endpoint]
#
# KEY SCENARIOS DEMONSTRATED:
# 1. SHARED PREFIX HITS: Repeated prompts with common prefixes show cache scoring in action
# 2. CACHE-AWARE ROUTING: Traces show which endpoints were selected based on KV cache state
# 3. SCORING INSIGHTS: Trace attributes reveal precise-prefix-cache-scorer decisions
# 4. HIT RATE IMPACT: Compare TTFT for cache hits vs misses across different endpoints
# 5. KV EVENTS: Shows KV cache event propagation and indexer state updates
#
# Tracing reveals:
# - Which endpoint was selected and why (cache score, queue score, utilization score)
# - How many blocks were cached vs computed fresh
# - TTFT improvement from cache hits (comparing cached vs non-cached requests)
# - Routing decisions across multiple endpoints based on cache state

set -e

# Configuration
ENDPOINT="${ENDPOINT:-http://localhost:8000/v1}"
CONCURRENT_WORKERS=${1:-4}
DURATION_MINUTES=${2:-5}
MODEL_NAME="${MODEL_NAME:-meta-llama/Llama-3.1-8B-Instruct}"

# Shared counter for statistics (macOS-compatible)
STATS_DIR="/tmp/precise_cache_stats_$$"
mkdir -p "$STATS_DIR"
echo "0" > "$STATS_DIR/total"
echo "0" > "$STATS_DIR/success"
echo "0" > "$STATS_DIR/fail"

increment_stat() {
    local stat_type=$1

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
echo "   Precise Prefix Cache-Aware Routing Traffic Generator"
echo "============================================================"
echo "Endpoint:     $ENDPOINT"
echo "Model:        $MODEL_NAME"
echo "Workers:      $CONCURRENT_WORKERS"
echo "Duration:     $DURATION_MINUTES minutes"
echo ""
echo "This script creates traffic patterns to showcase:"
echo "  ✓ Shared prefix cache hits across requests"
echo "  ✓ Cache-aware routing decisions (endpoint selection based on KV cache state)"
echo "  ✓ Scoring breakdown (cache score vs queue score vs utilization score)"
echo "  ✓ TTFT improvement from cache hits (comparing cached vs fresh computation)"
echo "  ✓ KV events propagation and indexer state updates"
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

# Prompt templates designed for prefix caching demonstration
# These prompts share common prefixes to trigger cache-aware routing

# System prompts - repeated to build cache across endpoints
SYSTEM_PROMPTS=(
    "You are a helpful AI assistant specialized in Kubernetes and cloud-native technologies."
    "You are an expert in distributed systems and microservices architecture."
    "You are a senior software engineer with expertise in Go, Python, and infrastructure."
)

# Base prompts - shared prefixes for demonstrating cache scoring
BASE_PREFIX_1="In the context of Kubernetes resource management and pod scheduling, explain how"
SUFFIX_VARIANTS_1=(
    "the scheduler selects nodes based on resource requests and limits."
    "resource quotas prevent namespace overconsumption of cluster resources."
    "horizontal pod autoscaling responds to increased workload demands."
    "node affinity and anti-affinity rules influence pod placement decisions."
    "priority classes determine which pods get scheduled first during resource contention."
)

BASE_PREFIX_2="When designing a distributed tracing system for microservices, describe"
SUFFIX_VARIANTS_2=(
    "how trace context is propagated across service boundaries using W3C traceparent headers."
    "the trade-offs between head-based and tail-based sampling strategies."
    "how to design effective span hierarchies that capture meaningful service interactions."
    "the best practices for adding custom attributes without excessive cardinality."
    "how to query distributed traces effectively using TraceQL for performance analysis."
)

BASE_PREFIX_3="For LLM inference serving with vLLM, explain the implementation details of"
SUFFIX_VARIANTS_3=(
    "continuous batching and how it differs from static batching approaches."
    "prefix caching and how it reduces computation for repeated prompt prefixes."
    "paged attention and how it manages KV cache memory more efficiently."
    "speculative decoding and its impact on generation throughput and latency."
    "tensor parallelism for distributing model parameters across multiple GPUs."
)

# Exactly repeated prompts - highest cache hit rate
REPEATED_PROMPTS=(
    "What is the difference between a Kubernetes Deployment and a StatefulSet?"
    "How does distributed tracing help debug microservices performance issues?"
    "Explain the prefill and decode phases in transformer-based LLM inference."
)

# Send request with custom headers for better tracing
send_request() {
    local worker_id=$1
    local request_num=$2
    local prompt=$3
    local max_tokens=$4
    local cache_pattern=$5  # Indicates expected cache behavior

    local start_time=$(date +%s%N)

    # Generate unique request ID for tracing
    local request_id="worker${worker_id}-req${request_num}-$(date +%s%N | tail -c 8)"

    local response=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Request-ID: $request_id" \
        -H "X-Cache-Pattern: $cache_pattern" \
        -d "{
            \"model\": \"$MODEL_NAME\",
            \"messages\": [
                {\"role\": \"user\", \"content\": $(echo "$prompt" | jq -Rs .)}
            ],
            \"max_tokens\": $max_tokens,
            \"temperature\": 0.7
        }" 2>&1)

    local end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))

    local http_code=$(echo "$response" | tail -n1)
    local prompt_length=${#prompt}

    if [ "$http_code" = "200" ]; then
        increment_stat success
        echo "[$(date '+%H:%M:%S')] W${worker_id}-${request_num} | ${cache_pattern} | ${prompt_length}ch/${max_tokens}t | ${duration_ms}ms | ✓"
    else
        increment_stat failure
        echo "[$(date '+%H:%M:%S')] W${worker_id}-${request_num} | ${cache_pattern} | ${prompt_length}ch/${max_tokens}t | ${duration_ms}ms | ✗ HTTP${http_code}"
    fi
}

# Worker function with cache-focused traffic patterns
worker_cache_pattern() {
    local worker_id=$1
    local pattern=$2
    local end_time=$3

    local request_count=0

    echo "[Worker $worker_id] Started with pattern: $pattern"

    while [ $(date +%s) -lt $end_time ]; do
        request_count=$((request_count + 1))

        # Select prompt based on caching pattern
        case $pattern in
            "exact_repeats")
                # Send the same prompts repeatedly to maximize cache hits
                # This should show strong cache scoring and consistent endpoint selection
                idx=$(( RANDOM % ${#REPEATED_PROMPTS[@]} ))
                prompt="${REPEATED_PROMPTS[$idx]}"
                max_tokens=100
                cache_pattern="EXACT_REPEAT"
                sleep_time=0.5
                ;;

            "shared_prefix_k8s")
                # Prompts with shared K8s prefix - demonstrates partial cache hits
                # Cache scorer should route to endpoints with prefix cached
                suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_1[@]} ))
                prompt="${BASE_PREFIX_1} ${SUFFIX_VARIANTS_1[$suffix_idx]}"
                max_tokens=150
                cache_pattern="SHARED_PREFIX_K8S"
                sleep_time=0.4
                ;;

            "shared_prefix_tracing")
                # Prompts with shared tracing prefix
                suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_2[@]} ))
                prompt="${BASE_PREFIX_2} ${SUFFIX_VARIANTS_2[$suffix_idx]}"
                max_tokens=150
                cache_pattern="SHARED_PREFIX_TRACING"
                sleep_time=0.4
                ;;

            "shared_prefix_llm")
                # Prompts with shared LLM prefix
                suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_3[@]} ))
                prompt="${BASE_PREFIX_3} ${SUFFIX_VARIANTS_3[$suffix_idx]}"
                max_tokens=150
                cache_pattern="SHARED_PREFIX_LLM"
                sleep_time=0.4
                ;;

            "mixed_cache_aware")
                # Realistic mix: some repeated, some shared prefix, some unique
                case $((request_count % 10)) in
                    0|1|2|3)
                        # 40% shared prefix (K8s)
                        suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_1[@]} ))
                        prompt="${BASE_PREFIX_1} ${SUFFIX_VARIANTS_1[$suffix_idx]}"
                        max_tokens=120
                        cache_pattern="MIXED_SHARED_K8S"
                        ;;
                    4|5|6)
                        # 30% exact repeats
                        idx=$(( RANDOM % ${#REPEATED_PROMPTS[@]} ))
                        prompt="${REPEATED_PROMPTS[$idx]}"
                        max_tokens=100
                        cache_pattern="MIXED_EXACT"
                        ;;
                    7|8)
                        # 20% shared prefix (LLM)
                        suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_3[@]} ))
                        prompt="${BASE_PREFIX_3} ${SUFFIX_VARIANTS_3[$suffix_idx]}"
                        max_tokens=140
                        cache_pattern="MIXED_SHARED_LLM"
                        ;;
                    9)
                        # 10% completely unique (no cache benefit)
                        prompt="Explain a completely unique topic: $(date +%s%N | md5 | head -c 10)"
                        max_tokens=80
                        cache_pattern="MIXED_UNIQUE"
                        ;;
                esac
                sleep_time=0.3
                ;;

            "warmup_then_repeat")
                # First half: send diverse prompts to warm up caches across endpoints
                # Second half: repeat those prompts to show cache hit benefits
                if [ $request_count -lt 20 ]; then
                    # Warmup phase: diverse prompts
                    case $((request_count % 3)) in
                        0)
                            suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_1[@]} ))
                            prompt="${BASE_PREFIX_1} ${SUFFIX_VARIANTS_1[$suffix_idx]}"
                            ;;
                        1)
                            suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_2[@]} ))
                            prompt="${BASE_PREFIX_2} ${SUFFIX_VARIANTS_2[$suffix_idx]}"
                            ;;
                        2)
                            suffix_idx=$(( RANDOM % ${#SUFFIX_VARIANTS_3[@]} ))
                            prompt="${BASE_PREFIX_3} ${SUFFIX_VARIANTS_3[$suffix_idx]}"
                            ;;
                    esac
                    max_tokens=120
                    cache_pattern="WARMUP"
                    sleep_time=0.6
                else
                    # Repeat phase: cycle through the warmed-up prompts
                    repeat_idx=$(( (request_count - 20) % 9 ))
                    case $((repeat_idx % 3)) in
                        0)
                            suffix_idx=$((repeat_idx / 3))
                            prompt="${BASE_PREFIX_1} ${SUFFIX_VARIANTS_1[$suffix_idx]}"
                            ;;
                        1)
                            suffix_idx=$((repeat_idx / 3))
                            prompt="${BASE_PREFIX_2} ${SUFFIX_VARIANTS_2[$suffix_idx]}"
                            ;;
                        2)
                            suffix_idx=$((repeat_idx / 3))
                            prompt="${BASE_PREFIX_3} ${SUFFIX_VARIANTS_3[$suffix_idx]}"
                            ;;
                    esac
                    max_tokens=120
                    cache_pattern="REPEAT_AFTER_WARMUP"
                    sleep_time=0.4
                fi
                ;;

            *)
                # Default: exact repeats
                idx=$(( RANDOM % ${#REPEATED_PROMPTS[@]} ))
                prompt="${REPEATED_PROMPTS[$idx]}"
                max_tokens=100
                cache_pattern="DEFAULT"
                sleep_time=0.5
                ;;
        esac

        send_request "$worker_id" "$request_count" "$prompt" "$max_tokens" "$cache_pattern"
        sleep "$sleep_time"
    done

    echo "[Worker $worker_id] Completed with $request_count requests"
}

# Distribute workers across cache-focused patterns
patterns=(
    "exact_repeats"           # Worker 1: Maximum cache hits
    "shared_prefix_k8s"       # Worker 2: Partial K8s prefix hits
    "shared_prefix_tracing"   # Worker 3: Partial tracing prefix hits
    "shared_prefix_llm"       # Worker 4: Partial LLM prefix hits
    "mixed_cache_aware"       # Worker 5+: Realistic production mix
    "warmup_then_repeat"      # Worker 6+: Show warmup → cache hit transition
)

# Start workers in background
end_time=$(($(date +%s) + DURATION_MINUTES * 60))

echo "Starting $CONCURRENT_WORKERS concurrent workers..."
echo ""

for i in $(seq 1 $CONCURRENT_WORKERS); do
    pattern_idx=$(( (i - 1) % ${#patterns[@]} ))
    pattern="${patterns[$pattern_idx]}"
    worker_cache_pattern "$i" "$pattern" "$end_time" &

    # Stagger worker starts slightly
    sleep 0.2
done

# Monitor progress
start_time=$(date +%s)
echo "============================================================"
echo "Traffic generation in progress... (Ctrl+C to stop)"
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
echo "   Traffic Generation Complete"
echo "============================================================"
echo "Duration:        ${duration}s (${DURATION_MINUTES} minutes)"
echo "Total Requests:  $total"
echo "Successful:      $success"
echo "Failed:          $fail"
echo "Success Rate:    $(awk "BEGIN {printf \"%.1f\", $success * 100 / $total}")%"
echo "Avg Throughput:  ${throughput} req/s"
echo ""
echo "Worker Distribution:"
echo "  - Exact Repeats:        Identical prompts → maximum cache hits"
echo "  - Shared Prefix (K8s):  Common K8s prefix → partial cache hits"
echo "  - Shared Prefix (Trace): Common tracing prefix → partial cache hits"
echo "  - Shared Prefix (LLM):  Common LLM prefix → partial cache hits"
echo "  - Mixed Cache-Aware:    Realistic production traffic (repeats + prefixes + unique)"
echo "  - Warmup then Repeat:   Shows cache warmup phase vs cache hit phase"
echo ""
echo "Expected Trace Spans & Attributes:"
echo "  - llm_d.inference_scheduler.endpoint_picker: ~$total spans with routing decisions"
echo "  - vllm.llm_request: ~$total spans on selected endpoints"
echo ""
echo "Key Trace Attributes to Examine:"
echo "  - llm_d.scorer.precise_prefix_cache.score: Cache score for each endpoint"
echo "  - llm_d.scorer.queue.score: Queue depth score for each endpoint"
echo "  - llm_d.scorer.kv_cache_utilization.score: KV cache utilization score"
echo "  - llm_d.picker.selected_endpoint: Which endpoint was chosen"
echo "  - llm_d.kv_cache.cached_blocks: Number of KV blocks found in cache"
echo "  - llm_d.kv_cache.computed_blocks: Number of KV blocks computed fresh"
echo "  - gen_ai.latency.time_to_first_token: TTFT (should be lower for cache hits)"
echo ""
echo "Next Steps:"
echo "============================================================"
echo "1. Open Grafana Tempo/Explore to view traces:"
echo "   http://localhost:3000/explore"
echo ""
echo "2. Query traces with TraceQL:"
echo ""
echo "   a) Find all requests with high cache scores:"
echo "      {resource.service.name=\"llm-d-inference-scheduler\" && name=\"llm_d.inference_scheduler.endpoint_picker\"}"
echo ""
echo "   b) Compare TTFT for cache hits vs misses:"
echo "      {resource.service.name=\"vllm-decode\" && name=\"vllm.llm_request\"} | select(span.gen_ai.latency.time_to_first_token)"
echo ""
echo "   c) Find routing decisions where precise-prefix-cache-scorer was highest:"
echo "      {span.llm_d.scorer.precise_prefix_cache.score > 0.7}"
echo ""
echo "3. Key Insights to Look For:"
echo "   • Endpoint Selection: Traces show which endpoint was selected and why"
echo "   • Scoring Breakdown: See cache_score, queue_score, utilization_score for each candidate"
echo "   • Cache Hit Rate: Compare cached_blocks vs computed_blocks"
echo "   • TTFT Improvement: Cache hits should show notably lower TTFT"
echo "   • KV Events: Observe KV cache event propagation and indexer updates"
echo ""
echo "4. Demo Talking Points:"
echo "   ✓ Show trace with high cache score → fast TTFT"
echo "   ✓ Show trace with low cache score → slower TTFT (fresh computation)"
echo "   ✓ Show routing decision across 4 endpoints → cache-aware selection"
echo "   ✓ Show KV cache indexer state updates from KV events"
echo "   ✓ Highlight observability gap without tracing (can't see why endpoint was chosen)"
echo ""
echo "============================================================"

# Cleanup
rm -rf "$STATS_DIR"
