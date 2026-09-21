"""Route the app's own `logging` calls to stdout, where ./serve labels them.

Nothing configured logging before this, so every `logger.info` in classifier,
downloader, services, sd and promote went nowhere -- and warnings only reached
stderr through logging's bare last-resort handler. Only the app's loggers are
attached, not the root one, so httpx's per-request INFO lines stay quiet.
"""

import logging
import sys

APP_LOGGERS = ("classifier", "downloader", "promote", "sd", "services")


def configure() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
    for name in APP_LOGGERS:
        logger = logging.getLogger(name)
        if any(getattr(h, "_patatatube", False) for h in logger.handlers):
            continue  # idempotent: --reload and test reloads import main again
        handler._patatatube = True
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
