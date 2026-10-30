# tests/test_devlog_server.py
import importlib.util
import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

SERVER = Path(__file__).resolve().parents[1] / "scripts" / "devlog" / "server.py"


@pytest.fixture()
def srv(tmp_path, monkeypatch):
    monkeypatch.setenv("PATATATUBE_DEVLOG_FILE", str(tmp_path / "log" / "devlog.jsonl"))
    spec = importlib.util.spec_from_file_location("devlog_server_under_test", SERVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.reset_logs()
    server = module.make_server(0, host="127.0.0.1")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    module.base = f"http://127.0.0.1:{server.server_address[1]}"
    yield module
    server.shutdown()
    server.server_close()


def call(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def test_health(srv):
    assert call(srv.base + "/health") == (200, b"ok\n")
    assert call(srv.base + "/api/devlog/health") == (200, b"ok\n")


def test_records_are_appended_and_echoed(srv, capsys):
    body = json.dumps({"session": "S", "records": [{"kind": "state", "msg": "a"}, {"kind": "play", "msg": "b"}]})
    assert call(srv.base + "/api/devlog", body.encode())[0] == 204
    lines = srv.LOG_PATH.read_text().splitlines()
    assert [json.loads(l)["msg"] for l in lines] == ["a", "b"]
    assert '"msg":"a"' in capsys.readouterr().out


def test_bad_payloads_are_rejected(srv):
    assert call(srv.base + "/api/devlog", b"not json")[0] == 400
    assert call(srv.base + "/api/devlog", b'{"records": "x"}')[0] == 400


def test_oversize_request_is_rejected(srv, monkeypatch):
    monkeypatch.setattr(srv, "MAX_REQUEST_BYTES", 10)
    assert call(srv.base + "/api/devlog", b'{"records": []}')[0] == 413


def test_upload_is_stored(srv):
    assert call(srv.base + "/api/devlog/upload?name=shot-1.png", b"\x89PNG")[0] == 204
    assert (srv.UPLOADS_DIR / "shot-1.png").read_bytes() == b"\x89PNG"


def test_upload_rejects_bad_names_and_sizes(srv, monkeypatch):
    assert call(srv.base + "/api/devlog/upload?name=../x", b"1")[0] == 400
    assert call(srv.base + "/api/devlog/upload?name=.hidden", b"1")[0] == 400
    monkeypatch.setattr(srv, "MAX_UPLOAD_BYTES", 2)
    assert call(srv.base + "/api/devlog/upload?name=big", b"123")[0] == 413


def test_upload_total_cap(srv, monkeypatch):
    monkeypatch.setattr(srv, "MAX_UPLOADS_TOTAL_BYTES", 4)
    assert call(srv.base + "/api/devlog/upload?name=a", b"123")[0] == 204
    assert call(srv.base + "/api/devlog/upload?name=b", b"123")[0] == 400


def test_unknown_path_is_404(srv):
    assert call(srv.base + "/nope")[0] == 404


def test_reset_logs_empties_everything(srv):
    srv.LOG_PATH.write_text("old\n")
    srv.LOG_PATH.with_suffix(".jsonl.1").write_text("older\n")
    (srv.UPLOADS_DIR / "x.png").write_bytes(b"1")
    srv.reset_logs()
    assert srv.LOG_PATH.read_text() == ""
    assert not srv.LOG_PATH.with_suffix(".jsonl.1").exists()
    assert list(srv.UPLOADS_DIR.iterdir()) == []
