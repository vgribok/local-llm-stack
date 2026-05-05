# ai-stack

Simplifies local agentic AI distribution: Open WebUI + adaptive thinking router + Tavily web search.<br/><br/>
Runs everything* on Docker allowing for easy configuration changes and deployment. (On MacOS Ollama runs on bare-metal, not on Docker.)

**Cross-platform:** Windows (NVIDIA, single- or dual-GPU) and macOS (Apple Silicon with bare-metal Ollama).

This solution is suitable for any front-end using local Ollama back-end, like Cline extension
of the VsCode, but is pre-integrated with bundled Open WebUI for search,
thinking control, and for user input augmentation out of the box.<br/><br/>
The system exposes a unified Ollama gateway at http://localhost:11434 (Windows) or http://localhost:11435 (macOS).
On dual-GPU Windows PCs, large models run on the bigger VRAM card while task/embedding models run on the smaller one.
On single-GPU or macOS, all models share one backend — the [router](./think-router/app.py) handles this transparently.

## What it does

A self-hosted ChatGPT-style UI with web-search-grounded agents. A unified Ollama gateway sits in front of the backend(s) and automatically decides whether to enable extended thinking per request, keeping reasoning latency proportional to question complexity. The same gateway endpoint serves both Open WebUI and VS Code AI coding agents (Cline, Continue.dev, etc.).

## Stack

### Windows (PC) — Dual GPU

| Service | Host port | GPU | Role |
|---|---|---|---|
| `open-webui` | 3001 | — | UI, agent orchestration |
| `think-router` | **11434** | — | Unified Ollama gateway + adaptive thinking proxy |
| `ollama-big` | 3003 | RTX 3090 Ti (24 GiB) | Chat / reasoning models |
| `ollama-small` | 3004 | RTX 5060 Ti (16 GiB) | Task model + embeddings |

### Windows (PC) — Single GPU

| Service | Host port | GPU | Role |
|---|---|---|---|
| `open-webui` | 3001 | — | UI, agent orchestration |
| `think-router` | **11434** | — | Unified Ollama gateway + adaptive thinking proxy |
| `ollama-big` | 3003 | Any NVIDIA GPU | All models (chat, task, embeddings) |

GPU count is detected automatically at startup via `nvidia-smi`. No manual configuration needed to select between the two PC layouts.

### macOS (Apple Silicon) — Bare-metal Ollama

| Service | Host port | Role |
|---|---|---|
| `open-webui` | 3001 | UI, agent orchestration |
| `think-router` | **11435** | Unified Ollama gateway + adaptive thinking proxy |
| Ollama (native) | 11434 | All models (chat, task, embeddings) |

External: **Tavily** for web search (free tier — 1k queries/month).

## Prerequisites

### Windows
- Docker Desktop with WSL2 GPU support enabled
- NVIDIA driver new enough for the GPUs to show in `nvidia-smi`
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

#### Windows (dual GPU)

Find your GPU UUIDs and add them to `.env`:
```powershell
nvidia-smi --query-gpu=uuid,name --format=csv
```
Set `BIG_GPU_ID` to the UUID of your larger-VRAM card and `SMALL_GPU_ID` to the smaller one.

#### Windows (single GPU)

No additional setup needed beyond the Tavily key — GPU count is detected automatically.

#### macOS

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

### 3. Start the stack

```bash
./ollama.ps1 start
```

This automatically detects your platform and GPU count, then uses the correct compose files:
- **Windows (dual GPU):** `docker-compose.yml` + `docker-compose.pc-dual.yml`
- **Windows (single GPU):** `docker-compose.yml` + `docker-compose.pc-single.yml`
- **macOS:** `docker-compose.yml` + `docker-compose.mac.yml`

### 4. Pull models (Windows only)

On Windows, use the wrapper to route models to the correct backend:
```powershell
./ollama.ps1 pull qwen3.6:27b       # dual GPU: -> big (by size);     single GPU: -> ollama-big
./ollama.ps1 pull granite4.1:3b     # dual GPU: -> small (by size);    single GPU: -> ollama-big
./ollama.ps1 pull nomic-embed-text  # dual GPU: -> small (by pattern); single GPU: -> ollama-big
```

On macOS, models are pulled directly via `ollama pull` (or the wrapper, which just calls the native CLI).

## Connecting a VS Code AI coding agent (Cline, Continue.dev, etc.)

| Setting | Windows | macOS |
|---|---|---|
| Provider | Ollama | Ollama |
| Base URL | `http://localhost:11434` | `http://localhost:11435` |
| Model | `qwen3.6:27b` (or any model visible in `/api/tags`) | `qwen3.6:35b-a3b-coding-mxfp8` (or your chat model) |

The agent gets model-aware routing, adaptive thinking classification, and the correct context window size automatically.

## Architecture decisions worth knowing

**Why two Ollama instances on dual-GPU Windows** — A single instance with both GPUs visible will split a model that doesn't fit on one GPU across both, which slows inference dramatically (no NVLink between consumer GPUs). Two pinned instances keep each model whole on its assigned GPU.

**Why separate model stores on dual-GPU Windows** — Each Ollama bind-mounts its own directory under `~/`. Sharing the store made both backends advertise the same models, and Open WebUI would route by name without regard for VRAM capacity. Separate stores enforce routing structurally.

**Single-GPU Windows uses one container** — All models share `ollama-big`. The think-router routes everything there; the big/small distinction is inert. Models live in a shared `~/.ollama` store.

**Why bare-metal Ollama on macOS** — Apple Silicon's unified memory architecture means there's no GPU/CPU memory split to manage. Running Ollama natively gives the best performance and simplest setup. Docker containers would add overhead without benefit.

**think-router is a unified gateway** — It merges `/api/tags` from all backends, routes requests to the correct backend, and applies adaptive thinking classification. On macOS and single-GPU Windows, both "big" and "small" URLs point to the same Ollama instance — the router handles this gracefully.

**Port 11435 on macOS** — The think-router exposes port 11435 to avoid conflicting with bare-metal Ollama on 11434. Clients (Cline, etc.) should connect to `localhost:11435` on Mac.

**GPU pinning on Windows uses `CUDA_VISIBLE_DEVICES`** — Docker Desktop on Windows ignores `NVIDIA_VISIBLE_DEVICES`. Filtering at the CUDA library level inside the container works. Dual-GPU uses UUIDs (not indices) because PCIe order can change; single-GPU defaults to device index 0.

**think-router auto-decides thinking per request** — Classifies each user prompt with `granite4.1:3b` into three tiers:

| Classifier tier | Condition | think flag |
|---|---|---|
| HIGH | Complex reasoning, non-trivial code, planning, architecture | `true` + conciseness instruction |
| LOW | Simple-to-moderate code, short explanations | `false` |
| NO | Factual lookups, definitions, conversational | `false` |
| RAG | `<context>` tag detected in message | `true` + conciseness instruction |

Manual overrides `/think` and `/no_think` as the first token of a message bypass the classifier.

## File layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Shared base: think-router + open-webui |
| `docker-compose.pc-dual.yml` | Windows overlay: dual-GPU, ollama-big + ollama-small with NVIDIA runtime |
| `docker-compose.pc-single.yml` | Windows overlay: single-GPU, one ollama-big with NVIDIA runtime |
| `docker-compose.mac.yml` | macOS overlay: points services to host.docker.internal Ollama |
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
| think-router can't reach Ollama (Mac) | Ollama not running | Run `ollama serve` or start Ollama app |
| Port conflict on Mac | Both Ollama and think-router want 11434 | think-router uses 11435 on Mac; connect clients to that port |
| GPU pinning not working (Windows) | `NVIDIA_VISIBLE_DEVICES` doesn't filter | Use `CUDA_VISIBLE_DEVICES=GPU-<UUID>` (dual GPU) or `CUDA_VISIBLE_DEVICES=0` (single GPU) |
| Wrong compose file selected (Windows) | `nvidia-smi` not in PATH | Ensure NVIDIA drivers are installed; run `nvidia-smi` manually to verify |
| Thinking always on / always off | Classifier not working | Check `docker logs ai-stack-think-router-1`; confirm granite4.1:3b is available |

## Wrapper commands

```bash
./ollama.ps1 help              # show detailed help
./ollama.ps1 start             # start stack (auto-detects platform and GPU count)
./ollama.ps1 list              # list models (all backends)
./ollama.ps1 ps                # show loaded models
./ollama.ps1 pull <model>      # pull model (Windows: auto-routes to correct backend)
./ollama.ps1 rm <model>        # delete model
./ollama.ps1 stop <model>      # unload from memory
./ollama.ps1 run <model>       # interactive chat
./ollama.ps1 show <model>      # show model info
./ollama.ps1 size <model>      # check registry size without pulling
```
