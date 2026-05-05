# Local AI Stack

Simplifies local agentic AI distribution: Open WebUI + adaptive thinking router + Tavily web search.<br/><br/>
Runs everything* on Docker allowing for easy configuration changes and deployment. (On macOS Ollama runs on bare-metal, not on Docker.)

**Cross-platform:** Windows (NVIDIA, single- or dual-GPU; or any GPU with bare-metal Ollama) and macOS (Apple Silicon).

**think-router** acts as a drop-in Ollama proxy — any client that speaks the Ollama API (Open WebUI, Cline, Continue.dev, curl) points at it instead of Ollama directly and gets adaptive thinking classification and multi-backend routing for free. The stack exposes a single Ollama-compatible endpoint at `http://localhost:11434` (Windows Docker) or `http://localhost:11435` (bare-metal / macOS).

## What it does

A self-hosted ChatGPT-style UI with web-search-grounded agents, backed by a unified Ollama gateway that automatically manages extended thinking, model routing, and backend selection across one or more GPUs.

## think-router

think-router is an Ollama-compatible HTTP proxy ([source](./think-router/app.py)). Any client that speaks the Ollama API — Open WebUI, Cline, Continue.dev, LM Studio, or plain `curl` — connects to think-router instead of Ollama directly and gets the following automatically, with no plugin or custom integration needed:

- **Adaptive thinking** — Each prompt is classified by `granite4.1:3b` to decide whether to enable extended thinking on the main model. Complex reasoning and architecture questions get full think time; factual lookups and simple code snippets skip it. Without this you must toggle thinking manually per request, or accept always-on (high latency for every message) or always-off (no deep reasoning).
- **Unified model registry** — On dual-GPU setups, think-router merges `/api/tags` from both Ollama instances. Clients see one Ollama with all models; think-router routes each request to the backend that holds the model.
- **Transparent passthrough** — Requests think-router doesn't need to modify are forwarded as-is. The endpoint is indistinguishable from a plain Ollama server to callers.

**Thinking classifier tiers:**

| Tier | Condition | Thinking |
|---|---|---|
| HIGH | Complex reasoning, non-trivial code, planning, architecture | on + conciseness hint |
| LOW | Simple-to-moderate code, short explanations | off |
| NO | Factual lookups, definitions, conversational | off |
| RAG | `<context>` tag detected in message | on + conciseness hint |

**Manual overrides** — prefix a message with `/think` or `/no_think` to bypass the classifier for that turn.

## Stack

### Windows (PC) — Dual NVIDIA GPU

| Service | Host port | GPU | Role |
|---|---|---|---|
| `open-webui` | 3001 | — | UI, agent orchestration |
| `think-router` | **11434** | — | Unified Ollama gateway + adaptive thinking proxy |
| `ollama-big` | 3003 | RTX 3090 Ti (24 GiB) | Chat / reasoning models |
| `ollama-small` | 3004 | RTX 5060 Ti (16 GiB) | Task model + embeddings |

### Windows (PC) — Single NVIDIA GPU

| Service | Host port | GPU | Role |
|---|---|---|---|
| `open-webui` | 3001 | — | UI, agent orchestration |
| `think-router` | **11434** | — | Unified Ollama gateway + adaptive thinking proxy |
| `ollama-big` | 3003 | Any NVIDIA GPU | All models (chat, task, embeddings) |

Used when `nvidia-smi` reports exactly one GPU and Ollama is not already running on the host.

### Bare-metal Ollama — macOS and non-NVIDIA Windows

| Service | Host port | Role |
|---|---|---|
| `open-webui` | 3001 | UI, agent orchestration |
| `think-router` | **11435** | Unified Ollama gateway + adaptive thinking proxy |
| Ollama (native) | 11434 | All models (chat, task, embeddings) |

> **Port 11435:** think-router uses 11435 in this configuration so it doesn't conflict with the pre-installed Ollama already running on 11434. Point VS Code agents and other clients to `localhost:11435`, not `localhost:11434`.

Used automatically on macOS (always) and on Windows when Ollama is already running on the host before `./ollama.ps1 start` — enabling AMD, Intel Arc, or any non-NVIDIA GPU without Docker GPU pass-through.

External: **Tavily** for web search (free tier — 1k queries/month).

## Prerequisites

### Windows
- Docker Desktop with WSL2 backend enabled
- NVIDIA drivers (for Docker GPU containers) **or** Ollama installed and running on the host
- Tavily API key (free at [tavily.com](https://tavily.com))

### macOS
- Docker Desktop for Mac
- Ollama installed and running (`brew install ollama` or [ollama.com](https://ollama.com))
- Tavily API key (free at [tavily.com](https://tavily.com))
- PowerShell for simplified stack management via [ollama.ps1](./ollama.ps1):
  ```bash
  brew install --cask powershell
  ```

## First-time setup

### 1. Create `.env` in the repo root (gitignored):

```bash
TAVILY_API_KEY=tvly-...

# Dual-GPU Windows only
BIG_CONTEXT_LENGTH=48000   # context window tokens; 48000 suits a 24 GiB card
BIG_GPU_ID=GPU-...         # run: nvidia-smi --query-gpu=uuid,name --format=csv
SMALL_GPU_ID=GPU-...

# Single-GPU Windows only (both optional; defaults shown)
# GPU_ID=0            # CUDA device index
# CONTEXT_LENGTH=32768
```

### 2. Platform-specific setup

#### Windows (dual NVIDIA GPU)

Find your GPU UUIDs and add them to `.env`:
```powershell
nvidia-smi --query-gpu=uuid,name --format=csv
```
Set `BIG_GPU_ID` to the UUID of your larger-VRAM card and `SMALL_GPU_ID` to the smaller one.

#### macOS / Windows with bare-metal Ollama

Ensure Ollama is running:
```bash
ollama serve  # or it may already be running as a service
```

Pull the required models:
```bash
ollama pull granite4.1:3b      # classifier / task model
ollama pull nomic-embed-text   # embeddings
ollama pull qwen3.6:35b-a3b-coding-mxfp8  # or your preferred chat model
```

#### Windows (single NVIDIA GPU, no bare-metal Ollama)

No additional setup needed — GPU count is detected automatically.

### 3. Start the stack

```bash
pwsh ./ollama.ps1 start
```

This automatically selects the correct compose files:
- **Windows (dual NVIDIA GPU):** `docker-compose.yml` + `docker-compose.pc-dual.yml`
- **Windows (single NVIDIA GPU):** `docker-compose.yml` + `docker-compose.pc-single.yml`
- **macOS / bare-metal Ollama:** `docker-compose.yml` + `docker-compose.bare-metal.yml`

### 4. Pull models (Windows Docker only)

On Windows with Docker-hosted Ollama, use the wrapper to route models to the correct backend:
```powershell
./ollama.ps1 pull qwen3.6:27b       # dual GPU: -> big (by size);     single GPU: -> ollama-big
./ollama.ps1 pull granite4.1:3b     # dual GPU: -> small (by size);    single GPU: -> ollama-big
./ollama.ps1 pull nomic-embed-text  # dual GPU: -> small (by pattern); single GPU: -> ollama-big
```

On macOS or bare-metal Windows, use `ollama pull` directly (or the wrapper, which calls the native CLI).

## Connecting a VS Code AI coding agent (Cline, Continue.dev, etc.)

| Setting | Windows (Docker Ollama) | macOS / bare-metal Ollama |
|---|---|---|
| Provider | Ollama | Ollama |
| Base URL | `http://localhost:11434` | `http://localhost:11435` |
| Model | `qwen3.6:27b` (or any model visible in `/api/tags`) | `qwen3.6:35b-a3b-coding-mxfp8` (or your chat model) |

The agent gets model-aware routing, adaptive thinking classification, and the correct context window size automatically.

## Architecture decisions worth knowing

**Why two Ollama instances on dual-GPU Windows** — A single instance with both GPUs visible will split a model that doesn't fit on one GPU across both, which slows inference dramatically (no NVLink between consumer GPUs). Two pinned instances keep each model whole on its assigned GPU.

**Why separate model stores on dual-GPU Windows** — Each Ollama bind-mounts its own directory under `~/`. Sharing the store made both backends advertise the same models, and Open WebUI would route by name without regard for VRAM capacity. Separate stores enforce routing structurally.

**Single-GPU Windows uses one container** — All models share `ollama-big`. The think-router routes everything there; the big/small distinction is inert. Models live in a shared `~/.ollama` store.

**Bare-metal overlay works for any GPU vendor** — Docker GPU pass-through on Windows requires NVIDIA drivers; AMD (ROCm is Linux-only) and Intel Arc GPUs cannot be passed into Windows Docker containers. The bare-metal overlay sidesteps this: Ollama runs natively with full GPU access, and Docker services connect via `host.docker.internal`. On Windows, this path is also selected automatically when Ollama is already running on port 11434 before `./ollama.ps1 start` is called.

**Why bare-metal Ollama on macOS** — Apple Silicon's unified memory architecture means there's no GPU/CPU memory split to manage. Running Ollama natively gives the best performance and simplest setup. Docker containers would add overhead without benefit.

**think-router is a unified gateway** — It merges `/api/tags` from all backends, routes each request to the backend that holds the model, and applies adaptive thinking classification. On macOS and bare-metal Windows, both "big" and "small" config URLs point to the same host Ollama instance — the router handles this gracefully. The classifier (`granite4.1:3b`) adds ~50–200ms per request; thinking is only enabled when the prompt warrants it.

**Port 11435 on bare-metal configurations** — think-router exposes port 11435 (not 11434) when using the bare-metal overlay, since host Ollama already occupies 11434. This applies to both macOS and bare-metal Windows.

**GPU pinning on Windows uses `CUDA_VISIBLE_DEVICES`** — Docker Desktop on Windows ignores `NVIDIA_VISIBLE_DEVICES`. Filtering at the CUDA library level inside the container works. Dual-GPU uses UUIDs (not indices) because PCIe order can change; single-GPU defaults to device index 0.

## File layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Shared base: think-router + open-webui |
| `docker-compose.pc-dual.yml` | Windows overlay: dual NVIDIA GPU, ollama-big + ollama-small |
| `docker-compose.pc-single.yml` | Windows overlay: single NVIDIA GPU, one ollama-big |
| `docker-compose.bare-metal.yml` | Bare-metal overlay: connects to host Ollama (any OS, any GPU) |
| `ollama.ps1` | Cross-platform wrapper for Ollama operations |
| `think-router/app.py` | Unified Ollama gateway — model registry, routing, thinking proxy |
| `think-router/test_app.py` | Unit tests for routing logic |
| `think-router/Dockerfile` | Python 3.12-slim image for the gateway |
| `patches/tavily.py` | Bind-mounted over OWUI's Tavily integration |
| `.env` | Tavily key + tunable defaults (gitignored) |
| `open-webui/` | OWUI runtime data — SQLite, uploads, vector store |

## Operational notes

- **Cold model loads** — First use loads weights into memory. `OLLAMA_KEEP_ALIVE=24h` keeps models warm between requests.
- **Recreating Open WebUI invalidates browser sessions** — Sign in again after compose changes.
- **Per-chat web search toggle** — `ENABLE_WEB_SEARCH=True` makes the feature available; toggle it per conversation via the `+` icon.
- **think-router is rebuilt on every `./ollama.ps1 start`** — Changes to `think-router/app.py` take effect automatically.
- **Models pulled after startup are discovered automatically** — think-router refreshes its registry on first request for an unknown model.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 401 on every API call | Stale browser session | Sign out + sign in |
| "No sources found" | Tavily key missing, or Web Search not toggled | Check `.env`; toggle in chat UI |
| think-router can't reach Ollama | Ollama not running on host | Run `ollama serve` or start Ollama app |
| Client can't connect (bare-metal) | Wrong port — Ollama holds 11434 | think-router is on **11435** in bare-metal mode; update client URL |
| GPU pinning not working (Windows) | `NVIDIA_VISIBLE_DEVICES` doesn't filter | Use `CUDA_VISIBLE_DEVICES=GPU-<UUID>` (dual GPU) or `CUDA_VISIBLE_DEVICES=0` (single GPU) |
| Wrong compose file selected (Windows) | `nvidia-smi` not in PATH | Ensure NVIDIA drivers are installed; run `nvidia-smi` manually to verify |
| Thinking always on / always off | Classifier not working | Check `docker logs ai-stack-think-router-1`; confirm granite4.1:3b is available |

## Wrapper commands

```bash
./ollama.ps1 help              # show detailed help
./ollama.ps1 start             # start stack (auto-detects platform, GPU count, bare-metal Ollama)
./ollama.ps1 list              # list models (all backends)
./ollama.ps1 ps                # show loaded models
./ollama.ps1 pull <model>      # pull model (Windows Docker: auto-routes to correct backend)
./ollama.ps1 rm <model>        # delete model
./ollama.ps1 stop <model>      # unload from memory
./ollama.ps1 run <model>       # interactive chat
./ollama.ps1 show <model>      # show model info
./ollama.ps1 size <model>      # check registry size without pulling
```
