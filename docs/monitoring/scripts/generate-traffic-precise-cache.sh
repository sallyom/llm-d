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
echo "  ✓ LONG prompts (300+ chars) spanning multiple KV cache blocks"
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

# LONG prompts with shared prefixes - designed to span multiple KV cache blocks (64 tokens each)
# These prompts are 300+ characters (~100+ tokens) to ensure they span at least 2 blocks

LONG_SHARED_PREFIX_K8S="In a production Kubernetes cluster running microservices at scale with hundreds of pods across multiple namespaces, consider the complexities of resource management, scheduling, networking, and observability. The cluster administrator needs to ensure optimal resource utilization, fair sharing among tenants, and reliable application performance. Given this context, explain in detail how"

LONG_SUFFIX_VARIANTS_K8S=(
    "the Kubernetes scheduler makes placement decisions using node affinity, pod affinity and anti-affinity rules, taints and tolerations, and resource requests and limits to ensure pods are optimally distributed across the cluster while respecting application-specific constraints and maintaining high availability."
    "horizontal pod autoscaling (HPA) monitors application metrics and dynamically adjusts replica counts in response to changing workload patterns, including the role of metrics server, custom metrics from Prometheus, and external metrics from cloud providers in making scaling decisions."
    "resource quotas and limit ranges work together to prevent resource exhaustion at the namespace level, including how they enforce constraints on CPU, memory, persistent volume claims, and object counts, and how they interact with pod priority and preemption mechanisms."
    "the container network interface (CNI) plugins enable pod-to-pod communication across nodes, implement network policies for traffic segmentation, and integrate with service mesh solutions like Istio for advanced traffic management, observability, and security features."
    "distributed tracing with OpenTelemetry can be implemented across microservices to capture request flows through the service mesh, including automatic instrumentation, manual span creation, context propagation through headers, and integration with backends like Jaeger and Tempo for trace visualization and analysis."
)

LONG_SHARED_PREFIX_LLM="When building a high-performance LLM inference serving system that needs to handle thousands of concurrent requests with low latency and high throughput, engineers must consider model optimization techniques, efficient memory management, batching strategies, and observability. The system uses vLLM for serving transformer-based models with features like paged attention, continuous batching, and prefix caching. In this architecture, describe comprehensively"

LONG_SUFFIX_VARIANTS_LLM=(
    "how prefix caching with block-level KV cache management reduces redundant computation for requests sharing common prompt prefixes, including the hash-based indexing mechanism, block eviction policies, and the trade-offs between cache hit rate and memory usage across multiple concurrent requests."
    "how continuous batching differs fundamentally from static batching by allowing new requests to join in-flight batches during the decode phase, including the scheduling algorithms that determine batch composition, iteration-level scheduling decisions, and the impact on both throughput and latency percentiles."
    "how paged attention manages KV cache memory more efficiently than contiguous allocation by organizing cache into fixed-size blocks that can be non-contiguously allocated, including the page table implementation, block sharing for prefix caching, and copy-on-write mechanisms during sequence forking."
    "how tensor parallelism and pipeline parallelism enable serving large models that exceed single GPU memory capacity, including the communication patterns between GPUs, the trade-offs between different parallelism strategies, and how these interact with attention mechanisms and batch processing."
    "how distributed tracing can provide deep observability into the inference pipeline, capturing spans for model loading, tokenization, prefill phase, decode iterations, KV cache operations, and batching decisions, with custom attributes that expose internal metrics like cache hit rates, batch utilization, and GPU memory usage."
)

LONG_SHARED_PREFIX_OBSERVABILITY="Modern cloud-native applications running on Kubernetes require comprehensive observability across multiple signal types including metrics, logs, and distributed traces. OpenTelemetry provides a vendor-neutral standard for collecting telemetry data with automatic instrumentation for common frameworks and manual instrumentation for custom logic. When implementing observability for a microservices architecture with distributed tracing, explain thoroughly"

LONG_SUFFIX_VARIANTS_OBSERVABILITY=(
    "how trace context propagation works using W3C traceparent and tracestate headers to maintain correlation across service boundaries, including the role of trace IDs, span IDs, parent-child relationships, and how baggage is used to carry request-scoped data through the distributed system without explicit parameter passing."
    "how sampling strategies balance observability coverage with storage and performance costs, comparing head-based sampling that makes decisions at trace creation, tail-based sampling that examines complete traces, and adaptive sampling that adjusts rates based on error conditions, latency thresholds, or other runtime characteristics."
    "how span processors and exporters buffer, batch, and transmit telemetry data to backend systems, including the trade-offs between synchronous and asynchronous export, retry logic for handling backend failures, and best practices for minimizing the performance impact of instrumentation on production services."
    "how semantic conventions standardize attribute naming and values across different telemetry signals, enabling consistent querying and correlation between traces, metrics, and logs, including domain-specific conventions for HTTP, database, messaging, and custom application attributes."
    "how trace querying languages like TraceQL enable sophisticated analysis of distributed traces through filtering by span attributes, aggregating metrics across traces, identifying performance anomalies, and correlating with other observability signals to debug complex failure modes in production systems."
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

            "long_shared_k8s")
                # LONG prompts with shared K8s prefix - spans multiple KV cache blocks
                suffix_idx=$(( RANDOM % ${#LONG_SUFFIX_VARIANTS_K8S[@]} ))
                prompt="${LONG_SHARED_PREFIX_K8S} ${LONG_SUFFIX_VARIANTS_K8S[$suffix_idx]}"
                max_tokens=200
                cache_pattern="LONG_SHARED_K8S"
                sleep_time=0.6
                ;;

            "long_shared_llm")
                # LONG prompts with shared LLM prefix - spans multiple KV cache blocks
                suffix_idx=$(( RANDOM % ${#LONG_SUFFIX_VARIANTS_LLM[@]} ))
                prompt="${LONG_SHARED_PREFIX_LLM} ${LONG_SUFFIX_VARIANTS_LLM[$suffix_idx]}"
                max_tokens=200
                cache_pattern="LONG_SHARED_LLM"
                sleep_time=0.6
                ;;

            "long_shared_observability")
                # LONG prompts with shared observability prefix - spans multiple KV cache blocks
                suffix_idx=$(( RANDOM % ${#LONG_SUFFIX_VARIANTS_OBSERVABILITY[@]} ))
                prompt="${LONG_SHARED_PREFIX_OBSERVABILITY} ${LONG_SUFFIX_VARIANTS_OBSERVABILITY[$suffix_idx]}"
                max_tokens=200
                cache_pattern="LONG_SHARED_OBSERVABILITY"
                sleep_time=0.6
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
    "long_shared_k8s"         # Worker 1: LONG K8s prompts spanning multiple blocks
    "long_shared_llm"         # Worker 2: LONG LLM prompts spanning multiple blocks
    "long_shared_observability" # Worker 3: LONG observability prompts spanning multiple blocks
    "exact_repeats"           # Worker 4: Maximum cache hits (short prompts)
    "shared_prefix_k8s"       # Worker 5: Partial K8s prefix hits (short)
    "shared_prefix_tracing"   # Worker 6: Partial tracing prefix hits (short)
    "shared_prefix_llm"       # Worker 7: Partial LLM prefix hits (short)
    "mixed_cache_aware"       # Worker 8+: Realistic production mix
    "warmup_then_repeat"      # Worker 9+: Show warmup → cache hit transition
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
echo "  - LONG Shared K8s:      300+ char prompts spanning 2+ KV cache blocks → strong prefix hits"
echo "  - LONG Shared LLM:      300+ char prompts spanning 2+ KV cache blocks → strong prefix hits"
echo "  - LONG Shared Observ:   300+ char prompts spanning 2+ KV cache blocks → strong prefix hits"
echo "  - Exact Repeats:        Identical short prompts → maximum cache hits"
echo "  - Shared Prefix (K8s):  Common K8s prefix → partial cache hits (short prompts)"
echo "  - Shared Prefix (Trace): Common tracing prefix → partial cache hits (short prompts)"
echo "  - Shared Prefix (LLM):  Common LLM prefix → partial cache hits (short prompts)"
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
