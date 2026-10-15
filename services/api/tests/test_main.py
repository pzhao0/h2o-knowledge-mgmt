import h2o_knowledge_mgmt_api.main as main
import httpx
from fastapi.testclient import TestClient
from h2o_knowledge_mgmt_api.main import app

client = TestClient(app)


def test_health_check_returns_ok() -> None:
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_ask_uses_configured_model_and_preserves_text_response(monkeypatch) -> None:
    def post(url, *, json, timeout):
        assert url == f"{main.LLM_BASE_URL}/chat/completions"
        assert json["model"] == main.LLM_MODEL
        assert json["messages"] == [{"role": "user", "content": "Hello"}]
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "Hello from Mistral"}}]},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(main, "post", post)
    response = client.post("/ask", json={"prompt": "Hello"})
    assert response.status_code == 200
    assert response.json() == {"answer": "Hello from Mistral"}
