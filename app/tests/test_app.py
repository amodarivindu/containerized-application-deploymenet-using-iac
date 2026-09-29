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


def test_index_renders_calculator(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"Calculator" in resp.data
    assert b'data-action="equals"' in resp.data


def test_calculate_returns_result(client):
    resp = client.post("/api/calculate", json={"expression": "(2 + 3) × 4"})
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["result"] == 20
    assert body["expression"] == "(2 + 3) × 4"


def test_calculate_division_by_zero_is_400(client):
    resp = client.post("/api/calculate", json={"expression": "1 / 0"})
    assert resp.status_code == 400
    assert resp.get_json()["error"] == "Division by zero"


def test_calculate_rejects_code(client):
    resp = client.post("/api/calculate", json={"expression": "__import__('os')"})
    assert resp.status_code == 400
    assert "Unsupported" in resp.get_json()["error"]


def test_calculate_without_json_body_is_400(client):
    resp = client.post("/api/calculate", data="not json")
    assert resp.status_code == 400


def test_calculate_requires_post(client):
    assert client.get("/api/calculate").status_code == 405


def test_unknown_route_is_404(client):
    assert client.get("/does-not-exist").status_code == 404
