import multiprocessing
from contextlib import asynccontextmanager

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI  # noqa: E402

import db  # noqa: E402
from middleware import setup_middleware  # noqa: E402
from paths import ensure_media_root  # noqa: E402
from router import SPLASH_DIR, VIDEOS_DIR, _load_static_asset_cache, router  # noqa: E402

PROCESS_NAME = "[PatataTube]"


def _set_process_name(name: str = PROCESS_NAME) -> None:
    # Deliberately NOT setproctitle(): on macOS it renames the process through a
    # synchronous LaunchServices XPC round-trip, which is illegal on the child
    # side of a fork from a multi-threaded parent. lifespan runs in every forked
    # gunicorn worker, so that call raced the kernel's Mach-port guard and took
    # workers out with EXC_GUARD/SIGKILL (~1 in 6 per ./serve, reported by the
    # arbiter as the misleading "was sent SIGKILL! Perhaps out of memory?").
    # This assignment is pure Python and touches no ports, so it is fork-safe.
    # The ps/Activity Monitor name is still set -- but once, in the arbiter,
    # before any fork, from gunicorn_conf.py; workers inherit it. See that file
    # for the full crash analysis.
    multiprocessing.current_process().name = name


@asynccontextmanager
async def lifespan(app: FastAPI):
    _set_process_name()
    ensure_media_root()
    db.init_db()
    VIDEOS_DIR.mkdir(parents=True, exist_ok=True)
    SPLASH_DIR.mkdir(parents=True, exist_ok=True)
    _load_static_asset_cache()
    yield


app = FastAPI(lifespan=lifespan)
setup_middleware(app)
app.include_router(router)
