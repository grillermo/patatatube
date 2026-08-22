import hashlib
import os

from fastapi import FastAPI, Request
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response, StreamingResponse

import cache

_MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_STRIPPED_HEADERS = {"content-length", "date", "server"}
# Endpoints whose whole point is live server state. converter.py moves jobs
# between queued/running/done with no HTTP request, so nothing flushes a cached
# copy: the iOS app polls this every 2s and would keep reading a frozen
# snapshot, leaving the download button spinning on a job that finished.
_NEVER_CACHED_PATHS = {"/api/jobs"}

# The web page's session cookie. Hardcoded rather than imported from router:
# middleware is imported by main *before* the router, and this is a wire-format
# constant, not shared logic.
_LOGIN_COOKIE = "upload_token"


def cache_key_for(request) -> str | None:
    """Cache key for a GET, or None when the request must not be cached.

    Bearer requests are scoped by a hash of the token so two tokens never share
    a response. Cookie-bearing requests get the same treatment for a different
    reason: this middleware answers from the cache *before* the endpoint runs,
    so an unscoped key would serve a cached authenticated page to a visitor with
    no cookie at all.
    """
    key = request.url.path
    if request.url.query:
        key += "?" + request.url.query

    auth = request.headers.get("authorization")
    if auth:
        scheme, _, token = auth.partition(" ")
        if scheme.lower() != "bearer" or not token:
            return None
        fingerprint = hashlib.sha256(token.encode()).hexdigest()
        return f"auth:{fingerprint}:{key}"

    session = request.cookies.get(_LOGIN_COOKIE)
    if session:
        fingerprint = hashlib.sha256(session.encode()).hexdigest()
        return f"cookie:{fingerprint}:{key}"

    return key


class RedisCacheMiddleware(BaseHTTPMiddleware):
    """FIFO Redis cache for GET responses, keyed by URL path + query string.

    Skipped entirely for Range requests (partial content). Bearer-authenticated
    requests are cached under a key scoped by the SHA-256 fingerprint of the
    token, so identical URLs for different tokens never share a response and
    the raw token never reaches Redis. Successful mutating requests flush the
    whole cache so list endpoints never serve stale data.
    """

    async def dispatch(self, request: Request, call_next):
        if request.method != "GET":
            response = await call_next(request)
            if request.method in _MUTATING_METHODS and response.status_code < 400:
                await cache.clear()
            return response

        if "range" in request.headers:
            return await call_next(request)

        if request.url.path in _NEVER_CACHED_PATHS:
            return await call_next(request)

        key = cache_key_for(request)
        if key is None:
            return await call_next(request)

        hit = await cache.get(key)
        if hit is not None:
            status_code, headers, body = hit
            return Response(
                content=body,
                status_code=status_code,
                headers={**headers, "x-cache": "hit"},
            )

        response = await call_next(request)
        if response.status_code != 200 or "set-cookie" in response.headers:
            return response

        cached_headers = {
            k: v
            for k, v in response.headers.items()
            if k.lower() not in _STRIPPED_HEADERS
        }

        async def tee():
            buffered: list[bytes] | None = []
            total = 0
            async for chunk in response.body_iterator:
                if buffered is not None:
                    total += len(chunk)
                    if total > cache.CACHE_MAX_ITEM_BYTES:
                        buffered = None
                    else:
                        buffered.append(chunk)
                yield chunk
            if buffered is not None:
                await cache.put(
                    key, response.status_code, cached_headers, b"".join(buffered)
                )

        return StreamingResponse(
            tee(),
            status_code=response.status_code,
            headers=dict(response.headers),
        )


def setup_middleware(app: FastAPI) -> None:
    allowed_hosts = [
        h.strip()
        for h in os.getenv(
            "ALLOWED_HOSTS",
            "videos.chiq.me,patatatube.chiq.me,localhost,127.0.0.1,0.0.0.0,testserver, 192.168.1.1",
        ).split(",")
        if h.strip()
    ]
    app.add_middleware(RedisCacheMiddleware)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=allowed_hosts)
