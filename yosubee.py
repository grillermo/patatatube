"""Hands a finished video to yosubee, which runs on the same machine.

Only the file's path crosses the wire: yosubee reads the mp4 off the shared
disk and does the MP3 conversion itself, so nothing here spawns ffmpeg and no
media bytes go over HTTP. YOSUBEE_LOCAL_URL points at yosubee's Caddy port
(3200), never a Rails port: Rails alternates between 3201 and 3202 on deploys.
"""

import os

import httpx

TIMEOUT_SECS = 5.0


class YosubeeError(Exception):
    pass


def configured() -> bool:
    return bool(os.getenv("YOSUBEE_LOCAL_URL"))


async def send(path: str, title: str, transport: httpx.AsyncBaseTransport | None = None) -> None:
    url = os.getenv("YOSUBEE_LOCAL_URL", "")
    headers = {"X-Local-Token": os.getenv("YOSUBEE_LOCAL_TOKEN", "")}
    # trust_env=False: see CLAUDE.md "Every httpx call passes trust_env=False".
    async with httpx.AsyncClient(timeout=TIMEOUT_SECS, trust_env=False, transport=transport) as client:
        try:
            resp = await client.post(url, json={"path": path, "title": title}, headers=headers)
        except httpx.HTTPError as e:
            raise YosubeeError(f"yosubee unreachable: {e}") from e
    if resp.is_success:
        return
    try:
        message = resp.json().get("error") or resp.text
    except ValueError:
        message = resp.text
    raise YosubeeError(f"yosubee {resp.status_code}: {message}")
