"""Thin proxy: OpenAI chat/completions → Elasticsearch unified inference API.

The ES /_inference/{id}/_stream endpoint returns OpenAI-compatible SSE chunks
but wraps each one in an extra "event: message" line and may include a UTF-8
BOM. This proxy strips those and passes the data lines straight through, so any
OpenAI-compatible client (LangChain ChatOpenAI, chatbot-rag-app, etc.) works
without modification.

Required env vars:
  ES_URL       — e.g. https://my-project.es.region.gcp.elastic.cloud
  ES_API_KEY   — Elasticsearch API key
  INFERENCE_ID — defaults to .anthropic-claude-4.6-sonnet-chat_completion
"""

import os
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse

app = FastAPI()

_ES_URL = os.environ["ES_URL"].rstrip("/")
_ES_API_KEY = os.environ["ES_API_KEY"]
_INFERENCE_ID = os.environ.get(
    "INFERENCE_ID", ".anthropic-claude-4.6-sonnet-chat_completion"
)
_STREAM_URL = f"{_ES_URL}/_inference/{_INFERENCE_ID}/_stream"
_ES_HEADERS = {
    "Authorization": f"ApiKey {_ES_API_KEY}",
    "Content-Type": "application/json",
}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    messages = body.get("messages", [])

    async def _stream():
        async with httpx.AsyncClient(timeout=120.0) as client:
            async with client.stream(
                "POST",
                _STREAM_URL,
                headers=_ES_HEADERS,
                json={"messages": messages},
            ) as resp:
                async for line in resp.aiter_lines():
                    # Strip UTF-8 BOM and whitespace; skip "event:" lines
                    line = line.lstrip("﻿").strip()
                    if line.startswith("data:"):
                        yield f"{line}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(_stream(), media_type="text/event-stream")


@app.get("/v1/models")
async def list_models():
    return JSONResponse({
        "object": "list",
        "data": [{"id": "claude-sonnet", "object": "model", "owned_by": "elastic"}],
    })


@app.get("/health")
async def health():
    return {"status": "ok", "inference_id": _INFERENCE_ID}
