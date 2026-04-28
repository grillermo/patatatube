import shutil
from pathlib import Path

from pybalt import download as pybalt_download

import db

VIDEOS_DIR = Path("videos")


async def download_video(video_id: int, url: str):
    db.update_video(video_id, status="downloading")
    try:
        downloaded_path = await pybalt_download(url)
        downloaded_path = Path(downloaded_path)

        dest = VIDEOS_DIR / f"{video_id}{downloaded_path.suffix}"
        shutil.move(str(downloaded_path), str(dest))

        db.update_video(video_id, status="done", filename=dest.name)
    except Exception as exc:
        db.update_video(video_id, status="error", error_msg=str(exc))
