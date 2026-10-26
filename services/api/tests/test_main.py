import h2o_knowledge_mgmt_api.main as main
import httpx
import pytest
from fastapi.testclient import TestClient
from h2o_knowledge_mgmt_api.main import app

client = TestClient(app)


def test_health_check_returns_ok() -> None:
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.fixture(autouse=True)
def configure_endpoint(monkeypatch):
    monkeypatch.setattr(main, "LLM_BASE_URL", "https://maas.example.test/v1")
    monkeypatch.setattr(main, "LLM_MODEL", "external-tool-capable-model")
    monkeypatch.setattr(main, "LLM_API_KEY", "")


@pytest.mark.parametrize("api_key", ["", "test-private-key"])
def test_ask_uses_external_endpoint_and_optional_bearer_token(monkeypatch, api_key) -> None:
    monkeypatch.setattr(main, "LLM_API_KEY", api_key)

    def post(url, *, json, headers, timeout):
        assert url == "https://maas.example.test/v1/chat/completions"
        assert json["model"] == "external-tool-capable-model"
        assert json["messages"] == [{"role": "user", "content": "Hello"}]
        assert headers == ({"Authorization": f"Bearer {api_key}"} if api_key else {})
        assert timeout == main.LLM_TIMEOUT_SECONDS
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "Hello from MaaS"}}]},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(main, "post", post)
    response = client.post("/ask", json={"prompt": "Hello"})
    assert response.status_code == 200
    assert response.json() == {"answer": "Hello from MaaS"}


def test_ask_requires_endpoint_configuration(monkeypatch) -> None:
    monkeypatch.setattr(main, "LLM_BASE_URL", "")
    assert client.post("/ask", json={"prompt": "Hello"}).status_code == 503
