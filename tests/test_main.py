from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_root_has_version():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["service"] == "0717-cicd-demo"
    assert response.json()["version"]
    assert response.json()["build"] == "v5"
