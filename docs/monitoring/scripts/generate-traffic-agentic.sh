#!/bin/bash

# Concurrent traffic generator for agentic/tool-calling workloads.
#
# This script is optimized for:
# - repeated system prompts and tool schemas
# - multi-turn tool-calling loops
# - precise prefix-cache-aware routing demonstrations
# - distributed tracing of agentic request patterns
#
# Usage: ./generate-traffic-agentic.sh [concurrent_workers] [duration_minutes] [endpoint]
#
# Environment variables:
#   MODEL_NAME    OpenAI-compatible model name
#   ENDPOINT      OpenAI-compatible /v1 endpoint base
#
# Example:
#   MODEL_NAME=google/gemma-4-26B-A4B-it \
#   ./generate-traffic-agentic.sh 4 5 http://localhost:8000/v1

set -euo pipefail

ENDPOINT="${ENDPOINT:-${3:-http://localhost:8000/v1}}"
CONCURRENT_WORKERS="${1:-4}"
DURATION_MINUTES="${2:-5}"
MODEL_NAME="${MODEL_NAME:-google/gemma-4-26B-A4B-it}"

STATS_DIR="/tmp/agentic_load_gen_stats_$$"
mkdir -p "$STATS_DIR"
: > "$STATS_DIR/total"
: > "$STATS_DIR/success"
: > "$STATS_DIR/fail"
: > "$STATS_DIR/tool_calls"
: > "$STATS_DIR/episodes"

cleanup() {
    rm -rf "$STATS_DIR"
}
trap cleanup EXIT

increment_stat() {
    local stat_type=$1
    echo "1" >> "$STATS_DIR/$stat_type"
}

get_stats() {
    local total success fail tool_calls episodes
    total=$(cat "$STATS_DIR/total" 2>/dev/null | wc -l | tr -d ' ')
    success=$(cat "$STATS_DIR/success" 2>/dev/null | wc -l | tr -d ' ')
    fail=$(cat "$STATS_DIR/fail" 2>/dev/null | wc -l | tr -d ' ')
    tool_calls=$(cat "$STATS_DIR/tool_calls" 2>/dev/null | wc -l | tr -d ' ')
    episodes=$(cat "$STATS_DIR/episodes" 2>/dev/null | wc -l | tr -d ' ')
    echo "$total $success $fail $tool_calls $episodes"
}

read -r -d '' SYSTEM_PROMPT <<'EOF' || true
You are an operations copilot used inside an agentic workflow.

Follow this policy on every turn:
1. Reuse the available tools whenever external state is needed.
2. Prefer tool calls over guessing.
3. If a tool is helpful, call it before answering.
4. After tool results arrive, produce a concise operational answer with next steps.
5. Keep answers short and factual.
EOF

read -r -d '' TOOLS_JSON <<'EOF' || true
[
  {
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get current weather for a city or region.",
      "parameters": {
        "type": "object",
        "properties": {
          "location": { "type": "string", "description": "City and region" },
          "unit": { "type": "string", "enum": ["celsius", "fahrenheit"] }
        },
        "required": ["location"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_docs",
      "description": "Search internal documentation for deployment and operations guidance.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string" },
          "product": { "type": "string" }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "check_calendar",
      "description": "Check on-call or meeting calendar availability.",
      "parameters": {
        "type": "object",
        "properties": {
          "team": { "type": "string" },
          "date": { "type": "string", "description": "ISO date" }
        },
        "required": ["team", "date"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "lookup_ticket",
      "description": "Lookup an incident, support, or engineering ticket.",
      "parameters": {
        "type": "object",
        "properties": {
          "ticket_id": { "type": "string" }
        },
        "required": ["ticket_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "estimate_cost",
      "description": "Estimate cost for a deployment change.",
      "parameters": {
        "type": "object",
        "properties": {
          "service": { "type": "string" },
          "scale": { "type": "string" }
        },
        "required": ["service", "scale"]
      }
    }
  }
]
EOF

AGENTIC_TASKS=(
  "We are planning an agent rollout in Boston. Check weather, look up docs for llm-d tracing, and tell me whether today is a good day for a deployment review."
  "Ticket INC-4821 is blocking a customer launch. Look up the ticket, search docs for prefix cache aware routing, and summarize the next operator action."
  "I need a short plan for enabling tracing on a Gemma 4 deployment. Search docs for tracing and estimate the cost impact of running 4 GPUs."
  "Check the calendar for platform-oncall on 2026-04-03, then search docs for pd-disaggregation and summarize whether it fits long prompt workloads."
  "We want to compare precise prefix cache aware routing against pd-disaggregation for a tool-using agent. Search docs and produce a concise recommendation."
  "Please search docs for Gemma 4 deployment guidance, then estimate cost for a staging service scaled to 4 GPUs."
)

echo "============================================================"
echo "   Agentic Tool-Calling Traffic Generator"
echo "============================================================"
echo "Endpoint:     $ENDPOINT"
echo "Model:        $MODEL_NAME"
echo "Workers:      $CONCURRENT_WORKERS"
echo "Duration:     $DURATION_MINUTES minutes"
echo ""
echo "This script is designed to highlight:"
echo "  ✓ repeated agent system prompts and tool schemas"
echo "  ✓ OpenAI tool calls and tool-result follow-up turns"
echo "  ✓ precise prefix cache reuse on shared agent prefixes"
echo "  ✓ tracing for realistic agentic workflows"
echo ""
echo "============================================================"
echo ""

echo "Checking endpoint availability..."
if ! curl -s -f "$ENDPOINT/models" > /dev/null 2>&1; then
    echo "ERROR: Cannot reach endpoint $ENDPOINT"
    exit 1
fi
echo "✓ Endpoint accessible"
echo ""

mock_tool_result() {
    local tool_name="$1"
    local args_json="$2"

    case "$tool_name" in
        get_weather)
            jq -cn \
              --arg location "$(printf '%s' "$args_json" | jq -r '.location // "Boston, MA"')" \
              --arg unit "$(printf '%s' "$args_json" | jq -r '.unit // "fahrenheit"')" \
              '{location:$location, unit:$unit, temperature:61, conditions:"clear", wind_mph:7, source:"mock-weather"}'
            ;;
        search_docs)
            jq -cn \
              --arg query "$(printf '%s' "$args_json" | jq -r '.query // "llm-d tracing"')" \
              --arg product "$(printf '%s' "$args_json" | jq -r '.product // "llm-d"')" \
              '{
                 query:$query,
                 product:$product,
                 top_results:[
                   {"title":"Distributed Tracing","path":"docs/monitoring/tracing/README.md"},
                   {"title":"Precise Prefix Cache Aware Routing","path":"guides/precise-prefix-cache-aware/README.md"},
                   {"title":"P/D Disaggregation","path":"guides/pd-disaggregation/README.md"}
                 ]
               }'
            ;;
        check_calendar)
            jq -cn \
              --arg team "$(printf '%s' "$args_json" | jq -r '.team // "platform-oncall"')" \
              --arg date "$(printf '%s' "$args_json" | jq -r '.date // "2026-04-03"')" \
              '{team:$team, date:$date, available_windows:["09:00-09:30","13:00-14:00"], source:"mock-calendar"}'
            ;;
        lookup_ticket)
            jq -cn \
              --arg ticket_id "$(printf '%s' "$args_json" | jq -r '.ticket_id // "INC-4821"')" \
              '{ticket_id:$ticket_id, severity:"high", status:"investigating", owner:"platform-inference", source:"mock-ticket-db"}'
            ;;
        estimate_cost)
            jq -cn \
              --arg service "$(printf '%s' "$args_json" | jq -r '.service // "llm-d-gemma4"')" \
              --arg scale "$(printf '%s' "$args_json" | jq -r '.scale // "4-gpu"')" \
              '{service:$service, scale:$scale, estimated_monthly_usd:12400, confidence:"low", source:"mock-cost-model"}'
            ;;
        *)
            jq -cn --arg name "$tool_name" '{tool:$name, result:"mock-result"}'
            ;;
    esac
}

send_chat_completion() {
    local request_id="$1"
    local messages_json="$2"
    local max_tokens="${3:-220}"
    local tool_choice="${4:-auto}"

    local payload
    payload=$(jq -cn \
      --arg model "$MODEL_NAME" \
      --argjson messages "$messages_json" \
      --argjson tools "$TOOLS_JSON" \
      --argjson max_tokens "$max_tokens" \
      --arg tool_choice "$tool_choice" \
      '{
        model: $model,
        messages: $messages,
        tools: $tools,
        tool_choice: $tool_choice,
        temperature: 0.2,
        max_tokens: $max_tokens,
        stream: false
      }')

    curl -sS -w "\n%{http_code}" \
      -X POST "$ENDPOINT/chat/completions" \
      -H "Content-Type: application/json" \
      -H "X-Request-ID: $request_id" \
      -d "$payload"
}

run_agentic_episode() {
    local worker_id="$1"
    local episode_id="$2"
    local task="$3"

    local session_id="agent-session-${worker_id}-${episode_id}"
    local request_prefix="${session_id}-$(date +%s%N)"
    local messages_initial
    messages_initial=$(jq -cn \
      --arg system_prompt "$SYSTEM_PROMPT" \
      --arg user_prompt "$task" \
      '[
         {role:"system", content:$system_prompt},
         {role:"user", content:$user_prompt}
       ]')

    local response_first body_first code_first
    response_first=$(send_chat_completion "${request_prefix}-turn1" "$messages_initial" 240 auto)
    body_first=$(printf '%s' "$response_first" | sed '$d')
    code_first=$(printf '%s' "$response_first" | tail -n1)
    increment_stat total

    if [ "$code_first" != "200" ]; then
        increment_stat fail
        echo "[$(date '+%H:%M:%S')] W${worker_id}-E${episode_id} turn1 | ✗ HTTP${code_first}"
        return
    fi

    local tool_calls_count assistant_message tool_messages
    tool_calls_count=$(printf '%s' "$body_first" | jq '(.choices[0].message.tool_calls // []) | length')
    assistant_message=$(printf '%s' "$body_first" | jq -c '(.choices[0].message // {}) | {role, content, tool_calls}')
    tool_messages='[]'

    if [ "$tool_calls_count" -gt 0 ]; then
        increment_stat success
        increment_stat episodes

        while IFS= read -r call; do
            [ -n "$call" ] || continue
            local tool_name raw_args parsed_args result_json tool_message
            tool_name=$(printf '%s' "$call" | jq -r '.function.name // "unknown_tool"')
            raw_args=$(printf '%s' "$call" | jq -r '.function.arguments // "{}"')
            parsed_args=$(printf '%s' "$raw_args" | jq -c . 2>/dev/null || printf '{}')
            result_json=$(mock_tool_result "$tool_name" "$parsed_args")
            tool_message=$(jq -cn \
              --arg tool_call_id "$(printf '%s' "$call" | jq -r '.id')" \
              --arg name "$tool_name" \
              --arg content "$result_json" \
              '{role:"tool", tool_call_id:$tool_call_id, name:$name, content:$content}')
            tool_messages=$(jq -cn \
              --argjson current "$tool_messages" \
              --argjson next "$tool_message" \
              '$current + [$next]')
            increment_stat tool_calls
        done < <(printf '%s' "$body_first" | jq -c '.choices[0].message.tool_calls[]?')

        local messages_second response_second body_second code_second
        messages_second=$(jq -cn \
          --argjson initial "$messages_initial" \
          --argjson assistant "$assistant_message" \
          --argjson tools_out "$tool_messages" \
          '$initial + [$assistant] + $tools_out')
        response_second=$(send_chat_completion "${request_prefix}-turn2" "$messages_second" 180 none)
        body_second=$(printf '%s' "$response_second" | sed '$d')
        code_second=$(printf '%s' "$response_second" | tail -n1)
        increment_stat total

        if [ "$code_second" = "200" ]; then
            increment_stat success
            local final_chars
            final_chars=$(printf '%s' "$body_second" | jq -r '.choices[0].message.content // ""' | wc -c | tr -d ' ')
            echo "[$(date '+%H:%M:%S')] W${worker_id}-E${episode_id} | tools=${tool_calls_count} | final=${final_chars}ch | ✓"
        else
            increment_stat fail
            echo "[$(date '+%H:%M:%S')] W${worker_id}-E${episode_id} turn2 | tools=${tool_calls_count} | ✗ HTTP${code_second}"
        fi
    else
        increment_stat success
        increment_stat episodes
        echo "[$(date '+%H:%M:%S')] W${worker_id}-E${episode_id} | tools=0 | completed without tool call | ✓"
    fi
}

worker_load_generator() {
    local worker_id="$1"
    local end_time="$2"
    local episode_id=0

    echo "[Worker $worker_id] Started"
    while [ "$(date +%s)" -lt "$end_time" ]; do
        episode_id=$((episode_id + 1))
        local task_idx task
        task_idx=$(( RANDOM % ${#AGENTIC_TASKS[@]} ))
        task="${AGENTIC_TASKS[$task_idx]}"
        run_agentic_episode "$worker_id" "$episode_id" "$task"
        sleep 0.6
    done
    echo "[Worker $worker_id] Completed"
}

end_time=$(($(date +%s) + DURATION_MINUTES * 60))
start_time=$(date +%s)

echo "Starting $CONCURRENT_WORKERS concurrent workers..."
echo ""
for i in $(seq 1 "$CONCURRENT_WORKERS"); do
    worker_load_generator "$i" "$end_time" &
    sleep 0.2
done

echo "============================================================"
echo "Traffic generation in progress... (Ctrl+C to stop)"
echo "============================================================"
echo ""

while [ "$(date +%s)" -lt "$end_time" ]; do
    sleep 10
    read -r total success fail tool_calls episodes <<< "$(get_stats)"
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    remaining=$((end_time - current_time))
    if [ "$total" -gt 0 ]; then
        success_rate=$((success * 100 / total))
        throughput=$(awk "BEGIN {printf \"%.1f\", $total / $elapsed}")
    else
        success_rate=0
        throughput=0.0
    fi
    echo "[$(date '+%H:%M:%S')] Progress: ${episodes} episodes | ${tool_calls} tool calls | ${total} requests | ${success_rate}% success | ${throughput} req/s | Remaining: ${remaining}s"
done

wait

read -r total success fail tool_calls episodes <<< "$(get_stats)"
duration=$(($(date +%s) - start_time))
throughput=$(awk "BEGIN {printf \"%.2f\", $total / $duration}")

echo ""
echo "============================================================"
echo "   Traffic Generation Complete"
echo "============================================================"
echo "Duration:        ${duration}s (${DURATION_MINUTES} minutes)"
echo "Episodes:        $episodes"
echo "Tool Calls:      $tool_calls"
echo "Total Requests:  $total"
echo "Successful:      $success"
echo "Failed:          $fail"
echo "Success Rate:    $(awk "BEGIN {if ($total == 0) print \"0.0\"; else printf \"%.1f\", $success * 100 / $total}")%"
echo "Avg Throughput:  ${throughput} req/s"
echo ""
echo "Expected Observability Signals:"
echo "  - higher prefix-cache reuse from repeated system prompt + tool schema"
echo "  - traces grouped around multi-turn tool-calling episodes"
echo "  - repeated request prefixes across workers for cache-aware routing"
echo ""
echo "Suggested Checks:"
echo "1. Grafana / Prometheus: watch vLLM prefix cache metrics and request latency."
echo "2. Jaeger / Tempo: search for repeated request traces from the same service."
echo "3. Precise prefix guide: inspect EPP scoring logs for cache-aware decisions."
echo ""
echo "Example exact command for EPP logs:"
echo "kubectl logs -l inferencepool=gaie-kv-events-epp --all-containers=true -n <namespace> --tail 100 | grep \"Calculated score\" | grep \"precise-prefix-cache-scorer/precise-prefix-cache-scorer\""
echo ""
