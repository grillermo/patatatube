"""Redis-backed FIFO response cache for GET requests.

Entries are stored per-URL (path + query string) with insertion order kept in
a Redis list; when the total cached bytes exceed CACHE_MAX_BYTES the oldest
entries are evicted first. Every operation fails open: if Redis is down the
cache is bypassed and retried after a short backoff.
"""

import os
import pickle
import time

import redis
from redis import asyncio as aioredis

CACHE_MAX_BYTES = int(os.getenv("CACHE_MAX_BYTES", str(300 * 1024 * 1024)))
# Responses bigger than this are never cached. Sized to admit full media
# responses (matches CACHE_MAX_BYTES, so one item may occupy the whole cache);
# it also bounds how much of a response body is buffered in memory.
CACHE_MAX_ITEM_BYTES = int(os.getenv("CACHE_MAX_ITEM_BYTES", str(300 * 1024 * 1024)))
# Entries expire on their own so a write nothing flushed (converter.py changes
# job and version status with no HTTP request in sight) goes stale for minutes,
# never forever. 0 disables expiry.
CACHE_TTL_SECONDS = int(os.getenv("CACHE_TTL_SECONDS", "300"))

_PREFIX = "ptcache"
_FIFO_KEY = f"{_PREFIX}:fifo"
_SIZES_KEY = f"{_PREFIX}:sizes"
_TOTAL_KEY = f"{_PREFIX}:total"
_RETRY_SECONDS = 30.0

_client: aioredis.Redis | None = None
_sync_client: "redis.Redis | None" = None
_down_until = 0.0


def _data_key(key: str) -> str:
    return f"{_PREFIX}:data:{key}"


def get_client() -> aioredis.Redis:
    global _client
    if _client is None:
        # Env is read lazily (not at import time) so load_dotenv() in main.py
        # has already run by the time the first request builds the client.
        _client = aioredis.from_url(
            os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0"),
            password=os.getenv("REDIS_PASSWORD") or None,
            socket_connect_timeout=0.5,
            socket_timeout=1.0,
        )
    return _client


def get_sync_client() -> "redis.Redis":
    """Blocking client for processes with no event loop (converter.py)."""
    global _sync_client
    if _sync_client is None:
        _sync_client = redis.Redis.from_url(
            os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0"),
            password=os.getenv("REDIS_PASSWORD") or None,
            socket_connect_timeout=0.5,
            socket_timeout=1.0,
        )
    return _sync_client


def set_sync_client(client) -> None:
    """Override the blocking Redis client (used by tests)."""
    global _sync_client
    _sync_client = client


def set_client(client: aioredis.Redis | None) -> None:
    """Override the Redis client (used by tests)."""
    global _client, _down_until
    _client = client
    _down_until = 0.0


def _available() -> bool:
    return time.monotonic() >= _down_until


def _mark_down() -> None:
    global _down_until
    _down_until = time.monotonic() + _RETRY_SECONDS


async def get(key: str) -> tuple[int, dict[str, str], bytes] | None:
    if not _available():
        return None
    try:
        raw = await get_client().get(_data_key(key))
    except Exception:
        _mark_down()
        return None
    if raw is None:
        return None
    try:
        return pickle.loads(raw)
    except Exception:
        return None


async def put(key: str, status_code: int, headers: dict[str, str], body: bytes) -> None:
    if not _available():
        return
    raw = pickle.dumps((status_code, headers, body))
    if len(raw) > CACHE_MAX_ITEM_BYTES:
        return
    try:
        r = get_client()
        # NX keeps FIFO order stable: an already-cached URL is not re-queued.
        if await r.set(_data_key(key), raw, nx=True, ex=CACHE_TTL_SECONDS or None):
            pipe = r.pipeline()
            pipe.rpush(_FIFO_KEY, key)
            pipe.hset(_SIZES_KEY, key, len(raw))
            pipe.incrby(_TOTAL_KEY, len(raw))
            await pipe.execute()
        await _evict(r)
    except Exception:
        _mark_down()


async def _evict(r: aioredis.Redis) -> None:
    total = int(await r.get(_TOTAL_KEY) or 0)
    while total > CACHE_MAX_BYTES:
        oldest = await r.lpop(_FIFO_KEY)
        if oldest is None:
            break
        key = oldest.decode() if isinstance(oldest, bytes) else oldest
        size = int(await r.hget(_SIZES_KEY, key) or 0)
        pipe = r.pipeline()
        pipe.delete(_data_key(key))
        pipe.hdel(_SIZES_KEY, key)
        pipe.decrby(_TOTAL_KEY, size)
        await pipe.execute()
        total -= size


async def clear() -> None:
    if not _available():
        return
    try:
        r = get_client()
        keys = [k async for k in r.scan_iter(match=f"{_PREFIX}:*")]
        if keys:
            await r.delete(*keys)
    except Exception:
        _mark_down()


def clear_blocking() -> None:
    """`clear()` for callers with no event loop -- i.e. converter.py.

    The middleware flushes on every mutating HTTP request, but the converter
    changes job/version status out of band, so without this a cached
    /api/videos or /api/videos/{id} keeps reporting 'converting' to the iOS
    app's poll loop until the entry expires. Fails open like everything else
    here: a Redis outage must never stop a job from finishing.
    """
    try:
        client = get_sync_client()
        keys = list(client.scan_iter(match=f"{_PREFIX}:*"))
        if keys:
            client.delete(*keys)
    except Exception:
        pass
