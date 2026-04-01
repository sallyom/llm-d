# llm-d Distributed Tracing Demo

Interactive web app for demoing llm-d's distributed tracing capabilities.

## Run

```bash
cd tracing-demo-app
python3 -m http.server 8765
```

Open http://localhost:8765

To stop:

```bash
kill $(lsof -ti :8765)
```

## Navigate

- **Arrow keys** or **Space** to move between stages
- **Click** the numbered circles in the progress bar
- **Jump** menu (top right) for direct access to any stage

## Stages

| # | Section | Stage |
|---|---------|-------|
| 1 | Prefix Cache | Gateway Request |
| 2 | Prefix Cache | EPP Prefix Cache Scorer |
| 3 | Prefix Cache | KV Cache Block Scoring |
| 4 | Prefix Cache | Cache-Aware Routing Payoff (2 vLLM pods) |
| 5 | P/D Disaggregation | P/D Profile Handler Decision |
| 6 | P/D Disaggregation | Parallel Prefill (3 pods) |
| 7 | P/D Disaggregation | Decode Payoff (KV transfer via RDMA) |
| 8 | vLLM | GenAI Semantic Conventions |
| 9 | Get Started | How to Enable Tracing in llm-d |

## Files

- `index.html` — page structure
- `styles.css` — dark theme styling
- `app.js` — stage data, architecture diagrams, animations

## No dependencies

Static HTML/CSS/JS — no build step, no npm, no framework.
