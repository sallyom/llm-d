// ── Stage Data ──
const stages = [
  // ── Prefix Cache Stages (1-4) ──
  {
    id: 1, section: "PREFIX CACHE",
    badge: "GATEWAY", badgeColor: "#06b6d4",
    title: "Gateway Request",
    subtitle: "W3C trace context propagation begins",
    progressLabel: "Gateway<br>Request",
    spanName: "gateway.request",
    layout: "prefix",
    metrics: [
      { label: "Span Duration", value: "2150", unit: "ms", delta: null },
      { label: "Span Kind", value: "SERVER", unit: "", delta: null },
      { label: "Service", value: "gateway-api", unit: "", delta: null },
      { label: "Status", value: "OK", unit: "", delta: null, deltaClass: "good" },
    ],
    attributes: [
      ["otel.service.name", "gateway-api-inference-extension", ""],
      ["http.method", "POST", ""],
      ["http.target", "/v1/chat/completions", ""],
      ["gen_ai.request.model", "meta-llama/Llama-3.1-8B", "highlight"],
      ["W3C traceparent", "injected \u2192 downstream", "good"],
    ],
    description: `<p>The <code>gateway.request</code> span wraps the entire request lifecycle. The gateway injects <span class="highlight">W3C trace context</span> (traceparent, tracestate) into headers before forwarding to the EPP plugins and downstream services.</p>
    <p>This is the root span \u2014 every child span across the scheduler, KV cache, and vLLM links back here.</p>`,
    activeComponents: ["app", "gateway"],
  },
  {
    id: 2, section: "PREFIX CACHE",
    badge: "EPP SCORER", badgeColor: "#a78bfa",
    title: "Precise Prefix Cache Scorer",
    subtitle: "Block-level cache scoring across candidate pods",
    progressLabel: "EPP Prefix<br>Cache Scorer",
    spanName: "llm_d.epp.scorer.prefix_cache",
    layout: "prefix",
    metrics: [
      { label: "Span Duration", value: "12", unit: "ms", delta: null },
      { label: "Candidates", value: "4", unit: "pods", delta: null },
      { label: "Best Score", value: "0.87", unit: "", delta: "\u2191 warm cache", deltaClass: "good" },
      { label: "Avg Score", value: "0.34", unit: "", delta: null },
    ],
    attributes: [
      ["llm_d.scorer.candidate_endpoints", "4", ""],
      ["gen_ai.request.model", "meta-llama/Llama-3.1-8B", ""],
      ["gen_ai.request.id", "req-a1b2c3d4", ""],
      ["llm_d.scorer.scores_computed", "4", ""],
      ["llm_d.scorer.score.max", "0.87", "good"],
      ["llm_d.scorer.score.avg", "0.34", ""],
      ["llm_d.scorer.endpoints_scored", "3", "highlight"],
    ],
    description: `<p>The <code>llm_d.epp.scorer.prefix_cache</code> span fires every time the scheduler needs to pick a pod. It calls the KV cache service and gets <span class="highlight">block-level hit scores</span> for each candidate pod.</p>
    <p>Here, 3 of 4 candidate pods had cached blocks. The best score is <span class="highlight">0.87</span> \u2014 meaning 87% of this request's prompt prefix blocks are already cached on that pod. The scheduler will route there.</p>`,
    activeComponents: ["app", "gateway", "epp"],
  },
  {
    id: 3, section: "PREFIX CACHE",
    badge: "KV CACHE", badgeColor: "#f97316",
    title: "KV Cache Block Scoring",
    subtitle: "Storage lookup \u2192 scoring algorithm \u2192 per-pod hit ratios",
    progressLabel: "KV Cache<br>Scoring",
    spanName: "llm_d.kv_cache.get_scores",
    layout: "prefix",
    metrics: [
      { label: "Lookup Duration", value: "6", unit: "ms", delta: null },
      { label: "Blocks Found", value: "14", unit: "of 16", delta: "\u2191 87.5% hit", deltaClass: "good" },
      { label: "Score Duration", value: "3", unit: "ms", delta: null },
      { label: "Pods Scored", value: "4", unit: "", delta: null },
    ],
    attributes: [
      ["gen_ai.request.model", "meta-llama/Llama-3.1-8B", ""],
      ["llm_d.kv_cache.pod_count", "4", ""],
      ["llm_d.kv_cache.lookup.block_count", "16", ""],
      ["llm_d.kv_cache.lookup.cache_hit", "true", "good"],
      ["llm_d.kv_cache.lookup.blocks_found", "14", "good"],
      ["llm_d.kv_cache.scorer.algorithm", "prefix-match", ""],
      ["llm_d.kv_cache.scorer.key_count", "16", ""],
      ["llm_d.kv_cache.score.max", "0.87", "good"],
      ["llm_d.kv_cache.score.avg", "0.34", ""],
      ["llm_d.kv_cache.scorer.pods_scored", "4", ""],
    ],
    description: `<p>Three KV cache spans form a pipeline under the scorer:</p>
    <ul>
      <li><code>llm_d.kv_cache.get_scores</code> \u2014 top-level call to the cache service</li>
      <li><code>llm_d.kv_cache.storage.lookup</code> \u2014 hits storage, finds <span class="highlight">14 of 16 blocks</span> cached</li>
      <li><code>llm_d.kv_cache.scorer.compute</code> \u2014 runs scoring algorithm, emits per-pod scores</li>
    </ul>
    <p>The <span class="highlight">block hit ratio</span> (blocks_found / block_count = 0.875) is the key signal. This tells the scheduler the target pod has a warm cache for this prompt prefix.</p>`,
    activeComponents: ["app", "gateway", "epp", "kvcache"],
  },
  {
    id: 4, section: "PREFIX CACHE",
    badge: "INFERENCE", badgeColor: "#10b981",
    title: "Cache-Aware Routing \u2014 The Payoff",
    subtitle: "Cache-warm vs cold: per-request proof that routing works",
    progressLabel: "Routing<br>Payoff",
    spanName: "Comparison: warm cache vs cold",
    layout: "prefix",
    metrics: [
      { label: "TTFT (warm)", value: "45", unit: "ms", delta: "\u2193 from 340ms", deltaClass: "good" },
      { label: "TTFT (cold)", value: "340", unit: "ms", delta: "\u2191 7.5x slower", deltaClass: "bad" },
      { label: "Block Hit (warm)", value: "0.87", unit: "", delta: "14/16 blocks", deltaClass: "good" },
      { label: "Block Hit (cold)", value: "0.12", unit: "", delta: "2/16 blocks", deltaClass: "bad" },
    ],
    attributes: [
      ["Request A \u2192 score.max", "0.87", "good"],
      ["Request A \u2192 cache_hit", "true", "good"],
      ["Request A \u2192 routed_to", "pod-gpu-0 (warm)", "good"],
      ["Request A \u2192 TTFT", "45ms", "good"],
      ["Request B \u2192 score.max", "0.08", "bad"],
      ["Request B \u2192 cache_hit", "false", "bad"],
      ["Request B \u2192 routed_to", "pod-gpu-3 (cold)", "bad"],
      ["Request B \u2192 TTFT", "340ms", "bad"],
    ],
    description: `<p>Two vLLM pods, same model. The scorer found Pod 1 has <span class="highlight">87% of blocks cached</span> (0.87 hit) \u2014 Pod 2 only has 12%. The scheduler routes to Pod 1. Result: TTFT <span class="highlight">45ms</span> vs 340ms on the cold pod.</p>
    <p>In the diagram, Pod 1 lights up green (selected), Pod 2 fades (not chosen). That's the routing decision visualized \u2014 and the trace proves it was correct, request by request.</p>`,
    activeComponents: ["app", "gateway", "epp", "kvcache", "vllm"],
  },


  // ── P/D Disaggregation Stages (5-7) ──
  {
    id: 5, section: "P/D DISAGGREGATION",
    badge: "P/D DECISION", badgeColor: "#a78bfa",
    title: "P/D Profile Handler Decision",
    subtitle: "Should we disaggregate prefill from decode?",
    progressLabel: "P/D<br>Decision",
    spanName: "llm_d.epp.pd.profile_handler.pick",
    layout: "pd",
    metrics: [
      { label: "Span Duration", value: "3", unit: "ms", delta: null },
      { label: "Decision", value: "prefill_decode", unit: "", delta: null },
      { label: "Input Tokens", value: "512", unit: "", delta: null },
      { label: "Cache Hit", value: "0.12", unit: "", delta: "\u2193 cold \u2192 disaggregate", deltaClass: "bad" },
    ],
    attributes: [
      ["llm_d.profile_handler.total_profiles", "3", ""],
      ["llm_d.profile_handler.executed_profiles", "1", ""],
      ["gen_ai.request.model", "meta-llama/Llama-3.1-8B", ""],
      ["gen_ai.request.id", "req-e5f6g7h8", ""],
      ["llm_d.profile_handler.decision", "prefill_decode", "highlight"],
      ["llm_d.profile_handler.selected_profile", "pd-nixlv2", ""],
      ["llm_d.profile_handler.decode_failed", "false", "good"],
      ["llm_d.epp.pd.prefill_pod_address", "10.0.2.15", ""],
      ["llm_d.epp.pd.prefill_pod_port", "8000", ""],
    ],
    description: `<p>The <code>llm_d.epp.pd.profile_handler.pick</code> span captures the <span class="highlight">disaggregation decision</span>. The scheduler evaluates whether to split prefill and decode across separate pods.</p>
    <p>With heterogeneous parallelism, <span class="highlight">multiple prefill pods</span> process prompt chunks in parallel, then transfer KV state to a <span class="highlight">wide decode pod</span> via RDMA. Cache hit ratio is 0.12 (cold), 512 input tokens \u2014 disaggregation across 3 prefill pods will significantly reduce TTFT.</p>
    <p>The <code>llm_d.epp.prerequest.pd_disaggregation</code> span injects the prefill pod addresses into request headers for the P/D proxy.</p>`,
    activeComponents: ["app", "gateway", "epp_pd"],
  },
  {
    id: 6, section: "P/D DISAGGREGATION",
    badge: "PREFILL", badgeColor: "#f97316",
    title: "P/D Proxy \u2014 Prefill Stage",
    subtitle: "Prefill pod processes prompt, KV cache transferred to decode pod",
    progressLabel: "Prefill<br>Stage",
    spanName: "llm_d.pd_proxy.prefill",
    layout: "pd",
    metrics: [
      { label: "Prefill Duration", value: "55", unit: "ms", delta: null },
      { label: "Connector", value: "nixlv2", unit: "", delta: null },
      { label: "Prefill Status", value: "200", unit: "", delta: null, deltaClass: "good" },
      { label: "KV Transfer", value: "active", unit: "", delta: "blocks shipping \u2192", deltaClass: "good" },
    ],
    attributes: [
      ["llm_d.pd_proxy.kv_connector", "nixlv2", ""],
      ["llm_d.pd_proxy.request_path", "/v1/chat/completions", ""],
      ["llm_d.pd_proxy.disaggregation_used", "true", "good"],
      ["llm_d.pd_proxy.prefill_target", "10.0.2.15:8000", "highlight"],
      ["llm_d.pd_proxy.prefill.status_code", "200", "good"],
      ["llm_d.pd_proxy.prefill.duration_ms", "55.2", ""],
      ["llm_d.pd_proxy.prefill_candidates", "2", ""],
    ],
    description: `<p>The <code>llm_d.pd_proxy.request</code> span wraps the entire proxy operation. Under it, <span class="highlight">3 parallel</span> <code>llm_d.pd_proxy.prefill</code> spans track each prefill pod.</p>
    <p>Each prefill pod processes a chunk of the prompt. The proxy coordinates all 3 in parallel using the nixlv2 connector. KV cache blocks from each prefill are transferred to the wide decode pod via <span class="highlight">RDMA</span>.</p>
    <p>Heterogeneous parallelism: small, fast prefill pods saturate compute on prompt processing while the large decode pod waits for KV state to arrive.</p>`,
    activeComponents: ["app", "gateway", "epp_pd", "proxy", "prefill_pod"],
  },
  {
    id: 7, section: "P/D DISAGGREGATION",
    badge: "DECODE + PAYOFF", badgeColor: "#10b981",
    title: "P/D Decode \u2014 The Payoff",
    subtitle: "Decode from transferred KV state vs monolithic: the comparison",
    progressLabel: "Decode<br>Payoff",
    spanName: "llm_d.pd_proxy.decode",
    layout: "pd",
    metrics: [
      { label: "True TTFT", value: "55", unit: "ms", delta: "prefill + transfer", deltaClass: "good" },
      { label: "Decode TTFT", value: "15", unit: "ms", delta: "\u2193 from transferred KV", deltaClass: "good" },
      { label: "Total Duration", value: "2105", unit: "ms", delta: null },
      { label: "Coordinator OH", value: "0.5", unit: "ms", delta: "negligible", deltaClass: "good" },
    ],
    attributes: [
      ["llm_d.pd_proxy.decode.target", "10.0.3.22:8000", ""],
      ["llm_d.pd_proxy.decode.duration_ms", "2050", ""],
      ["llm_d.pd_proxy.true_ttft_ms", "55", "highlight"],
      ["llm_d.pd_proxy.total_duration_ms", "2105", ""],
      ["llm_d.pd_proxy.coordinator_overhead_ms", "0.5", "good"],
      ["gen_ai.usage.prompt_tokens", "512", ""],
      ["gen_ai.usage.completion_tokens", "256", ""],
      ["gen_ai.latency.time_to_first_token", "0.015s", "good"],
      ["Monolithic TTFT (comparison)", "340ms", "bad"],
      ["P/D TTFT improvement", "6.2x faster", "good"],
    ],
    description: `<p>The wide decode pod starts from <span class="highlight">transferred KV state</span> from all 3 prefill pods \u2014 not recomputing any of the prompt. Decode TTFT is just <span class="highlight">15ms</span> because KV cache arrived via RDMA.</p>
    <p>Compare: a monolithic request with a cold cache takes 340ms TTFT. With heterogeneous P/D across 3 prefill pods, the true TTFT (including parallel prefill) is 55ms \u2014 a <span class="highlight">6.2x improvement</span>.</p>
    <p>The tracing shows each prefill pod's contribution and the coordinator overhead (0.5ms). You can see exactly when disaggregation helps (cold cache, long prompts) vs when decode_only is better (warm cache).</p>`,
    activeComponents: ["app", "gateway", "epp_pd", "proxy", "prefill_pod", "decode_pod"],
  },

  // ── vLLM GenAI Semantic Conventions (Stage 8) ──
  {
    id: 8, section: "vLLM",
    badge: "vLLM SPAN", badgeColor: "#10b981",
    title: "vLLM \u2014 GenAI Semantic Conventions",
    subtitle: "Upstream OpenTelemetry standard for LLM observability",
    progressLabel: "vLLM<br>GenAI",
    spanName: "vllm:llm_request",
    layout: "vllm",
    metrics: [
      { label: "Prompt Tokens", value: "512", unit: "", delta: null },
      { label: "Completion Tokens", value: "256", unit: "", delta: null },
      { label: "TTFT", value: "0.015", unit: "s", delta: "\u2193 from transferred KV", deltaClass: "good" },
      { label: "Model Prefill", value: "0.033", unit: "s", delta: null },
    ],
    attributes: [
      ["gen_ai.request.model", "meta-llama/Llama-3.1-8B", "highlight"],
      ["gen_ai.request.id", "req-e5f6g7h8", ""],
      ["gen_ai.usage.prompt_tokens", "512", ""],
      ["gen_ai.usage.completion_tokens", "256", ""],
      ["gen_ai.latency.time_to_first_token", "0.015s", "good"],
      ["gen_ai.latency.time_in_model_prefill", "0.033s", ""],
      ["gen_ai.latency.time_in_queue", "0.002s", "good"],
      ["gen_ai.latency.time_in_model_execute", "1.98s", ""],
      ["gen_ai.system", "vllm", ""],
      ["gen_ai.operation.name", "chat", ""],
    ],
    description: `<p>vLLM's <code>llm_request</code> span uses <span class="highlight">OpenTelemetry GenAI semantic conventions</span> \u2014 a vendor-neutral standard for LLM observability. No custom instrumentation needed: vLLM emits these spans natively when you pass <code>--otlp-traces-endpoint</code>.</p>
    <p>The conventions separate <span class="highlight">usage</span> (token counts for cost attribution) from <span class="highlight">latency</span> (TTFT, queue time, prefill time, execution time). This is what enables per-request chargeback and SLO debugging.</p>
    <p>Because vLLM extracts W3C trace context from incoming headers, these spans automatically link into the distributed trace \u2014 appearing as children of the gateway or P/D proxy spans.</p>`,
    activeComponents: [],
  },

  // ── How to Enable (Stage 9) ──
  {
    id: 9, section: "GET STARTED",
    badge: "ENABLE", badgeColor: "#10b981",
    title: "How Do I Enable Tracing in llm-d?",
    subtitle: "Well-lit paths: pre-configured guides with tracing built in",
    progressLabel: "Enable<br>Tracing",
    spanName: "Configuration",
    layout: "enable",
    metrics: [
      { label: "Helm Values", value: "2", unit: "files", delta: "ModelService + GAIE", deltaClass: "good" },
      { label: "Flags to Set", value: "3", unit: "", delta: "enabled, endpoint, sampler", deltaClass: "good" },
      { label: "Components Traced", value: "5", unit: "", delta: "all automatic", deltaClass: "good" },
      { label: "Setup Time", value: "~5", unit: "min", delta: "one script", deltaClass: "good" },
    ],
    attributes: [
      ["Guide: Precise Prefix Cache", "guides/precise-prefix-cache-aware/", "highlight"],
      ["Guide: P/D Disaggregation", "guides/pd-disaggregation/", "highlight"],
      ["Tracing docs", "docs/monitoring/tracing/README.md", ""],
      ["Collector install script", "docs/monitoring/scripts/install-otel-collector-jaeger.sh", ""],
      ["OTel Collector manifest", "docs/monitoring/tracing/otel-collector.yaml", ""],
      ["Jaeger manifest", "docs/monitoring/tracing/jaeger-all-in-one.yaml", ""],
      ["Tracing proposal", "docs/proposals/distributed-tracing.md", ""],
    ],
    description: `<p>llm-d provides <span class="highlight">well-lit paths</span> \u2014 pre-configured guides that have tracing already enabled. Pick one, deploy, and you get distributed tracing across all components automatically.</p>
    <p>No code changes. No custom instrumentation. Just set <code>tracing.enabled: true</code> in your Helm values and point to an OTel collector.</p>`,
    activeComponents: [],
  },
];

let currentStage = 1;

// ── Initialization ──
function init() {
  buildProgressBar();
  buildJumpMenu();
  renderStage(1);
}

function buildProgressBar() {
  const track = document.getElementById("progressTrack");
  let html = "";
  stages.forEach((s, i) => {
    // Section divider between prefix cache and P/D
    if (i > 0 && s.section !== stages[i - 1].section) {
      html += `<div class="section-divider"><span class="section-divider-label">${s.section}</span></div>`;
    } else if (i === 0) {
      // First section label
      html += `<div class="section-label-start">${s.section}</div>`;
    }
    html += `<div class="stage-node" data-stage="${s.id}">
      <div class="node-circle" id="node${s.id}" onclick="goToStage(${s.id})">${s.id}</div>
      <div class="node-label">${s.progressLabel}</div>
    </div>`;
    if (i < stages.length - 1) {
      html += `<div class="progress-line" id="line${s.id}-${stages[i + 1].id}"></div>`;
    }
  });
  track.innerHTML = html;
}

function buildJumpMenu() {
  const menu = document.getElementById("jumpMenu");
  let html = "";
  let lastSection = "";
  stages.forEach((s) => {
    if (s.section !== lastSection) {
      html += `<div class="jump-section-label">${s.section}</div>`;
      lastSection = s.section;
    }
    html += `<button class="jump-item" data-stage="${s.id}" onclick="goToStage(${s.id})">${s.id}. ${s.title}</button>`;
  });
  menu.innerHTML = html;
}

function toggleJumpMenu() {
  const menu = document.getElementById("jumpMenu");
  menu.classList.toggle("open");
  menu.querySelectorAll(".jump-item").forEach((item) => {
    item.classList.toggle("active", parseInt(item.dataset.stage) === currentStage);
  });
}

document.addEventListener("click", (e) => {
  if (!e.target.closest(".nav-controls")) {
    document.getElementById("jumpMenu").classList.remove("open");
  }
});

// ── Navigation ──
function goToStage(n) {
  if (n < 1 || n > stages.length) return;
  currentStage = n;
  renderStage(n);
  document.getElementById("jumpMenu").classList.remove("open");
}

function nextStage() {
  if (currentStage < stages.length) goToStage(currentStage + 1);
}

function prevStage() {
  if (currentStage > 1) goToStage(currentStage - 1);
}

document.addEventListener("keydown", (e) => {
  if (e.key === "ArrowRight" || e.key === " ") { e.preventDefault(); nextStage(); }
  if (e.key === "ArrowLeft") { e.preventDefault(); prevStage(); }
});

// ── Render Stage ──
function renderStage(n) {
  const stage = stages[n - 1];

  // Update progress nodes
  for (let i = 1; i <= stages.length; i++) {
    const node = document.getElementById(`node${i}`);
    node.className = "node-circle";
    if (i < n) node.classList.add("completed");
    if (i === n) node.classList.add("active");
  }

  for (let i = 0; i < stages.length - 1; i++) {
    const line = document.getElementById(`line${stages[i].id}-${stages[i + 1].id}`);
    if (line) {
      line.className = "progress-line";
      if (stages[i].id < n) line.classList.add("active");
    }
  }

  // Stage header
  const badge = document.getElementById("stageBadge");
  badge.textContent = stage.badge;
  badge.style.background = stage.badgeColor;
  document.getElementById("stageOf").textContent = `Stage ${n} of ${stages.length}`;
  document.getElementById("stageTitle").textContent = stage.title;
  document.getElementById("stageSubtitle").textContent = stage.subtitle;
  document.getElementById("stageCounter").textContent = `${n}-${stages.length}`;

  renderMetrics(stage.metrics);

  document.getElementById("spanName").textContent = stage.spanName;
  renderAttributes(stage.attributes);

  // Clear stream animation
  const diagram = document.getElementById("archDiagram");
  if (diagram._streamInterval) {
    clearInterval(diagram._streamInterval);
    diagram._streamInterval = null;
  }

  renderArchDiagram(stage);

  document.getElementById("waterfallSection").innerHTML = renderTraceWaterfall(stage);

  document.getElementById("descriptionBox").innerHTML = stage.description;

  document.getElementById("footerTitle").textContent = stage.section + " \u2014 " + stage.title;
  document.getElementById("prevBtn").style.visibility = n === 1 ? "hidden" : "visible";
  document.getElementById("nextBtn").style.visibility = n === stages.length ? "hidden" : "visible";

  document.querySelector(".main-content").classList.remove("fade-in");
  void document.querySelector(".main-content").offsetWidth;
  document.querySelector(".main-content").classList.add("fade-in");
}

function renderMetrics(metrics) {
  const grid = document.getElementById("metricsGrid");
  grid.innerHTML = metrics.map((m) => `
    <div class="metric-card">
      <div class="metric-label">${m.label}</div>
      <div class="metric-value">${m.value}<span class="metric-unit">${m.unit}</span></div>
      ${m.delta ? `<div class="metric-delta ${m.deltaClass || "neutral"}">${m.delta}</div>` : ""}
    </div>
  `).join("");
}

function renderAttributes(attrs) {
  document.getElementById("attrBody").innerHTML = attrs.map(([key, val, cls]) => `
    <tr><td>${key}</td><td class="${cls ? "attr-val-" + cls : ""}">${val}</td></tr>
  `).join("");
}

// ── Architecture Diagrams ──
function renderArchDiagram(stage) {
  if (stage.layout === "prefix") {
    renderPrefixDiagram(stage);
  } else if (stage.layout === "pd") {
    renderPDDiagram(stage);
  } else if (stage.layout === "vllm") {
    renderVllmDiagram(stage);
  } else if (stage.layout === "enable") {
    renderEnableDiagram(stage);
  }
}

// ── Prefix Cache Diagram (2 vLLM pods — warm vs cold) ──
function renderPrefixDiagram(stage) {
  const diagram = document.getElementById("archDiagram");
  const W = diagram.parentElement.clientWidth - 48;
  const H = 392;
  const boxW = Math.min(150, W * 0.30);
  const boxH = 75;
  const smallBoxH = 65;

  // Layout:
  //   Row 1: [Application]            [Gateway]
  //   Row 2: [KV Cache]               [EPP Scorer]
  //   Row 3: [vLLM Pod 1 (warm)]      [vLLM Pod 2 (cold)]
  const gapY = (H - boxH * 2 - smallBoxH) / 2;
  const row1 = 0;
  const row2 = boxH + gapY;
  const row3 = boxH * 2 + gapY * 2;

  const positions = {
    app:       { x: 0, y: row1 },
    gateway:   { x: W - boxW, y: row1 },
    kvcache:   { x: 0, y: row2 },
    epp:       { x: W - boxW, y: row2 },
    vllm_warm: { x: 0, y: row3 },
    vllm_cold: { x: W - boxW, y: row3 },
  };

  const components = [
    { id: "app",       name: "Application", tag: "CLIENT",   detail: "/v1/chat/completions" },
    { id: "gateway",   name: "Gateway",     tag: "SERVER",   detail: "gateway.request" },
    { id: "kvcache",   name: "KV Cache",    tag: "INTERNAL", detail: "get_scores" },
    { id: "epp",       name: "EPP Scorer",  tag: "INTERNAL", detail: "prefix_cache" },
    { id: "vllm_warm", name: "vLLM Pod 1",  tag: "0.87 HIT", detail: "llm_request" },
    { id: "vllm_cold", name: "vLLM Pod 2",  tag: "0.12 HIT", detail: "llm_request" },
  ];

  function pt(id, anchor) {
    const p = positions[id];
    const bh = (id.startsWith("vllm_")) ? smallBoxH : boxH;
    const cx = p.x + boxW / 2, cy = p.y + bh / 2;
    if (anchor === "right") return { x: p.x + boxW, y: cy };
    if (anchor === "left") return { x: p.x, y: cy };
    if (anchor === "bottom") return { x: cx, y: p.y + bh };
    if (anchor === "top") return { x: cx, y: p.y };
    return { x: cx, y: cy };
  }

  const vllmActive = stage.activeComponents.includes("vllm");

  const conns = [
    { from: pt("app", "right"), to: pt("gateway", "left"), label: "POST", active: true },
    { from: pt("gateway", "bottom"), to: pt("epp", "top"), label: "trace ctx", active: stage.activeComponents.includes("epp") },
    { from: pt("epp", "left"), to: pt("kvcache", "right"), label: "score", active: stage.activeComponents.includes("kvcache") },
    // EPP routes to warm pod (selected)
    { from: pt("epp", "bottom"), to: pt("vllm_warm", "top"), label: "routed \u2713", active: vllmActive,
      midX: positions.vllm_warm.x + boxW / 2 },
    // EPP considered cold pod (not selected) — dashed
    { from: pt("epp", "bottom"), to: pt("vllm_cold", "top"), label: "", active: false,
      midX: positions.vllm_cold.x + boxW / 2, dashed: true },
  ];

  // KV cache scored both pods
  if (stage.activeComponents.includes("kvcache")) {
    conns.push(
      { from: pt("kvcache", "bottom"), to: pt("vllm_warm", "top"), label: "", active: true, dashed: true },
      { from: pt("kvcache", "bottom"), to: pt("vllm_cold", "top"), label: "", active: false, dashed: true,
        midX: positions.vllm_cold.x + boxW / 2 },
    );
  }

  let html = renderSVGConnectionsPD(conns, W, H); // reuse PD renderer for midX support
  html += renderConnLabels(conns);

  // Render boxes with special styling for warm/cold pods
  components.forEach((comp) => {
    const pos = positions[comp.id];
    const isVllm = comp.id.startsWith("vllm_");
    const isWarm = comp.id === "vllm_warm";
    const isCold = comp.id === "vllm_cold";
    const bh = isVllm ? smallBoxH : boxH;

    let isActive = stage.activeComponents.includes(comp.id);
    // vllm_warm is active when vllm is active; vllm_cold shows but dimmer
    if (isWarm && vllmActive) isActive = true;
    if (isCold && vllmActive) isActive = false; // cold pod is not chosen

    let extraClass = "";
    if (isWarm && vllmActive) extraClass = "selected-pod";
    if (isCold && vllmActive) extraClass = "rejected-pod";

    let extra = "";
    if (comp.id === "app" && stage.id === 4) {
      extra = `<div class="stream-response"><span class="stream-text"></span><span class="stream-cursor">|</span></div>`;
    }

    // Tag color override for warm/cold
    let tagStyle = "";
    if (isWarm) tagStyle = 'style="background:rgba(16,185,129,0.2);color:#10b981;"';
    if (isCold) tagStyle = 'style="background:rgba(239,68,68,0.15);color:#ef4444;"';

    html += `
      <div class="comp-box ${isActive ? "active pulse-glow" : ""} ${isVllm ? "compact" : ""} ${extraClass}"
           style="left:${pos.x}px; top:${pos.y}px; width:${boxW}px;">
        <div class="comp-name">${comp.name}</div>
        <span class="comp-tag" ${tagStyle}>${comp.tag}</span>
        <div class="comp-detail">${comp.detail}</div>
        ${extra}
      </div>`;
  });

  // Request dot (stages 1-3)
  if (stage.id <= 3) {
    const dotPaths = [
      { sx: positions.app.x + boxW, sy: positions.app.y + boxH / 2, ex: positions.gateway.x, ey: positions.gateway.y + boxH / 2 },
      { sx: positions.gateway.x + boxW / 2, sy: positions.gateway.y + boxH, ex: positions.epp.x + boxW / 2, ey: positions.epp.y },
      { sx: positions.epp.x, sy: positions.epp.y + boxH / 2, ex: positions.kvcache.x + boxW, ey: positions.kvcache.y + boxH / 2 },
    ];
    html += renderDot(dotPaths[stage.id - 1], "request-dot", 1.5);
  }

  // Stage 4: response flows from warm pod back
  if (stage.id === 4) {
    // Route dot to warm pod
    html += renderDot({ sx: positions.epp.x, sy: positions.epp.y + boxH, ex: positions.vllm_warm.x + boxW / 2, ey: positions.vllm_warm.y }, "request-dot", 1.2, 0);
    // Response from warm pod
    for (let i = 0; i < 3; i++) {
      html += renderDot({ sx: positions.vllm_warm.x + boxW, sy: positions.vllm_warm.y + smallBoxH / 2, ex: positions.gateway.x, ey: positions.gateway.y + boxH / 2 }, "response-dot", 1.3, 0.3 + i * 0.4);
      html += renderDot({ sx: positions.gateway.x, sy: positions.gateway.y + boxH / 2, ex: positions.app.x + boxW, ey: positions.app.y + boxH / 2 }, "response-dot", 1.2, 0.8 + i * 0.4);
    }
  }

  diagram.innerHTML = html;
  startStreamAnimation(stage, diagram);
}

// ── P/D Disaggregation Diagram (Heterogeneous: multi-prefill + wide decode) ──
function renderPDDiagram(stage) {
  const diagram = document.getElementById("archDiagram");
  const W = diagram.parentElement.clientWidth - 48;
  const H = 392;
  const boxW = Math.min(140, W * 0.26);
  const boxH = 70;
  const smallBoxW = boxW;
  const smallBoxH = 60;

  // Layout:
  //   Row 1: [Application]  ──>  [Gateway]  ──>  [EPP Profile]
  //   Row 2:                     [P/D Proxy]
  //   Row 3: [Prefill 1] [Prefill 2] [Prefill 3]  ──KV──>  [Decode Pod (wide)]
  const row1 = 0;
  const row2 = boxH + 30;
  const row3 = H - smallBoxH - 40;

  // Prefill pods spread across left 55%, decode pod on right
  const prefillCount = 3;
  const prefillZoneW = W * 0.52;
  const prefillGap = (prefillZoneW - prefillCount * smallBoxW) / (prefillCount - 1);
  const decodeX = W - boxW - 10;

  const positions = {
    app:     { x: 0, y: row1 },
    gateway: { x: (W - boxW) / 2, y: row1 },
    epp_pd:  { x: W - boxW - 10, y: row1 },
    proxy:   { x: (W - boxW) / 2, y: row2 },
  };

  // Add prefill pod positions
  for (let i = 0; i < prefillCount; i++) {
    positions[`prefill_${i}`] = { x: i * (smallBoxW + prefillGap), y: row3 };
  }
  positions.decode_pod = { x: decodeX, y: row3 };

  const components = [
    { id: "app",     name: "Application", tag: "CLIENT",   detail: "/v1/chat/completions" },
    { id: "gateway", name: "Gateway",     tag: "SERVER",   detail: "gateway.request" },
    { id: "epp_pd",  name: "EPP Profile", tag: "INTERNAL", detail: "profile_handler.pick" },
    { id: "proxy",   name: "P/D Proxy",   tag: "SERVER",   detail: "pd_proxy.request" },
  ];
  for (let i = 0; i < prefillCount; i++) {
    components.push({ id: `prefill_${i}`, name: `Prefill ${i + 1}`, tag: "vLLM", detail: "llm_request" });
  }
  components.push({ id: "decode_pod", name: "Decode (wide)", tag: "vLLM", detail: "llm_request" });

  function pt(id, anchor) {
    const p = positions[id];
    const bw = (id.startsWith("prefill_")) ? smallBoxW : boxW;
    const bh = (id.startsWith("prefill_")) ? smallBoxH : boxH;
    const cx = p.x + bw / 2, cy = p.y + bh / 2;
    if (anchor === "right") return { x: p.x + bw, y: cy };
    if (anchor === "left") return { x: p.x, y: cy };
    if (anchor === "bottom") return { x: cx, y: p.y + bh };
    if (anchor === "top") return { x: cx, y: p.y };
    return { x: cx, y: cy };
  }

  const conns = [
    { from: pt("app", "right"), to: pt("gateway", "left"), label: "POST", active: true },
    { from: pt("gateway", "right"), to: pt("epp_pd", "left"), label: "decide", active: stage.activeComponents.includes("epp_pd") },
    { from: pt("gateway", "bottom"), to: pt("proxy", "top"), label: "trace ctx", active: stage.activeComponents.includes("proxy") },
  ];

  // Proxy -> each prefill pod
  const prefillActive = stage.activeComponents.includes("prefill_pod");
  for (let i = 0; i < prefillCount; i++) {
    conns.push({
      from: pt("proxy", "bottom"), to: pt(`prefill_${i}`, "top"),
      label: i === 1 ? "prefill" : "", active: prefillActive,
      midX: positions[`prefill_${i}`].x + smallBoxW / 2
    });
  }

  // Proxy -> decode pod
  const decodeActive = stage.activeComponents.includes("decode_pod");
  conns.push({
    from: pt("proxy", "bottom"), to: pt("decode_pod", "top"),
    label: "decode", active: decodeActive,
    midX: positions.decode_pod.x + boxW / 2
  });

  // KV transfer lines from each prefill to decode (stages 6-7)
  if (prefillActive && decodeActive) {
    for (let i = 0; i < prefillCount; i++) {
      conns.push({
        from: pt(`prefill_${i}`, "right"), to: pt("decode_pod", "left"),
        label: i === 1 ? "KV transfer (RDMA)" : "", active: true, dashed: true
      });
    }
  }

  // Use the PD SVG renderer (handles midX and dashed)
  let html = renderSVGConnectionsPD(conns, W, H);
  html += renderConnLabels(conns);

  // Render boxes — prefill pods use smaller size
  components.forEach((comp) => {
    const pos = positions[comp.id];
    const isActive = stage.activeComponents.includes(comp.id)
      || (comp.id.startsWith("prefill_") && prefillActive);
    const isPrefill = comp.id.startsWith("prefill_");
    const bw = isPrefill ? smallBoxW : boxW;
    let extra = "";
    if (comp.id === "app" && stage.id === 7) {
      extra = `<div class="stream-response"><span class="stream-text"></span><span class="stream-cursor">|</span></div>`;
    }
    html += `
      <div class="comp-box ${isActive ? "active pulse-glow" : ""} ${isPrefill ? "compact" : ""}"
           style="left:${pos.x}px; top:${pos.y}px; width:${bw}px;">
        <div class="comp-name">${comp.name}</div>
        <span class="comp-tag">${comp.tag}</span>
        <div class="comp-detail">${comp.detail}</div>
        ${extra}
      </div>`;
  });

  // Animated dots
  if (stage.id === 5) {
    html += renderDot({ sx: positions.app.x + boxW, sy: positions.app.y + boxH / 2, ex: positions.gateway.x, ey: positions.gateway.y + boxH / 2 }, "request-dot", 1.5, 0);
  }
  if (stage.id === 6) {
    // Dots flowing to each prefill pod (staggered)
    for (let i = 0; i < prefillCount; i++) {
      const pp = positions[`prefill_${i}`];
      html += renderDot({
        sx: positions.proxy.x + boxW / 2, sy: positions.proxy.y + boxH,
        ex: pp.x + smallBoxW / 2, ey: pp.y
      }, "request-dot", 1.2, i * 0.2);
    }
  }
  if (stage.id === 7) {
    // KV transfer dots from each prefill to decode
    for (let i = 0; i < prefillCount; i++) {
      const pp = positions[`prefill_${i}`];
      for (let j = 0; j < 2; j++) {
        html += renderDot({
          sx: pp.x + smallBoxW, sy: pp.y + smallBoxH / 2,
          ex: positions.decode_pod.x, ey: positions.decode_pod.y + boxH / 2
        }, "kv-transfer-dot", 1.0, i * 0.2 + j * 0.5);
      }
    }
    // Response dots back from decode
    for (let i = 0; i < 2; i++) {
      html += renderDot({ sx: positions.decode_pod.x, sy: positions.decode_pod.y, ex: positions.gateway.x + boxW / 2, ey: positions.gateway.y + boxH }, "response-dot", 1.4, 0.5 + i * 0.5);
      html += renderDot({ sx: positions.gateway.x, sy: positions.gateway.y + boxH / 2, ex: positions.app.x + boxW, ey: positions.app.y + boxH / 2 }, "response-dot", 1.2, 1.0 + i * 0.5);
    }
  }

  diagram.innerHTML = html;
  startStreamAnimation(stage, diagram);
}

// ── Shared rendering helpers ──

function renderSVGConnections(conns, W, H) {
  let svg = `<svg width="${W}" height="${H}" style="position:absolute;top:0;left:0;" xmlns="http://www.w3.org/2000/svg">`;
  svg += `<defs><filter id="glow"><feGaussianBlur stdDeviation="3" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>`;
  conns.forEach((c) => {
    const color = c.active ? "#06b6d4" : "#1e293b";
    const glow = c.active ? `filter="url(#glow)"` : "";
    if (c.midY !== undefined) {
      svg += `<path d="M${c.from.x},${c.from.y} L${c.from.x},${c.midY} L${c.to.x},${c.to.y}" fill="none" stroke="${color}" stroke-width="2" ${glow}/>`;
    } else {
      svg += `<line x1="${c.from.x}" y1="${c.from.y}" x2="${c.to.x}" y2="${c.to.y}" stroke="${color}" stroke-width="2" ${glow}/>`;
    }
  });
  svg += `</svg>`;
  return svg;
}

function renderSVGConnectionsPD(conns, W, H) {
  let svg = `<svg width="${W}" height="${H}" style="position:absolute;top:0;left:0;" xmlns="http://www.w3.org/2000/svg">`;
  svg += `<defs><filter id="glow"><feGaussianBlur stdDeviation="3" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>`;
  conns.forEach((c) => {
    const color = c.active ? (c.dashed ? "#f97316" : "#06b6d4") : "#1e293b";
    const glow = c.active ? `filter="url(#glow)"` : "";
    const dash = c.dashed ? `stroke-dasharray="6,4"` : "";
    if (c.midX !== undefined) {
      // L-shaped: go down then across
      svg += `<path d="M${c.from.x},${c.from.y} L${c.midX},${c.from.y} L${c.midX},${c.to.y} L${c.to.x},${c.to.y}" fill="none" stroke="${color}" stroke-width="2" ${dash} ${glow}/>`;
    } else {
      svg += `<line x1="${c.from.x}" y1="${c.from.y}" x2="${c.to.x}" y2="${c.to.y}" stroke="${color}" stroke-width="2" ${dash} ${glow}/>`;
    }
  });
  svg += `</svg>`;
  return svg;
}

function renderConnLabels(conns) {
  let html = "";
  conns.forEach((c) => {
    let lx, ly;
    if (c.midY !== undefined) {
      lx = c.from.x - 60;
      ly = (c.from.y + c.midY) / 2 - 8;
    } else if (c.midX !== undefined) {
      lx = c.midX + 6;
      ly = (c.from.y + c.to.y) / 2 - 8;
    } else if (Math.abs(c.from.x - c.to.x) < 10) {
      lx = c.from.x + 10;
      ly = (c.from.y + c.to.y) / 2 - 8;
    } else {
      lx = (c.from.x + c.to.x) / 2 - 15;
      ly = (c.from.y + c.to.y) / 2 - 18;
    }
    const color = c.dashed ? "#f97316" : "#64748b";
    html += `<div class="conn-label" style="left:${lx}px;top:${ly}px;color:${color};">${c.label}</div>`;
  });
  return html;
}

function renderCompBoxes(components, positions, boxW, stage) {
  let html = "";
  components.forEach((comp) => {
    const pos = positions[comp.id];
    const isActive = stage.activeComponents.includes(comp.id);
    let extra = "";
    // Streaming response on payoff stages
    if (comp.id === "app" && (stage.id === 4 || stage.id === 7)) {
      extra = `<div class="stream-response"><span class="stream-text"></span><span class="stream-cursor">|</span></div>`;
    }
    html += `
      <div class="comp-box ${isActive ? "active pulse-glow" : ""}"
           style="left:${pos.x}px; top:${pos.y}px; width:${boxW}px;">
        <div class="comp-name">${comp.name}</div>
        <span class="comp-tag">${comp.tag}</span>
        <div class="comp-detail">${comp.detail}</div>
        ${extra}
      </div>`;
  });
  return html;
}

function renderDot(path, cls, dur, delay) {
  return `<div class="${cls}" style="
    --start-x:${path.sx}px; --start-y:${path.sy}px;
    --end-x:${path.ex}px; --end-y:${path.ey}px;
    animation: dotMove ${dur}s ease-in-out infinite;
    animation-delay: ${delay || 0}s;
  "></div>`;
}

// ── vLLM GenAI Diagram ──
function renderVllmDiagram(stage) {
  const diagram = document.getElementById("archDiagram");
  diagram.innerHTML = `
    <div class="vllm-panel">
      <div class="vllm-span-header">
        <span class="vllm-span-icon">\u25C9</span>
        <span class="vllm-span-title">llm_request</span>
        <span class="vllm-span-service">vllm-decode-pod</span>
        <span class="vllm-span-duration">2045ms</span>
      </div>

      <div class="vllm-attr-grid">
        <div class="vllm-attr-group">
          <div class="vllm-group-label">gen_ai.request.*</div>
          <div class="vllm-attr"><span class="vllm-attr-key">.model</span> <span class="vllm-attr-val highlight">meta-llama/Llama-3.1-8B</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.id</span> <span class="vllm-attr-val">req-e5f6g7h8</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">gen_ai.system</span> <span class="vllm-attr-val">vllm</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">gen_ai.operation.name</span> <span class="vllm-attr-val">chat</span></div>
        </div>

        <div class="vllm-attr-group">
          <div class="vllm-group-label">gen_ai.usage.* <span class="vllm-group-hint">(cost attribution)</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.prompt_tokens</span> <span class="vllm-attr-val num">512</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.completion_tokens</span> <span class="vllm-attr-val num">256</span></div>
        </div>

        <div class="vllm-attr-group">
          <div class="vllm-group-label">gen_ai.latency.* <span class="vllm-group-hint">(SLO debugging)</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.time_to_first_token</span> <span class="vllm-attr-val good">0.015s</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.time_in_queue</span> <span class="vllm-attr-val good">0.002s</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.time_in_model_prefill</span> <span class="vllm-attr-val">0.033s</span></div>
          <div class="vllm-attr"><span class="vllm-attr-key">.time_in_model_execute</span> <span class="vllm-attr-val">1.98s</span></div>
        </div>
      </div>

      <div class="vllm-note">
        <span class="vllm-note-icon">\u2192</span>
        Upstream vLLM feature \u2014 no code changes. Enable with <code>--otlp-traces-endpoint</code>
      </div>
    </div>
  `;
}

// ── Enable Tracing Diagram ──
function renderEnableDiagram(stage) {
  const diagram = document.getElementById("archDiagram");
  diagram.innerHTML = `
    <div class="enable-panel">
      <div class="enable-section">
        <div class="enable-heading">1. Deploy OTel Collector + Jaeger</div>
        <pre class="enable-code">docs/monitoring/scripts/install-otel-collector-jaeger.sh -n &lt;namespace&gt;</pre>
      </div>

      <div class="enable-section">
        <div class="enable-heading">2. ModelService values (vLLM + P/D Proxy)</div>
        <pre class="enable-code"><span class="yaml-key">tracing:</span>
  <span class="yaml-key">enabled:</span> <span class="yaml-val">true</span>
  <span class="yaml-key">otlpEndpoint:</span> <span class="yaml-str">"http://otel-collector:4317"</span>
  <span class="yaml-key">sampling:</span>
    <span class="yaml-key">sampler:</span> <span class="yaml-str">"parentbased_traceidratio"</span>
    <span class="yaml-key">samplerArg:</span> <span class="yaml-str">"0.1"</span></pre>
      </div>

      <div class="enable-section">
        <div class="enable-heading">3. GAIE/EPP values (Inference Scheduler)</div>
        <pre class="enable-code"><span class="yaml-key">inferenceExtension:</span>
  <span class="yaml-key">tracing:</span>
    <span class="yaml-key">enabled:</span> <span class="yaml-val">true</span>
    <span class="yaml-key">otelExporterEndpoint:</span> <span class="yaml-str">"http://otel-collector:4317"</span></pre>
      </div>

      <div class="enable-section">
        <div class="enable-heading">4. Open Jaeger</div>
        <pre class="enable-code">kubectl port-forward svc/jaeger-collector 16686:16686
# open http://localhost:16686</pre>
      </div>

      <div class="enable-well-lit">
        <div class="well-lit-label">Well-Lit Paths (tracing pre-configured)</div>
        <div class="well-lit-items">
          <div class="well-lit-item">
            <span class="well-lit-icon">\u2713</span>
            <span>guides/precise-prefix-cache-aware/</span>
          </div>
          <div class="well-lit-item">
            <span class="well-lit-icon">\u2713</span>
            <span>guides/pd-disaggregation/</span>
          </div>
        </div>
      </div>
    </div>
  `;
}

function startStreamAnimation(stage, diagram) {
  if (stage.id === 4 || stage.id === 7) {
    const streamEl = diagram.querySelector(".stream-text");
    if (streamEl) {
      const tokens = stage.id === 4
        ? ["KV", " cache", " hit", " 0.87", " \u2014", " routed", " to", " warm", " pod,", " TTFT", " 45ms"]
        : ["P/D", " disagg", " \u2014", " prefill", " 55ms", " +", " decode", " TTFT", " 15ms", " =", " 6.2x", " faster"];
      let idx = 0;
      diagram._streamInterval = setInterval(() => {
        if (idx < tokens.length) { streamEl.textContent += tokens[idx]; idx++; }
        else { streamEl.textContent = ""; idx = 0; }
      }, 300);
    }
  }
}

// ── Trace Waterfall ──
function renderTraceWaterfall(stage) {
  if (stage.layout === "vllm") {
    return `<div class="trace-waterfall">
      <div style="font-size:12px;color:#64748b;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:10px;">OpenTelemetry GenAI Semantic Conventions</div>
      <div class="genai-conventions">
        <div class="genai-row">
          <span class="genai-ns">gen_ai.request.*</span>
          <span class="genai-desc">Model identity and request metadata \u2014 which model, which request</span>
        </div>
        <div class="genai-row">
          <span class="genai-ns">gen_ai.usage.*</span>
          <span class="genai-desc">Token counts for cost attribution and chargeback \u2014 prompt vs completion tokens</span>
        </div>
        <div class="genai-row">
          <span class="genai-ns">gen_ai.latency.*</span>
          <span class="genai-desc">Latency breakdown for SLO debugging \u2014 TTFT, queue time, prefill, execution</span>
        </div>
        <div class="genai-row">
          <span class="genai-ns">gen_ai.system</span>
          <span class="genai-desc">Inference engine identifier \u2014 "vllm" \u2014 for multi-engine environments</span>
        </div>
      </div>
    </div>`;
  }

  if (stage.layout === "enable") {
    return `<div class="trace-waterfall">
      <div style="font-size:12px;color:#64748b;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:10px;">What You Get</div>
      <div class="enable-what-you-get">
        <div class="wyg-item"><span class="wyg-component">Gateway</span> <code>gateway.request</code></div>
        <div class="wyg-item"><span class="wyg-component">EPP Scorer</span> <code>llm_d.epp.scorer.prefix_cache</code></div>
        <div class="wyg-item"><span class="wyg-component">KV Cache</span> <code>llm_d.kv_cache.get_scores</code> + storage + scorer</div>
        <div class="wyg-item"><span class="wyg-component">P/D Proxy</span> <code>llm_d.pd_proxy.request</code> + prefill + decode</div>
        <div class="wyg-item"><span class="wyg-component">vLLM</span> <code>llm_request</code> with GenAI semantic conventions</div>
      </div>
    </div>`;
  }

  const prefixBars = [
    { label: "gateway.request", cls: "gateway", left: 0, width: 100, time: "2150ms", stage: 1 },
    { label: "epp.scorer.prefix_cache", cls: "epp", left: 2, width: 5, time: "12ms", stage: 2 },
    { label: "kv_cache.get_scores", cls: "kvcache", left: 2.5, width: 4, time: "10ms", stage: 3 },
    { label: "  .storage.lookup", cls: "kvcache-sub", left: 3, width: 2.5, time: "6ms", stage: 3 },
    { label: "  .scorer.compute", cls: "kvcache-sub", left: 5.5, width: 1.2, time: "3ms", stage: 3 },
    { label: "vllm:llm_request", cls: "vllm", left: 8, width: 90, time: "2050ms", stage: 4 },
  ];

  const pdBars = [
    { label: "gateway.request", cls: "gateway", left: 0, width: 100, time: "2150ms", stage: 5 },
    { label: "epp.pd.profile_handler.pick", cls: "epp", left: 1, width: 2, time: "3ms", stage: 5 },
    { label: "epp.prerequest.pd_disagg", cls: "epp", left: 3, width: 1.5, time: "2ms", stage: 5 },
    { label: "pd_proxy.request", cls: "pd-proxy", left: 4, width: 94, time: "2105ms", stage: 6 },
    { label: "  pd_proxy.prefill", cls: "prefill", left: 5, width: 4, time: "55ms", stage: 6 },
    { label: "    vllm:llm_request (prefill)", cls: "vllm", left: 5.5, width: 3.5, time: "50ms", stage: 6 },
    { label: "  pd_proxy.decode", cls: "decode", left: 10, width: 88, time: "2050ms", stage: 7 },
    { label: "    vllm:llm_request (decode)", cls: "vllm", left: 10.5, width: 87, time: "2045ms", stage: 7 },
  ];

  const bars = stage.layout === "prefix" ? prefixBars : pdBars;
  const baseStage = stage.layout === "prefix" ? 0 : 4;

  let html = '<div class="trace-waterfall">';
  html += `<div style="font-size:12px;color:#64748b;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:8px;padding-left:4px;">
    ${stage.layout === "prefix" ? "Trace Waterfall \u2014 Prefix Cache Flow" : "Trace Waterfall \u2014 P/D Disaggregation Flow"}
  </div>`;

  bars.forEach((bar) => {
    const visible = bar.stage <= stage.id;
    const opacity = visible ? 1 : 0.15;
    html += `
      <div class="trace-bar-row" style="opacity:${opacity};transition:opacity 0.5s;">
        <div class="trace-bar-label">${bar.label}</div>
        <div class="trace-bar-container">
          <div class="trace-bar ${bar.cls}" style="left:${bar.left}%;width:${visible ? bar.width : 0}%;"></div>
          ${visible ? `<span class="trace-bar-time" style="left:${bar.left + bar.width + 1}%;">${bar.time}</span>` : ""}
        </div>
      </div>`;
  });

  html += "</div>";
  return html;
}

// ── Init ──
init();
