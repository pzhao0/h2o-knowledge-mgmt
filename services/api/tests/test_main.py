from fastapi.testclient import TestClient
from h2o_knowledge_mgmt_api.main import app

client = TestClient(app)


def test_health_check_returns_ok() -> None:
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
