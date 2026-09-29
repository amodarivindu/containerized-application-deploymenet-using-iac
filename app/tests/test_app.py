import pytest

from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_health_returns_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_info_contains_version_and_host(client):
    resp = client.get("/api/info")
    assert resp.status_code == 200
    body = resp.get_json()
    assert {"version", "environment", "hostname", "started"} <= body.keys()


def test_index_renders_html(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"Hello from AWS ECS Fargate" in resp.data


def test_unknown_route_is_404(client):
    assert client.get("/does-not-exist").status_code == 404
