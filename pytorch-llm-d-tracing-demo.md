# llm-d Distributed Tracing Demo

**"Beyond Generic Spans: Distributed Tracing for Actionable LLM Observability"**
~10 minutes | Demo-driven | Jaeger UI alongside

---

## Hook

> Generic tracing tools give you HTTP 200 and a duration. For LLM inference, that's almost useless.
>
> You need to know: did this request hit a warm KV cache? Which pod had the best cache locality?
> What did that routing decision cost in latency?
>
> That's what we built into llm-d. Let me show you.

---

## What We Instrumented

llm-d is a distributed inference framework. Requests flow through several components:

- **Gateway** receives the request
- **Inference Scheduler (EPP)** makes routing decisions — which pod has the best KV cache locality
- **KV Cache Manager** stores and scores block-level cache data per pod
- **vLLM** does the actual inference

We added manual OpenTelemetry instrumentation at each decision point. Not auto-instrumentation —
that only gives you HTTP spans. We instrument *why* the scheduler made each routing choice.

All spans propagate W3C trace context, so you get one continuous trace from gateway entry
to vLLM completion.

---

## Jaeger: Trace Structure Overview

> *[Pull up a trace in Jaeger]*

Here's a single request. The root span is `gateway.request`. Under it you'll see child spans
from the EPP scorer plugin and the KV cache service, then the vLLM `llm_request` span.

Full request lifecycle across three services — one trace, no guesswork.

---

## Scenario: Precise Prefix Cache-Aware Routing

This is the core story. llm-d's scheduler doesn't just round-robin requests to pods — it checks
which pod already has KV cache blocks for this request's prompt prefix, and routes accordingly.
The tracing shows you exactly how that decision is made.

### The Scorer Span

> *[Click into `llm_d.epp.scorer.prefix_cache` span]*

This span is created by the precise-prefix-cache scorer plugin. Every time the scheduler
picks a pod, it calls the KV cache service and gets block-level hit scores for each candidate.

**Key attributes:**

| Attribute | What it tells you |
|---|---|
| `llm_d.scorer.candidate_endpoints` | How many pods were considered |
| `gen_ai.request.model` | Which model this request targets |
| `llm_d.scorer.scores_computed` | How many pods returned scores |
| `llm_d.scorer.score.max` | Best cache hit score across pods |
| `llm_d.scorer.score.avg` | Average score — shows distribution |
| `llm_d.scorer.endpoints_scored` | Pods that had *any* cached blocks |

### The KV Cache Spans

> *[Expand the child spans under the scorer]*

Under the scorer, you'll see three KV cache spans forming a pipeline:

**`llm_d.kv_cache.get_scores`** — top-level call to the cache service

| Attribute | What it tells you |
|---|---|
| `gen_ai.request.model` | Model name |
| `llm_d.kv_cache.pod_count` | Pods being scored |

**`llm_d.kv_cache.storage.lookup`** — hits the actual storage backend

| Attribute | What it tells you |
|---|---|
| `llm_d.kv_cache.lookup.block_count` | Blocks being looked up |
| `llm_d.kv_cache.lookup.pod_filter_count` | Pods in the filter |
| `llm_d.kv_cache.lookup.cache_hit` | Whether any blocks were found |
| `llm_d.kv_cache.lookup.blocks_found` | How many blocks matched |

**`llm_d.kv_cache.scorer.compute`** — runs the scoring algorithm

| Attribute | What it tells you |
|---|---|
| `llm_d.kv_cache.scorer.algorithm` | Which scoring strategy |
| `llm_d.kv_cache.scorer.key_count` | Keys scored |
| `llm_d.kv_cache.score.max` | Best score |
| `llm_d.kv_cache.score.avg` | Average score |
| `llm_d.kv_cache.scorer.pods_scored` | Pods that got scores |

The **block hit ratio** — `blocks_found / block_count` — is the key metric.

### The Comparison

> *[Show two traces side by side]*

Here's why this matters. In a generic tracing setup, two requests look identical — both
got HTTP 200, similar total duration. In Jaeger, you can diff the scorer spans directly:

| | Request A | Request B |
|---|---|---|
| Block hit ratio | **0.87** | **0.12** |
| Routed to | Pod with warm cache | Cold pod |
| TTFT | **45ms** | **340ms** |
| `cache_hit` | `true` | `false` |
| `score.max` | 0.91 | 0.08 |

That's your validation signal — not a statistical aggregate, but a per-request audit trail
showing that KV-cache-aware scheduling is working and *how much* it helps.

---

## The Gap Generic Tooling Can't Close

Auto-instrumentation sees HTTP. It sees that a request went to `/v1/chat/completions`
and got a 200 back in 2.1 seconds.

It doesn't know:
- What the scheduler scored
- Which pod had the warmest cache
- Whether the TTFT was fast because of cache locality or just a short prompt
- The block hit ratio for this specific request

llm-d's performance story depends on these routing decisions being correct.
The tracing validates that they are — and when they're not, it tells you
specifically what went wrong and where.

---

## Scenario: P/D Disaggregation with Heterogeneous Parallelism

Now let's look at what happens when the cache is cold. The scheduler doesn't just
send the request to a single pod — it disaggregates prefill from decode, fanning
out across multiple prefill pods in parallel.

### The Decision Span

> *[Click into `llm_d.epp.pd.profile_handler.pick` span]*

This span captures the disaggregation decision. The scheduler sees a cold cache
(0.12 block hit ratio) and a long prompt (512 tokens) — disaggregation will help.

**Key attributes:**

| Attribute | What it tells you |
|---|---|
| `llm_d.profile_handler.decision` | `prefill_decode` — split the work |
| `llm_d.profile_handler.selected_profile` | `pd-nixlv2` — which connector |
| `gen_ai.request.id` | Request being disaggregated |
| `llm_d.profile_handler.decode_failed` | `false` — decode path is healthy |

The `llm_d.epp.prerequest.pd_disaggregation` span then injects prefill pod
addresses into request headers for the P/D proxy.

### The Prefill Stage

> *[Expand `llm_d.pd_proxy.prefill` spans]*

The P/D proxy coordinates 3 prefill pods running in parallel. Each processes
a chunk of the prompt using the nixlv2 connector.

**Key attributes:**

| Attribute | What it tells you |
|---|---|
| `llm_d.pd_proxy.kv_connector` | `nixlv2` — RDMA-based KV transfer |
| `llm_d.pd_proxy.disaggregation_used` | `true` |
| `llm_d.pd_proxy.prefill_target` | Pod address for this prefill |
| `llm_d.pd_proxy.prefill.duration_ms` | ~55ms (parallel across 3 pods) |
| `llm_d.pd_proxy.prefill.status_code` | 200 — prefill succeeded |

### The Decode Stage and KV Transfer

> *[Expand `llm_d.pd_proxy.decode` span]*

The wide decode pod starts from transferred KV state — not recomputing the prompt.
KV blocks arrive from all 3 prefill pods via RDMA.

**Key attributes:**

| Attribute | What it tells you |
|---|---|
| `llm_d.pd_proxy.decode.target` | Decode pod address |
| `llm_d.pd_proxy.true_ttft_ms` | **55ms** — real TTFT including prefill |
| `gen_ai.latency.time_to_first_token` | **0.015s** — decode-local TTFT |
| `llm_d.pd_proxy.coordinator_overhead_ms` | **0.5ms** — negligible |
| `llm_d.pd_proxy.total_duration_ms` | 2105ms — full request |

### The Comparison

> *[Show a monolithic trace alongside]*

| | P/D Disaggregated | Monolithic (cold) |
|---|---|---|
| TTFT | **55ms** | **340ms** |
| Prefill | 3 pods parallel, 55ms | 1 pod, 340ms |
| Decode TTFT | 15ms (from transferred KV) | 340ms (recomputed) |
| Coordinator overhead | 0.5ms | N/A |
| Improvement | **6.2x faster** | baseline |

The tracing shows exactly when disaggregation helps (cold cache, long prompts)
and when it doesn't (warm cache → the scheduler picks `decode_only` instead,
as we saw in the prefix cache scenario).

---

## Close

The instrumentation is upstream in llm-d. Enable it with standard OpenTelemetry
environment variables, deploy the OTel collector, and Jaeger is ready.

What you get:
- End-to-end traces across gateway, inference scheduler, KV cache, P/D proxy, and vLLM
- Cache scoring decisions with per-pod block hit ratios
- Per-request routing validation — did cache-aware scheduling actually help?
- P/D disaggregation decisions with the reasoning attached
- Heterogeneous parallelism visibility: multi-prefill fan-out + wide decode
- Coordinator overhead measurement proving the proxy isn't a bottleneck
- Request-level cost attribution: prompt tokens, completion tokens, cached tokens

The distributed tracing proposal is in the llm-d repo under `docs/proposals/distributed-tracing.md`.

---

## Why Tracing Matters (Reference Notes)

*These are background talking points, not part of the live demo:*

- **Cost attribution**: Per-request token counts tied to model/service/app for real chargeback
- **Multi-tenant validation**: Verify scheduling decisions per workload class, catch pathological eviction
- **Compliance**: Request-level audit trails (metadata only, no payloads) for regulated industries
- **SLO debugging**: Traces tell you *why* TTFT degraded — cache cold-start, slow pod, queue time
- **RAG pipelines**: End-to-end latency breakdown across retrieval + inference hops
