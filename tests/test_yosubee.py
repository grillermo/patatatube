import json

import httpx
import pytest

import yosubee

URL = "http://localhost:3200/upload-from-video?user=hola@grillermo.com&playlist_name=English"


@pytest.fixture()
def configured(monkeypatch):
    monkeypatch.setenv("YOSUBEE_LOCAL_URL", URL)
    monkeypatch.setenv("YOSUBEE_LOCAL_TOKEN", "local-secret")


@pytest.mark.asyncio
async def test_send_posts_path_title_and_token(configured):
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(202, json={"job_id": "abc"})

    await yosubee.send("/media/videos/7.mp4", "A title", transport=httpx.MockTransport(handler))

    req = seen[0]
    assert str(req.url) == URL
    assert req.headers["X-Local-Token"] == "local-secret"
    assert json.loads(req.content) == {"path": "/media/videos/7.mp4", "title": "A title"}


@pytest.mark.asyncio
async def test_send_raises_with_yosubee_error_message(configured):
    transport = httpx.MockTransport(lambda r: httpx.Response(422, json={"error": "No card named English"}))
    with pytest.raises(yosubee.YosubeeError, match="No card named English"):
        await yosubee.send("/p.mp4", "t", transport=transport)


@pytest.mark.asyncio
async def test_send_raises_on_connect_error(configured):
    def handler(request):
        raise httpx.ConnectError("refused", request=request)

    with pytest.raises(yosubee.YosubeeError, match="unreachable"):
        await yosubee.send("/p.mp4", "t", transport=httpx.MockTransport(handler))


def test_not_configured_without_url(monkeypatch):
    monkeypatch.delenv("YOSUBEE_LOCAL_URL", raising=False)
    assert yosubee.configured() is False
