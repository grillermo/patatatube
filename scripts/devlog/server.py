#!/usr/bin/env python3
"""Receives the DevLog records a `./deploy --devlog` build of PatataTube sends.

A phone cannot write to this Mac's filesystem, so the diagnostics build POSTs
batches of JSON records to /api/devlog. This server appends them, one per line,
to log/devlog.jsonl and echoes each to stdout, so a run can be watched live.
Files from DevLog.upload arrive at /api/devlog/upload?name=... and land in
log/screens/. Both are emptied on start, so they only hold the current run.

    scripts/devlog/server.py                        # 0.0.0.0:19485 -> log/devlog.jsonl
    PATATATUBE_DEVLOG_PORT=19500 scripts/devlog/server.py
    curl http://$(scutil --get LocalHostName).local:${PATATATUBE_DEVLOG_PORT:-19485}/api/devlog/health

Stdlib only. It listens on the LAN without auth, so it caps request, record and
file sizes instead of trusting the client. (Separate from the backend's
POST /api/devlog -> log/ios.jsonl, which Xcode device runs still use.)
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlparse

PORT = int(os.getenv("PATATATUBE_DEVLOG_PORT", "19485"))
LOG_PATH = Path(os.getenv("PATATATUBE_DEVLOG_FILE", Path(__file__).resolve().parents[2] / "log" / "devlog.jsonl"))
UPLOADS_DIR = LOG_PATH.parent / "screens"
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RECORDS_PER_REQUEST = 2000
# At the cap the file becomes devlog.jsonl.1, so at most two generations exist.
MAX_LOG_BYTES = 32 * 1024 * 1024
MAX_UPLOAD_BYTES = 8 * 1024 * 1024
MAX_UPLOADS_TOTAL_BYTES = 512 * 1024 * 1024
UPLOAD_NAME = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")

write_lock = Lock()


def append(records):
    lines = []
    for record in records:
        try:
            lines.append(json.dumps(record, ensure_ascii=True, separators=(",", ":")))
        except (TypeError, ValueError):
            continue
    if not lines:
        return 0
    with write_lock:
        if LOG_PATH.exists() and LOG_PATH.stat().st_size >= MAX_LOG_BYTES:
            os.replace(LOG_PATH, LOG_PATH.with_suffix(LOG_PATH.suffix + ".1"))
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line, flush=True)
    return len(lines)


def uploads_size():
    return sum(p.stat().st_size for p in UPLOADS_DIR.iterdir() if p.is_file())


def save_upload(name, data):
    if not UPLOAD_NAME.match(name) or name.startswith("."):
        return False
    with write_lock:
        if uploads_size() + len(data) > MAX_UPLOADS_TOTAL_BYTES:
            return False
        (UPLOADS_DIR / name).write_bytes(data)
    return True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/api/devlog/health"):
            self._reply(200, b"ok\n")
        else:
            self._reply(404, b"not found\n")

    def do_POST(self):
        url = urlparse(self.path)
        if url.path == "/api/devlog/upload":
            return self._upload(parse_qs(url.query).get("name", [""])[0])
        if url.path != "/api/devlog":
            return self._reply(404, b"not found\n")
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            return self._reply(413, b"bad size\n")
        try:
            payload = json.loads(self.rfile.read(length))
            records = payload["records"]
            if not isinstance(records, list) or len(records) > MAX_RECORDS_PER_REQUEST:
                raise ValueError("records")
        except (ValueError, KeyError, TypeError):
            return self._reply(400, b"bad payload\n")
        append([r for r in records if isinstance(r, dict)])
        self._reply(204, b"")

    def _upload(self, name):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_UPLOAD_BYTES:
            return self._reply(413, b"bad size\n")
        data = self.rfile.read(length)
        if not save_upload(name, data):
            return self._reply(400, b"bad name or uploads full\n")
        print(json.dumps({"kind": "upload", "name": name, "bytes": length}), flush=True)
        self._reply(204, b"")

    def _reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *args):
        # Records already go to stdout; access lines would bury them.
        pass


def reset_logs():
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOG_PATH.write_text("")
    LOG_PATH.with_suffix(LOG_PATH.suffix + ".1").unlink(missing_ok=True)
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    for old in UPLOADS_DIR.iterdir():
        if old.is_file():
            old.unlink()


def make_server(port=PORT, host="0.0.0.0"):
    return ThreadingHTTPServer((host, port), Handler)


def main():
    reset_logs()
    server = make_server()
    print(f"devlog: listening on :{PORT}, writing {LOG_PATH}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
