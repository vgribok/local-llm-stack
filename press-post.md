Adaptive thinking router for Ollama that auto-classifies prompts and toggles extended thinking on/off — no more manual /think switching

**TL;DR:** Open-sourced a local AI stack with a proxy that sits in front of Ollama and automatically decides whether your prompt needs extended thinking. Complex reasoning → thinking on. Simple questions → thinking off. Adds ~50-200ms latency but saves you from either always-on thinking (slow for everything) or always-off (no deep reasoning when you need it).

---

## The Problem

If you're running thinking-capable models (Qwen3, DeepSeek-R1, etc.), you've probably noticed the dilemma:

- **Always-on thinking:** Every response takes 10-30+ seconds even for "what's the syntax for X?"
- **Always-off thinking:** Fast responses but you lose the deep reasoning when you actually need it
- **Manual toggle:** Works but annoying — you have to remember to prefix `/think` or switch settings per-chat

## The Solution: think-router

A FastAPI proxy that intercepts Ollama API calls and uses a tiny classifier model (`granite4.1:3b`, ~2GB VRAM) to categorize each prompt before forwarding:

| Tier | When | Thinking |
|---|---|---|
| HIGH | Complex reasoning, non-trivial code, architecture, planning | ✅ ON |
| LOW | Simple-to-moderate code, short explanations | ❌ OFF |
| NO | Factual lookups, definitions, conversational | ❌ OFF |
| RAG | `<context>` tag detected (document synthesis) | ✅ ON |

The classifier prompt is dead simple — it just asks the model to reply with NO, LOW, or HIGH based on how much "deliberation" the request needs.

**Manual overrides still work:** Prefix any message with `/think` or `/no_think` to bypass classification.

## What's in the stack

- **think-router** — The adaptive thinking proxy (drop-in Ollama replacement)
- **Open WebUI** — ChatGPT-style interface with agent support
- **Tavily integration** — Web search grounding (free tier: 1k queries/month)
- **Multi-GPU routing** — Dual-GPU Windows setups get automatic model→GPU routing

## Why Docker Compose?

Everything is text-based config. Want to tweak context window size? Change an env var. Swap the classifier model? One line. Adjust GPU pinning? Edit the compose file.

This matters because **coding agents (Cline, Cursor, etc.) can modify these configs for you.** Ask your agent to "increase context length to 64k" or "switch the classifier to phi4-mini" and it can edit the compose files directly or bubble up settings into the .env. No clicking through UIs, no hunting for config files — just describe what you want.

The whole stack rebuilds on `./ollama.ps1 start`, so experimentation is fast: change config → restart → test.

## Platform support

| Platform | GPU | How it works |
|---|---|---|
| Windows | Dual NVIDIA | Two Ollama containers, one per GPU. Router merges model lists and routes by model name. |
| Windows | Single NVIDIA | One Ollama container, router still handles thinking classification |
| Windows | AMD/Intel Arc | Bare-metal Ollama (ROCm/oneAPI), Docker services connect via `host.docker.internal` |
| macOS | Apple Silicon | Bare-metal Ollama (unified memory), Docker for UI/router only |

## Why two Ollama instances on dual-GPU?

Consumer GPUs don't have NVLink. If you let Ollama see both GPUs, it'll split large models across them — and inference tanks because of PCIe bandwidth. Pinning each instance to one GPU keeps models whole.

## The brevity trick

When thinking is enabled, the router injects this into the system prompt:

> "Be concise and efficient in your reasoning. Think briefly and directly — avoid restating the problem or over-elaborating obvious steps."

Empirically cuts thinking token count in half without truncating the actual answer.

## Quick start

```bash
# Clone
git clone https://github.com/vgribok/local-llm-stack
cd local-llm-stack

# Create .env with your Tavily key (optional but enables web search)
echo "TAVILY_API_KEY=tvly-..." > .env

# Start (auto-detects platform and GPU config)
pwsh ./ollama.ps1 start
```

On macOS/bare-metal, make sure Ollama is running first and pull your models:
```bash
ollama pull granite4.1:3b      # classifier
ollama pull qwen3.6:27b        # or whatever thinking model you prefer
```

## Connecting VS Code agents (Cline, Continue.dev)

Just point them at the router instead of Ollama directly:

| Config | Windows Docker | macOS / bare-metal |
|---|---|---|
| Base URL | `http://localhost:11434` | `http://localhost:11435` |
> Note 11435 port instead of 11434 with bare-metal Ollama back-end - to avoid the conflict with the bare-metal Ollama endpoint. 

The agent gets adaptive thinking for free — no plugin needed.

## Repo

**GitHub:** https://github.com/vgribok/local-llm-stack

The router is ~400 lines of Python: [think-router/app.py](https://github.com/vgribok/local-llm-stack/blob/main/think-router/app.py)

---

Happy to answer questions about the classification approach, multi-GPU routing, or anything else. The classifier accuracy isn't perfect but it's been good enough that I stopped manually toggling thinking.