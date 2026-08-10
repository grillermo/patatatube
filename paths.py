"""Media storage roots, read from env at import time.

MEDIA_ROOT unset defaults to '.', which keeps VIDEOS_DIR/HLS_DIR byte-identical
to the repo-relative paths every other module used before this existed.
"""

import os
from pathlib import Path

MEDIA_ROOT = Path(os.getenv("MEDIA_ROOT", "."))
VIDEOS_DIR = Path(os.getenv("VIDEOS_DIR", str(MEDIA_ROOT / "videos")))
HLS_DIR = Path(os.getenv("HLS_DIR", str(MEDIA_ROOT / "data/hls")))


def ensure_media_root() -> None:
    """Refuse to start against a missing external volume.

    Without this, VIDEOS_DIR.mkdir(parents=True) on an unmounted volume
    silently recreates the tree on the boot disk instead of failing loudly.
    """
    if str(MEDIA_ROOT) == ".":
        return
    if not MEDIA_ROOT.is_dir():
        raise RuntimeError(f"MEDIA_ROOT {MEDIA_ROOT} does not exist or is not a directory")
    if os.stat(MEDIA_ROOT).st_dev == os.stat("/").st_dev:
        raise RuntimeError(
            f"MEDIA_ROOT {MEDIA_ROOT} resolved onto the boot volume "
            "(the external volume is probably not mounted)"
        )
