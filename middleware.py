import os

from fastapi import FastAPI
from fastapi.middleware.trustedhost import TrustedHostMiddleware


def setup_middleware(app: FastAPI) -> None:
    allowed_hosts = [
        h.strip()
        for h in os.getenv(
            "ALLOWED_HOSTS",
            "videos.chiq.me,patatatube.chiq.me,localhost,127.0.0.1,0.0.0.0,testserver",
        ).split(",")
        if h.strip()
    ]
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=allowed_hosts)
