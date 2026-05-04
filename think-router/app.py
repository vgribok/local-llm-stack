"""
Unified Ollama gateway and transparent thinking proxy.

Sits in front of both ollama-big and ollama-small and provides a single
Ollama-compatible endpoint for all clients (Open WebUI, Cline, etc.):

  /api/tags   — merges model lists from both backends
  /api/show   — routes to whichever backend owns the model
  /api/chat   — routes to the owning backend; applies adaptive thinking
                classification only for big-GPU models

Thinking classification: for /api/chat to a thinking-capable model on
ollama-big, calls a tiny classifier on ollama-small to decide whether the
user's last message needs deliberation. Sets body['think'] accordingly.
Manual overrides via '/think' or '/no_think' as the first token of the user
message.

All other endpoints fall through to ollama-big (management operations).
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

UPSTREAM_URL       = os.environ.get("UPSTREAM_URL",       "http://ollama-big:11434")
SMALL_UPSTREAM_URL = os.environ.get("SMALL_UPSTREAM_URL", "http://ollama-small:11434")
CLASSIFIER_URL     = os.environ.get("CLASSIFIER_URL",     "http://ollama-small:11434")
CLASSIFIER_MODEL   = os.environ.get("CLASSIFIER_MODEL",   "granite4.1:3b")
CLASSIFIER_TIMEOUT_S = float(os.environ.get("CLASSIFIER_TIMEOUT_S", "8"))

# Injected into the system message whenever thinking is enabled.
# Empirically halves thinking token count without truncating the answer.
CONCISE_THINKING_INSTRUCTION = (
    "Be concise and efficient in your reasoning. "
    "Think briefly and directly — avoid restating the problem or over-elaborating obvious steps."
)

ROUTER_DEBUG_DECISIONS = os.environ.get("ROUTER_DEBUG_DECISIONS", "0").lower() in (
    "1", "true", "yes", "on"
)

# Auto-discovery overrides. Both empty by default.
# EXCLUDE_MODELS: never classify these even if they report 'thinking' capability.
# INCLUDE_MODELS: always classify these even if they don't report 'thinking'.
EXCLUDE_MODELS = set(filter(None, (os.environ.get("EXCLUDE_MODELS") or "").split(",")))
INCLUDE_MODELS = set(filter(None, (os.environ.get("INCLUDE_MODELS") or "").split(",")))

# model_name -> bool (is thinking-capable). Populated lazily from /api/show.
_thinking_cache: dict[str, bool] = {}

# model_name -> backend URL. Populated from /api/tags on both backends at startup
# and refreshed on cache miss (handles models pulled after startup).
_model_backend: dict[str, str] = {}

logging.basicConfig(level=logging.INFO, format="%(asctime)s [think-router] %(message)s")
log = logging.getLogger("think-router")

CLASSIFIER_PROMPT = """Reply with exactly one word: NO, LOW, or HIGH.
How much deliberation does the user's request below require?

NO   — factual questions, definitions, simple lookups, conversational replies, one-line answers
LOW  — moderate reasoning: simple-to-medium code, straightforward explanations, short summaries of simple topics
HIGH — complex reasoning, non-trivial algorithms or code, planning, architecture, or synthesis of a complex system or document

{prompt}

Answer (NO, LOW, or HIGH):"""


async def _refresh_model_registry() -> None:
    """Query /api/tags on both backends and rebuild the model→backend map."""
    updated: dict[str, str] = {}
    for backend_url in (UPSTREAM_URL, SMALL_UPSTREAM_URL):
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                r = await client.get(f"{backend_url}/api/tags")
                r.raise_for_status()
                for m in r.json().get("models") or []:
                    name = m.get("name")
                    if name:
                        updated[name] = backend_url
        except Exception as e:
            log.warning("model registry refresh failed for %s: %s", backend_url, e)
    if updated:
        _model_backend.clear()
        _model_backend.update(updated)
        big = sum(1 for v in updated.values() if v == UPSTREAM_URL)
        small = sum(1 for v in updated.values() if v == SMALL_UPSTREAM_URL)
        log.info("model registry: %d total (%d big, %d small)", len(updated), big, small)


async def _backend_for_model(model: str) -> str:
    """Return the backend URL that owns this model. Refreshes once on cache miss."""
    if model in _model_backend:
        return _model_backend[model]
    await _refresh_model_registry()
    return _model_backend.get(model, UPSTREAM_URL)


@asynccontextmanager
async def lifespan(_: FastAPI):
    await _refresh_model_registry()
    yield


app = FastAPI(lifespan=lifespan)


def _last_user_message(messages: list[dict]) -> str:
    for m in reversed(messages or []):
        if m.get("role") == "user":
            content = m.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def _override_from_prefix(text: str) -> Optional[bool]:
    head = text.lstrip().lower()
    if head.startswith("/no_think") or head.startswith("/nothink"):
        return False
    if head.startswith("/think"):
        return True
    return None


def _apply_thinking_controls(body: dict) -> dict:
    """Inject conciseness instruction into system message when thinking is enabled."""
    messages = body.setdefault("messages", [])
    if messages and messages[0].get("role") == "system":
        messages[0]["content"] = CONCISE_THINKING_INSTRUCTION + "\n\n" + messages[0]["content"]
    else:
        messages.insert(0, {"role": "system", "content": CONCISE_THINKING_INSTRUCTION})
    return body


def _trace_id_from_request(request: Request) -> str:
    inbound = request.headers.get("x-request-id") or request.headers.get("x-correlation-id")
    return inbound.strip() if inbound and inbound.strip() else uuid.uuid4().hex[:12]


def _decision_log(
    trace_id: str,
    *,
    model: str,
    reason: str,
    body: dict,
    client_supplied_think: bool,
) -> None:
    if not ROUTER_DEBUG_DECISIONS:
        return
    log.info(
        "decision trace_id=%s model=%s reason=%s think=%s thinking_budget=%s client_supplied_think=%s stream=%s",
        trace_id,
        model or "<missing>",
        reason,
        body.get("think"),
        body.get("options", {}).get("num_predict"),
        client_supplied_think,
        _is_streaming(body),
    )


async def _classify(prompt: str) -> Optional[str]:
    """Returns 'NO', 'LOW', or 'HIGH', or None on failure."""
    if not prompt:
        return "NO"
    snippet = prompt[:2000]
    try:
        async with httpx.AsyncClient(timeout=CLASSIFIER_TIMEOUT_S) as client:
            r = await client.post(
                f"{CLASSIFIER_URL}/api/generate",
                json={
                    "model": CLASSIFIER_MODEL,
                    "prompt": CLASSIFIER_PROMPT.format(prompt=snippet),
                    "stream": False,
                    "options": {"num_predict": 4, "temperature": 0.0},
                    "keep_alive": "24h",
                },
            )
            r.raise_for_status()
            answer = (r.json().get("response") or "").strip().upper()
            if answer.startswith("HIGH"):
                return "HIGH"
            if answer.startswith("LOW"):
                return "LOW"
            return "NO"
    except Exception as e:
        log.warning("classifier failed: %s", e)
        return None


async def _is_thinking_capable(model: str) -> bool:
    """Look up whether a big-GPU model has 'thinking' in its capabilities. Cached."""
    if model in EXCLUDE_MODELS:
        return False
    if model in INCLUDE_MODELS:
        return True
    if model in _thinking_cache:
        return _thinking_cache[model]
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.post(f"{UPSTREAM_URL}/api/show", json={"model": model})
            r.raise_for_status()
            caps = r.json().get("capabilities") or []
            is_thinking = "thinking" in caps
    except Exception as e:
        log.warning("capability lookup failed for %s: %s", model, e)
        is_thinking = False
    _thinking_cache[model] = is_thinking
    log.info("discovered model=%s thinking_capable=%s (cached)", model, is_thinking)
    return is_thinking


async def _maybe_set_think(body: dict, trace_id: str) -> dict:
    """Decide and stamp body['think'] for thinking-capable models on /api/chat."""
    model = body.get("model", "")
    client_supplied_think = "think" in body
    if not model:
        _decision_log(trace_id, model=model, reason="missing-model", body=body,
                      client_supplied_think=client_supplied_think)
        return body
    if not await _is_thinking_capable(model):
        _decision_log(trace_id, model=model, reason="not-thinking-capable", body=body,
                      client_supplied_think=client_supplied_think)
        return body
    if client_supplied_think:
        log.info("model=%s think=%s (client-supplied; passthrough)", model, body["think"])
        _decision_log(trace_id, model=model, reason="client-supplied", body=body,
                      client_supplied_think=client_supplied_think)
        return body

    last = _last_user_message(body.get("messages", []))
    override = _override_from_prefix(last)
    if override is not None:
        body["think"] = override
        if override:
            _apply_thinking_controls(body)
        log.info("model=%s think=%s (override)", model, override)
        _decision_log(trace_id, model=model, reason="override", body=body,
                      client_supplied_think=client_supplied_think)
        return body

    # RAG-augmented message: document synthesis almost always benefits from full deliberation.
    if "<context>" in last:
        body["think"] = True
        _apply_thinking_controls(body)
        log.info("model=%s think=True (rag-detected)", model)
        _decision_log(trace_id, model=model, reason="rag-detected", body=body,
                      client_supplied_think=client_supplied_think)
        return body

    tier = await _classify(last)
    if tier is None:
        body["think"] = True
        _apply_thinking_controls(body)
        log.info("model=%s think=True (classifier-failed default)", model)
        reason = "classifier-failed default"
    elif tier == "NO":
        body["think"] = False
        log.info("model=%s think=False (classified NO)", model)
        reason = "classified NO"
    elif tier == "LOW":
        body["think"] = False
        log.info("model=%s think=False (classified LOW)", model)
        reason = "classified LOW"
    else:
        body["think"] = True
        _apply_thinking_controls(body)
        log.info("model=%s think=True (classified HIGH)", model)
        reason = "classified HIGH"
    _decision_log(trace_id, model=model, reason=reason, body=body,
                  client_supplied_think=client_supplied_think)
    return body


def _is_streaming(body: dict) -> bool:
    return body.get("stream", True)


async def _forward(
    request: Request,
    body_bytes: bytes,
    body_obj: Optional[dict],
    trace_id: str,
    *,
    target_base: str = UPSTREAM_URL,
) -> Response:
    """Forward the request to target_base; stream back if upstream streams."""
    url = f"{target_base}{request.url.path}"
    params = dict(request.query_params)
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length")}

    streaming = body_obj is not None and _is_streaming(body_obj)

    client = httpx.AsyncClient(timeout=None)
    req = client.build_request(request.method, url, content=body_bytes, params=params, headers=headers)
    started = time.perf_counter()
    try:
        upstream = await client.send(req, stream=True)
    except Exception:
        await client.aclose()
        raise
    headers_ms = (time.perf_counter() - started) * 1000
    if ROUTER_DEBUG_DECISIONS:
        log.info(
            "forward_headers trace_id=%s method=%s path=%s target=%s status=%s stream=%s elapsed_ms=%.1f",
            trace_id, request.method, request.url.path, target_base,
            upstream.status_code, streaming, headers_ms,
        )

    if not streaming:
        try:
            content = await upstream.aread()
            total_ms = (time.perf_counter() - started) * 1000
            if ROUTER_DEBUG_DECISIONS:
                log.info(
                    "forward_complete trace_id=%s method=%s path=%s status=%s stream=False elapsed_ms=%.1f",
                    trace_id, request.method, request.url.path, upstream.status_code, total_ms,
                )
            return Response(
                content=content,
                status_code=upstream.status_code,
                media_type=upstream.headers.get("content-type"),
            )
        finally:
            await upstream.aclose()
            await client.aclose()

    async def gen():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            total_ms = (time.perf_counter() - started) * 1000
            if ROUTER_DEBUG_DECISIONS:
                log.info(
                    "forward_complete trace_id=%s method=%s path=%s status=%s stream=True elapsed_ms=%.1f",
                    trace_id, request.method, request.url.path, upstream.status_code, total_ms,
                )
            await upstream.aclose()
            await client.aclose()

    return StreamingResponse(
        gen(),
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type", "application/x-ndjson"),
    )


@app.get("/health")
async def health():
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            up  = await client.get(f"{UPSTREAM_URL}/api/version")
            sm  = await client.get(f"{SMALL_UPSTREAM_URL}/api/version")
            cl  = await client.get(f"{CLASSIFIER_URL}/api/version")
        registry_view = {
            k: ("big" if v == UPSTREAM_URL else "small")
            for k, v in _model_backend.items()
        }
        return {
            "ok": up.status_code == 200 and sm.status_code == 200 and cl.status_code == 200,
            "upstream_big": up.status_code,
            "upstream_small": sm.status_code,
            "classifier": cl.status_code,
            "model_registry": registry_view,
            "thinking_cache": _thinking_cache,
            "exclude_override": sorted(EXCLUDE_MODELS),
            "include_override": sorted(INCLUDE_MODELS),
            "router_debug_decisions": ROUTER_DEBUG_DECISIONS,
        }
    except Exception as e:
        return JSONResponse(status_code=503, content={"ok": False, "error": str(e)})


@app.get("/api/tags")
async def tags():
    """Merge model lists from both backends into a single /api/tags response."""
    all_models = []
    for backend_url in (UPSTREAM_URL, SMALL_UPSTREAM_URL):
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                r = await client.get(f"{backend_url}/api/tags")
                r.raise_for_status()
                all_models.extend(r.json().get("models") or [])
        except Exception as e:
            log.warning("/api/tags fetch failed for %s: %s", backend_url, e)
    return JSONResponse({"models": all_models})


@app.post("/api/show")
async def show(request: Request):
    """Route /api/show to whichever backend owns the requested model."""
    trace_id = _trace_id_from_request(request)
    raw = await request.body()
    try:
        model = json.loads(raw).get("model", "")
    except Exception:
        model = ""
    target = await _backend_for_model(model) if model else UPSTREAM_URL
    return await _forward(request, raw, None, trace_id, target_base=target)


@app.post("/api/chat")
async def chat(request: Request):
    """Route to the owning backend; apply thinking classification for big-GPU models."""
    trace_id = _trace_id_from_request(request)
    raw = await request.body()
    try:
        body = json.loads(raw)
    except Exception:
        return await _forward(request, raw, None, trace_id)

    model = body.get("model", "")
    target = await _backend_for_model(model) if model else UPSTREAM_URL

    if target == UPSTREAM_URL:
        body = await _maybe_set_think(body, trace_id)

    new_raw = json.dumps(body).encode("utf-8")
    return await _forward(request, new_raw, body, trace_id, target_base=target)


# Catch-all transparent proxy for all other paths and methods (management ops → big GPU).
@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"])
async def passthrough(path: str, request: Request):
    trace_id = _trace_id_from_request(request)
    raw = await request.body()
    try:
        body = json.loads(raw) if raw else None
    except Exception:
        body = None
    return await _forward(request, raw, body, trace_id)
