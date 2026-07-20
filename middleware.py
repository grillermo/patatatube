import os

from fastapi import FastAPI, Request
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response, StreamingResponse

import cache

_MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_STRIPPED_HEADERS = {"content-length", "date", "server"}


class RedisCacheMiddleware(BaseHTTPMiddleware):
    """FIFO Redis cache for GET responses, keyed by URL path + query string.

    Skipped entirely for Range requests (partial content) and requests that
    carry an Authorization header (a cached body would bypass the token
    check). Successful mutating requests flush the whole cache so list
    endpoints never serve stale data.
    """

    async def dispatch(self, request: Request, call_next):
        if request.method != "GET":
            response = await call_next(request)
            if request.method in _MUTATING_METHODS and response.status_code < 400:
                await cache.clear()
            return response

        if "range" in request.headers or "authorization" in request.headers:
            return await call_next(request)

        key = request.url.path
        if request.url.query:
            key += "?" + request.url.query

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
