import multiprocessing
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI
from setproctitle import setproctitle

import db
from middleware import setup_middleware
from router import SPLASH_DIR, VIDEOS_DIR, _load_static_asset_cache, router

load_dotenv()

PROCESS_NAME = "[PatataTube]"


def _set_process_name(name: str = PROCESS_NAME) -> None:
    multiprocessing.current_process().name = name
    setproctitle(name)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _set_process_name()
    db.init_db()
    VIDEOS_DIR.mkdir(exist_ok=True)
    SPLASH_DIR.mkdir(parents=True, exist_ok=True)
    _load_static_asset_cache()
    yield


app = FastAPI(lifespan=lifespan)
setup_middleware(app)
app.include_router(router)
