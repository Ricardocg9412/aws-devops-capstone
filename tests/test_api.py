from concurrent.futures import ThreadPoolExecutor
import json

from fastapi.testclient import TestClient
import pytest

from app.main import JsonFormatter, Settings, create_app


@pytest.fixture
def configured_app(tmp_path):
    return create_app(Settings(unready_file=tmp_path / "unready"))


@pytest.fixture
def client(configured_app):
    with TestClient(configured_app) as test_client:
        yield test_client


@pytest.fixture
def asset():
    return {"id": "srv-001", "name": "application-server", "environment": "dev",
            "type": "ec2", "status": "running"}


def test_asset_lifecycle(client, asset):
    assert client.get("/items").json() == []
    response = client.post("/items", json=asset)
    assert response.status_code == 201
    assert response.json() == asset
    assert response.headers["location"] == "/items/srv-001"
    assert client.get(response.headers["location"]).json() == asset
    assert client.get("/items").json() == [asset]
    response = client.delete("/items/srv-001")
    assert response.status_code == 204
    assert response.content == b""
    assert client.get("/items/srv-001").status_code == 404
    assert client.delete("/items/srv-001").status_code == 404
    assert client.get("/items").json() == []


def test_duplicate_does_not_overwrite(client, asset):
    assert client.post("/items", json=asset).status_code == 201
    assert client.post("/items", json={**asset, "status": "stopped"}).status_code == 409
    assert client.get("/items/srv-001").json() == asset


@pytest.mark.parametrize("changes", [
    {"environment": "staging"}, {"name": "   "}, {"id": "bad/id"},
    {"status": 123}, {"extra": True}, {"type": None},
])
def test_invalid_payload(client, asset, changes):
    assert client.post("/items", json={**asset, **changes}).status_code == 422
    assert client.get("/items").json() == []


def test_missing_field_and_malformed_json(client, asset):
    del asset["name"]
    assert client.post("/items", json=asset).status_code == 422
    assert client.post("/items", content="{", headers={"Content-Type": "application/json"}).status_code == 422


@pytest.mark.parametrize("environment", ["dev", "qa", "prod"])
def test_valid_environments(client, asset, environment):
    assert client.post("/items", json={**asset, "environment": environment}).status_code == 201


def test_capacity(client, asset):
    for index in range(20):
        assert client.post("/items", json={**asset, "id": f"srv-{index}"}).status_code == 201
    assert len(client.get("/items").json()) == 20


def test_concurrent_duplicate_creation(client, asset):
    with ThreadPoolExecutor(max_workers=10) as pool:
        statuses = list(pool.map(lambda _: client.post("/items", json=asset).status_code, range(20)))
    assert statuses.count(201) == 1
    assert statuses.count(409) == 19
    assert client.get("/items").json() == [asset]


def test_readiness_failure_and_recovery(tmp_path):
    marker = tmp_path / "unready"
    application = create_app(Settings(unready_file=marker))
    assert application.state.initialized is False
    with TestClient(application) as client:
        assert client.get("/ready").status_code == 200
        marker.touch()
        assert client.get("/ready").status_code == 503
        assert client.get("/health").status_code == 200
        marker.unlink()
        assert client.get("/ready").status_code == 200
    assert application.state.initialized is False


def test_start_unready(tmp_path):
    marker = tmp_path / "unready"
    marker.touch()
    with TestClient(create_app(Settings(unready_file=marker))) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/ready").status_code == 503


def test_state_lost_after_restart(configured_app, asset):
    with TestClient(configured_app) as client:
        assert client.post("/items", json=asset).status_code == 201
    with TestClient(configured_app) as client:
        assert client.get("/items").json() == []


def test_documentation(client):
    assert client.get("/docs").status_code == 200
    schema = client.get("/openapi.json").json()
    assert set(schema["paths"]) == {"/health", "/ready", "/items", "/items/{id}"}


def test_environment_configuration(monkeypatch, tmp_path):
    marker = tmp_path / "configured-unready"
    monkeypatch.setenv("INVENTORY_UNREADY_FILE", str(marker))
    monkeypatch.setenv("INVENTORY_LOG_LEVEL", "WARNING")
    settings = Settings()
    assert settings.unready_file == marker
    assert settings.log_level == "WARNING"


def test_structured_request_logging(client, caplog):
    import logging
    logger = logging.getLogger("inventory.requests")
    with caplog.at_level(logging.INFO, logger="inventory.requests"):
        logger.addHandler(caplog.handler)
        try:
            client.get("/items/missing")
        finally:
            logger.removeHandler(caplog.handler)
    entry = json.loads(JsonFormatter().format(caplog.records[-1]))
    assert entry["timestamp"]
    assert entry["level"] == "INFO"
    assert entry["method"] == "GET"
    assert entry["path"] == "/items/missing"
    assert entry["status_code"] == 404
    assert entry["duration_ms"] >= 0
