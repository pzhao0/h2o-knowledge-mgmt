"""Minimal API application scaffold."""

import os

from fastapi import FastAPI, HTTPException
from httpx import HTTPError, post
from pydantic import BaseModel, Field

LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://h2o-llm-vllm/v1").rstrip("/")
LLM_MODEL = os.getenv(
    "LLM_MODEL", "RedHatAI/Mistral-Small-3.1-24B-Instruct-2503-quantized.w8a8"
)
LLM_TIMEOUT_SECONDS = float(os.getenv("LLM_TIMEOUT_SECONDS", "60"))

app = FastAPI(
    title="H2O Knowledge Management API",
    description="A small API scaffold with a demo endpoint for the configured model.",
    version="0.1.0",
)


@app.get("/healthz", tags=["health"])
def health_check() -> dict[str, str]:
    """Report that the API process is responding."""
    return {"status": "ok"}


class AskRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)


@app.post("/ask", tags=["demo"])
def ask_model(request: AskRequest) -> dict[str, str]:
    """Send one prompt to the OpenAI-compatible model endpoint."""
    try:
        response = post(
            f"{LLM_BASE_URL}/chat/completions",
            json={
                "model": LLM_MODEL,
                "messages": [{"role": "user", "content": request.prompt}],
                "temperature": 0.2,
                "max_tokens": 256,
            },
            timeout=LLM_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        answer = response.json()["choices"][0]["message"]["content"]
    except (HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=502, detail="The model endpoint did not return a valid response."
        ) from exc

    return {"answer": answer}
