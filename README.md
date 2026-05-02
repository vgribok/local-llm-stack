# ai-stack

Local agentic AI on Windows: Open WebUI + dual-Ollama backends pinned to separate GPUs + Tavily web search + adaptive thinking router.

## What it does

A self-hosted ChatGPT-style UI with web-search-grounded agents. The agentic loop (generate search query → fetch sources → embed → answer) runs concurrently on two GPUs instead of fighting for one. A lightweight proxy in front of the big-model backend automatically decides whether to enable extended thinking per request, keeping reasoning latency proportional to question complexity.

## Stack

| Service | Host port | GPU | Role |
|---|---|---|---|
| `open-webui` | 3001 | — | UI, agent orchestration |
| `think-router` | — (internal) | — | Adaptive thinking proxy for `ollama-big` |
| `ollama-big` | 3003 | RTX 3090 Ti (24 GiB) | Chat / reasoning models |
| `ollama-small` | 3004 | RTX 5060 Ti (16 GiB) | Task model + embeddings |

External: **Tavily** for web search (free tier — 1k queries/month).

## Prerequisites

- Windows + Docker Desktop with WSL2 GPU support enabled
- NVIDIA driver new enough for the GPUs to show in `nvidia-smi`
- Tavily API key (free at [tavily.com](https://tavily.com))

## First-time setup

1. Create `.env` in the repo root (gitignored):
   ```
   TAVILY_API_KEY=tvly-...

   # ollama-big context window (tokens). Reduce to reclaim VRAM; increase for longer chats.
   BIG_CONTEXT_LENGTH=48000
   ```

2. Update GPU UUIDs in [docker-compose.yml](docker-compose.yml). The current values are specific to this host — find yours:
   ```powershell
   nvidia-smi --query-gpu=uuid,name --format=csv
   ```
   Replace the `CUDA_VISIBLE_DEVICES=GPU-...` values for `ollama-big` and `ollama-small`.

3. Start the stack and pull starter models:
   ```powershell
   .\ollama.ps1 start
   .\ollama.ps1 pull qwen3.6:27b
   .\ollama.ps1 pull granite4.1:3b
   .\ollama.ps1 pull nomic-embed-text
   ```

`.\ollama.ps1 help` lists all wrapper commands. The wrapper auto-routes pulls to the correct GPU by registry size + name pattern; do **not** use `docker exec ... ollama pull` directly or models will land on the wrong backend.

## Architecture decisions worth knowing

**Why two Ollama instances** — A single instance with both GPUs visible will split a model that doesn't fit on one GPU across both, which slows inference dramatically (no NVLink between consumer GPUs). Two pinned instances keep each model whole on its assigned GPU.

**Why separate model stores** — Each Ollama bind-mounts its own directory under `~/`. Sharing the store made both backends advertise the same models, and Open WebUI would route by name without regard for VRAM capacity. Separate stores enforce routing structurally: a model only exists where it fits.

**GPU pinning uses `CUDA_VISIBLE_DEVICES`, not `NVIDIA_VISIBLE_DEVICES`** — Docker Desktop on Windows ignores the NVIDIA-runtime filter and exposes all GPUs to every container with `runtime: nvidia`. Filtering at the CUDA library level inside the container actually works. UUIDs (not indices) are used because PCIe order can change.

**`RAG_OLLAMA_BASE_URL` is set explicitly** — Open WebUI uses a separate Ollama URL for embeddings, which defaults to `host.docker.internal:11434` and silently fails in our setup. It must point at `ollama-small`.

**`TASK_MODEL` is a small dense non-thinking instruct model** — Reasoning/MoE models add latency and bleed conversation context into search queries. Currently `granite4.1:3b`.

**think-router auto-decides thinking per request** — Ollama 0.22.x does not implement `thinking_budget`; the parameter is silently ignored. The router works around this by classifying each user prompt with `granite4.1:3b` (on `ollama-small`) into three tiers, then setting the `think` flag on the upstream request accordingly:

| Classifier tier | Condition | think flag |
|---|---|---|
| HIGH | Complex reasoning, non-trivial code, planning, architecture | `true` + conciseness instruction injected |
| LOW | Simple-to-moderate code, short explanations | `false` |
| NO | Factual lookups, definitions, conversational | `false` |
| RAG | `<context>` tag detected in message | `true` + conciseness instruction injected |

The conciseness instruction ("Think briefly and directly — avoid restating the problem or over-elaborating obvious steps.") is prepended to the system message for think=true requests. It empirically halves thinking token count without truncating the answer. Manual overrides `/think` and `/no_think` as the first token of a message bypass the classifier entirely.

## File layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Stack definition; the canonical reference for env vars and tuning |
| `ollama.ps1` | Wrapper for Ollama operations across both backends |
| `think-router/app.py` | Thinking proxy — classifier logic and transparent Ollama passthrough |
| `think-router/Dockerfile` | Python 3.12-slim image for the proxy |
| `patches/tavily.py` | Bind-mounted over OWUI's Tavily integration — guards against empty and oversized queries |
| `.env` | Tavily key + tunable defaults (gitignored) |
| `.gitignore` | Excludes `.env`, `open-webui/` (DB/uploads/vectors), `.claude/` |
| `open-webui/` | OWUI runtime data — SQLite, uploads, vector store. Contains JWT secret |

## Operational notes

- **Cold model loads take 60–90s** on first use — WSL2 mmap of weights from the Windows filesystem is slow. `OLLAMA_KEEP_ALIVE=24h` holds models warm after that, so subsequent calls are sub-second to first token.
- **Recreating Open WebUI invalidates browser sessions** — sign in again after any compose change that touches the `open-webui` service.
- **The 5060 Ti is also the Windows display GPU** — expect ~1.5–2 GiB baseline VRAM consumed by desktop apps before any AI workload.
- **Per-chat web search toggle** — `ENABLE_WEB_SEARCH=True` in compose only makes the feature *available*; you still toggle it on per conversation via the `+` icon next to the message input.
- **think-router is rebuilt on every `.\ollama.ps1 start`** — `--build` is passed to `docker compose up`, so changes to `think-router/app.py` take effect automatically on the next start.
- **CUDA utilization ~50% during generation is normal** — autoregressive inference on large models is memory-bandwidth-bound, not compute-bound. Near-100% utilization only appears during the KV prefill phase.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 401 on every API call | Stale browser session after OWUI restart | Sign out + sign in |
| Long "Thinking" / partial CPU offload | Model loaded on the wrong GPU (doesn't fit) | `.\ollama.ps1 ps` to confirm; pull into correct backend |
| "No sources found" | Tavily key missing, or Web Search not toggled per-chat | Check `.env`; toggle in chat UI |
| Search query bleeds prior context | TASK_MODEL fell back to chat model (configured TASK_MODEL not pulled) | Pull the configured TASK_MODEL into `ollama-small` |
| GPU pinning not working | `NVIDIA_VISIBLE_DEVICES` doesn't filter on Docker Desktop | Use `CUDA_VISIBLE_DEVICES=GPU-<UUID>` instead |
| Thinking always on / always off | think-router classifier not working | Check `docker logs ai-stack-think-router-1`; confirm granite4.1:3b is pulled on ollama-small |
| think-router changes not taking effect | Image not rebuilt | `.\ollama.ps1 start` rebuilds automatically; or `docker compose up -d --build think-router` |
