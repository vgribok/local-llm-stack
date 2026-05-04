"""
Focused pre-deploy tests for think-router/app.py.
Covers pure helpers and the new model-registry / routing logic (httpx mocked).
"""

import asyncio
import json
import sys
import types
import unittest
from unittest.mock import AsyncMock, MagicMock, patch


# ---------------------------------------------------------------------------
# Stub out the FastAPI / httpx surface so we can import app.py without a
# running server. The real classes are only needed at request-handler time.
# ---------------------------------------------------------------------------
def _make_stub(name):
    mod = types.ModuleType(name)
    sys.modules[name] = mod
    return mod


# We only need to stub sub-modules that are imported at module level.
# fastapi is already importable (we pip-installed it), but httpx may need
# the real package too — both are installed, so just import normally.
import os
os.environ.setdefault("UPSTREAM_URL",       "http://big:11434")
os.environ.setdefault("SMALL_UPSTREAM_URL", "http://small:11434")
os.environ.setdefault("CLASSIFIER_URL",     "http://small:11434")

import importlib
sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent))
app_mod = importlib.import_module("app")

BIG   = "http://big:11434"
SMALL = "http://small:11434"


# ---------------------------------------------------------------------------
# Helper: run a coroutine synchronously
# ---------------------------------------------------------------------------
def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ---------------------------------------------------------------------------
# Pure helper tests (no I/O)
# ---------------------------------------------------------------------------
class TestLastUserMessage(unittest.TestCase):
    def test_plain_string(self):
        msgs = [{"role": "user", "content": "hello"}]
        self.assertEqual(app_mod._last_user_message(msgs), "hello")

    def test_list_content(self):
        msgs = [{"role": "user", "content": [{"text": "hi"}, {"text": " there"}]}]
        self.assertEqual(app_mod._last_user_message(msgs), "hi  there")

    def test_skips_non_user(self):
        msgs = [
            {"role": "user",      "content": "first"},
            {"role": "assistant", "content": "reply"},
            {"role": "user",      "content": "second"},
        ]
        self.assertEqual(app_mod._last_user_message(msgs), "second")

    def test_empty(self):
        self.assertEqual(app_mod._last_user_message([]), "")


class TestOverrideFromPrefix(unittest.TestCase):
    def test_think(self):
        self.assertIs(app_mod._override_from_prefix("/think do this"), True)

    def test_no_think(self):
        self.assertIs(app_mod._override_from_prefix("/no_think do this"), False)

    def test_nothink(self):
        self.assertIs(app_mod._override_from_prefix("/nothink do this"), False)

    def test_no_override(self):
        self.assertIsNone(app_mod._override_from_prefix("just a normal message"))

    def test_leading_whitespace(self):
        self.assertIs(app_mod._override_from_prefix("  /think go"), True)


class TestApplyThinkingControls(unittest.TestCase):
    def test_prepends_to_existing_system(self):
        body = {"messages": [{"role": "system", "content": "original"}]}
        app_mod._apply_thinking_controls(body)
        self.assertIn(app_mod.CONCISE_THINKING_INSTRUCTION,
                      body["messages"][0]["content"])
        self.assertIn("original", body["messages"][0]["content"])

    def test_inserts_system_when_absent(self):
        body = {"messages": [{"role": "user", "content": "hi"}]}
        app_mod._apply_thinking_controls(body)
        self.assertEqual(body["messages"][0]["role"], "system")

    def test_no_messages_key(self):
        body = {}
        app_mod._apply_thinking_controls(body)
        self.assertEqual(body["messages"][0]["role"], "system")


class TestIsStreaming(unittest.TestCase):
    def test_defaults_true(self):
        self.assertTrue(app_mod._is_streaming({}))

    def test_explicit_false(self):
        self.assertFalse(app_mod._is_streaming({"stream": False}))

    def test_explicit_true(self):
        self.assertTrue(app_mod._is_streaming({"stream": True}))


# ---------------------------------------------------------------------------
# Model registry tests (httpx mocked)
# ---------------------------------------------------------------------------
def _tags_response(names, backend_label):
    """Build a mock httpx response for /api/tags."""
    resp = MagicMock()
    resp.raise_for_status = MagicMock()
    resp.json.return_value = {"models": [{"name": n} for n in names]}
    return resp


class TestModelRegistry(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        app_mod._model_backend.clear()

    async def test_refresh_populates_registry(self):
        big_resp   = _tags_response(["qwen3.6:27b", "llama3:70b"], "big")
        small_resp = _tags_response(["granite4.1:3b", "nomic-embed-text"], "small")

        async def fake_get(url, **kwargs):
            if "big" in url:
                return big_resp
            return small_resp

        with patch("httpx.AsyncClient") as MockClient:
            inst = AsyncMock()
            inst.__aenter__ = AsyncMock(return_value=inst)
            inst.__aexit__  = AsyncMock(return_value=False)
            inst.get = fake_get
            MockClient.return_value = inst

            await app_mod._refresh_model_registry()

        self.assertEqual(app_mod._model_backend["qwen3.6:27b"],        BIG)
        self.assertEqual(app_mod._model_backend["llama3:70b"],          BIG)
        self.assertEqual(app_mod._model_backend["granite4.1:3b"],       SMALL)
        self.assertEqual(app_mod._model_backend["nomic-embed-text"],    SMALL)

    async def test_backend_for_model_cache_hit(self):
        app_mod._model_backend["qwen3.6:27b"] = BIG
        result = await app_mod._backend_for_model("qwen3.6:27b")
        self.assertEqual(result, BIG)

    async def test_backend_for_model_cache_miss_falls_back_to_big(self):
        # Registry is empty; refresh will also find nothing → falls back to BIG
        async def fake_get(url, **kwargs):
            resp = MagicMock()
            resp.raise_for_status = MagicMock()
            resp.json.return_value = {"models": []}
            return resp

        with patch("httpx.AsyncClient") as MockClient:
            inst = AsyncMock()
            inst.__aenter__ = AsyncMock(return_value=inst)
            inst.__aexit__  = AsyncMock(return_value=False)
            inst.get = fake_get
            MockClient.return_value = inst

            result = await app_mod._backend_for_model("unknown-model")

        self.assertEqual(result, BIG)

    async def test_small_model_routes_to_small(self):
        app_mod._model_backend["nomic-embed-text"] = SMALL
        result = await app_mod._backend_for_model("nomic-embed-text")
        self.assertEqual(result, SMALL)


# ---------------------------------------------------------------------------
# Chat routing: thinking classification skipped for small-GPU models
# ---------------------------------------------------------------------------
class TestChatRoutingSkipsThinkingForSmallModels(unittest.IsolatedAsyncioTestCase):
    async def test_small_model_bypasses_maybe_set_think(self):
        """
        When a model resolves to the small backend, _maybe_set_think must NOT
        be called — the body should reach _forward unchanged.
        """
        app_mod._model_backend["granite4.1:3b"] = SMALL

        captured = {}

        async def fake_forward(request, body_bytes, body_obj, trace_id, *, target_base=BIG):
            captured["target"] = target_base
            captured["body"]   = json.loads(body_bytes)
            resp = MagicMock()
            resp.status_code = 200
            return resp

        body = {"model": "granite4.1:3b", "messages": [{"role": "user", "content": "hi"}]}

        request = MagicMock()
        request.body      = AsyncMock(return_value=json.dumps(body).encode())
        request.headers   = {}
        request.query_params = {}
        request.url.path  = "/api/chat"
        request.method    = "POST"

        with patch.object(app_mod, "_forward", fake_forward), \
             patch.object(app_mod, "_maybe_set_think", AsyncMock(side_effect=AssertionError(
                 "_maybe_set_think must not be called for small-GPU models"))):
            await app_mod.chat(request)

        self.assertEqual(captured["target"], SMALL)
        self.assertNotIn("think", captured["body"])

    async def test_big_model_calls_maybe_set_think(self):
        app_mod._model_backend["qwen3.6:27b"] = BIG

        think_called = {}

        async def fake_think(body, trace_id):
            think_called["yes"] = True
            body["think"] = False
            return body

        async def fake_forward(request, body_bytes, body_obj, trace_id, *, target_base=BIG):
            resp = MagicMock()
            resp.status_code = 200
            return resp

        body = {"model": "qwen3.6:27b", "messages": [{"role": "user", "content": "hello"}]}

        request = MagicMock()
        request.body         = AsyncMock(return_value=json.dumps(body).encode())
        request.headers      = {}
        request.query_params = {}
        request.url.path     = "/api/chat"
        request.method       = "POST"

        with patch.object(app_mod, "_forward", fake_forward), \
             patch.object(app_mod, "_maybe_set_think", fake_think):
            await app_mod.chat(request)

        self.assertTrue(think_called.get("yes"), "_maybe_set_think should have been called")


if __name__ == "__main__":
    unittest.main(verbosity=2)
