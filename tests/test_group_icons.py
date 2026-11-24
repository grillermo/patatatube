import base64
import importlib

import httpx
import pytest
from fastapi.testclient import TestClient

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    monkeypatch.setenv("PIXELLABS_API_TOKEN", "px-token")
    import db
    importlib.reload(db)
    import main
    importlib.reload(main)
    import pixellab
    monkeypatch.setattr(pixellab, "ICONS_DIR", tmp_path / "group_icons")
    with TestClient(main.app) as c:
        yield c


AUTH = {"Authorization": "Bearer test-secret"}


def _fake_pixellab(monkeypatch, handler):
    import pixellab
    real = pixellab.generate

    async def fake(prompt, transport=None):
        return await real(prompt, transport=httpx.MockTransport(handler))

    monkeypatch.setattr(pixellab, "generate", fake)


def _group_id(client):
    return client.post("/api/groups", json={"name": "cats", "label": "Cats"}, headers=AUTH).json()["id"]


def test_generate_sends_the_prompt_and_serves_the_preview(client, monkeypatch):
    seen = {}

    def handler(request):
        seen["auth"] = request.headers["Authorization"]
        seen["body"] = request.read().decode()
        b64 = "data:image/png;base64," + base64.b64encode(PNG).decode()
        return httpx.Response(200, json={"image": {"base64": b64}})

    _fake_pixellab(monkeypatch, handler)
    resp = client.post("/api/icons/generate", json={"prompt": "a sleepy cat"}, headers=AUTH)
    assert resp.status_code == 200
    body = resp.json()
    assert body["icon_url"] == f"/group-icons/{body['icon']}.png"
    assert seen["auth"] == "Bearer px-token"
    assert "a sleepy cat" in seen["body"] and '"width": 16' in seen["body"].replace('":16', '": 16')

    img = client.get(body["icon_url"])
    assert img.status_code == 200 and img.content == PNG
    assert img.headers["content-type"] == "image/png"


def test_generate_requires_token_and_prompt(client):
    assert client.post("/api/icons/generate", json={"prompt": "cat"}).status_code == 401
    assert client.post("/api/icons/generate", json={"prompt": "  "}, headers=AUTH).status_code == 400


def test_generate_without_pixellab_token_is_503(client, monkeypatch):
    monkeypatch.delenv("PIXELLABS_API_TOKEN")
    assert client.post("/api/icons/generate", json={"prompt": "cat"}, headers=AUTH).status_code == 503


@pytest.mark.parametrize("status,expected", [(402, 429), (500, 502)])
def test_generate_maps_pixellab_failures(client, monkeypatch, status, expected):
    _fake_pixellab(monkeypatch, lambda r: httpx.Response(status, text="nope"))
    resp = client.post("/api/icons/generate", json={"prompt": "cat"}, headers=AUTH)
    assert resp.status_code == expected


def test_generate_rejects_a_non_png(client, monkeypatch):
    b64 = base64.b64encode(b"GIF89a....").decode()
    _fake_pixellab(monkeypatch, lambda r: httpx.Response(200, json={"image": {"base64": b64}}))
    assert client.post("/api/icons/generate", json={"prompt": "cat"}, headers=AUTH).status_code == 502


def test_set_and_clear_group_icon(client, monkeypatch):
    b64 = base64.b64encode(PNG).decode()
    _fake_pixellab(monkeypatch, lambda r: httpx.Response(200, json={"image": {"base64": b64}}))
    gid = _group_id(client)
    icon = client.post("/api/icons/generate", json={"prompt": "cat"}, headers=AUTH).json()["icon"]

    resp = client.put(f"/api/groups/{gid}/icon", json={"icon": icon}, headers=AUTH)
    assert resp.status_code == 200
    assert resp.json()["icon_url"] == f"/group-icons/{icon}.png"
    listed = {g["id"]: g for g in client.get("/api/groups").json()["groups"]}
    assert listed[gid]["icon_url"] == f"/group-icons/{icon}.png"

    resp = client.put(f"/api/groups/{gid}/icon", json={"icon": None}, headers=AUTH)
    assert resp.json()["icon_url"] is None


def test_set_group_icon_rejects_unknown_or_traversal_names(client):
    gid = _group_id(client)
    for bad in ["../../etc/passwd", "a" * 32, "nothex"]:
        resp = client.put(f"/api/groups/{gid}/icon", json={"icon": bad}, headers=AUTH)
        assert resp.status_code == 400
    assert client.put(f"/api/groups/{gid}/icon", json={"icon": None}).status_code == 401


def test_icon_file_route_only_serves_icon_names(client):
    assert client.get("/group-icons/..%2Fwatch_later.sqlite").status_code == 404
    assert client.get("/group-icons/" + "a" * 32 + ".png").status_code == 404
