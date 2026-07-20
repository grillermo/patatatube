# tests/test_cache.py
import importlib

import pytest
from fakeredis import FakeAsyncRedis
from fastapi.testclient import TestClient

import cache


@pytest.fixture()
def fake_redis():
    fake = FakeAsyncRedis()
    cache.set_client(fake)
    yield fake
    cache.set_client(None)


@pytest.fixture()
def client(monkeypatch, tmp_path, fake_redis):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    # Reload db first so DB_PATH env var is picked up
    import db
    importlib.reload(db)
    # Then reload main so it gets the reloaded db module
    import main
    importlib.reload(main)
    with TestClient(main.app) as c:
        yield c


@pytest.mark.asyncio
async def test_put_get_roundtrip(fake_redis):
    await cache.put("/x?a=1", 200, {"content-type": "text/plain"}, b"hello")
    assert await cache.get("/x?a=1") == (200, {"content-type": "text/plain"}, b"hello")
    assert await cache.get("/x?a=2") is None


@pytest.mark.asyncio
async def test_fifo_eviction_drops_oldest(fake_redis, monkeypatch):
    body = b"x" * 1000
    entry_size = len(cache.pickle.dumps((200, {}, body)))
    monkeypatch.setattr(cache, "CACHE_MAX_BYTES", entry_size * 2)
    await cache.put("/a", 200, {}, body)
    await cache.put("/b", 200, {}, body)
    await cache.put("/c", 200, {}, body)
    assert await cache.get("/a") is None
    assert await cache.get("/b") is not None
    assert await cache.get("/c") is not None


@pytest.mark.asyncio
async def test_oversized_entry_not_cached(fake_redis, monkeypatch):
    monkeypatch.setattr(cache, "CACHE_MAX_ITEM_BYTES", 100)
    await cache.put("/big", 200, {}, b"x" * 200)
    assert await cache.get("/big") is None


@pytest.mark.asyncio
async def test_clear_removes_everything(fake_redis):
    await cache.put("/a", 200, {}, b"1")
    await cache.clear()
    assert await cache.get("/a") is None
    assert await fake_redis.keys("*") == []


@pytest.mark.asyncio
async def test_fails_open_when_redis_down(monkeypatch):
    class Broken:
        def __getattr__(self, name):
            async def boom(*a, **kw):
                raise ConnectionError("down")
            return boom

    cache.set_client(Broken())
    try:
        await cache.put("/a", 200, {}, b"1")
        assert await cache.get("/a") is None
        await cache.clear()
    finally:
        cache.set_client(None)


def test_get_is_cached_and_served_from_cache(client):
    first = client.get("/api/classifications")
    assert first.status_code == 200
    assert "x-cache" not in first.headers
    second = client.get("/api/classifications")
    assert second.status_code == 200
    assert second.headers["x-cache"] == "hit"
    assert second.content == first.content


def test_query_params_are_part_of_key(client):
    client.get("/api/videos")
    hit = client.get("/api/videos")
    assert hit.headers.get("x-cache") == "hit"
    other = client.get("/api/videos?classification=children")
    assert "x-cache" not in other.headers


def test_mutation_flushes_cache(client, monkeypatch):
    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    client.get("/api/videos")
    assert client.get("/api/videos").headers.get("x-cache") == "hit"
    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/123"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    after = client.get("/api/videos")
    assert "x-cache" not in after.headers


def test_authorized_requests_bypass_cache(client):
    client.get("/api/videos")
    assert client.get("/api/videos").headers.get("x-cache") == "hit"
    authed = client.get(
        "/api/videos", headers={"Authorization": "Bearer test-secret"}
    )
    assert "x-cache" not in authed.headers
