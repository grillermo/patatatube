# tests/test_devlog.py
import importlib
import json

import pytest
from fastapi.testclient import TestClient

AUTH = {"Authorization": "Bearer test-secret"}


@pytest.fixture()
def log_file(tmp_path):
    return tmp_path / "log" / "ios.jsonl"


@pytest.fixture()
def client(monkeypatch, tmp_path, log_file):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    monkeypatch.setenv("IOS_LOG_FILE", str(log_file))
    import db
    importlib.reload(db)
    import main
    importlib.reload(main)
    with TestClient(main.app) as c:
        yield c


def record(seq, msg="m", kind="play"):
    return {
        "ts": "2026-07-30T14:55:40.123Z",
        "seq": seq,
        "kind": kind,
        "msg": msg,
        "src": "VideoPlayerView.swift:187",
        "fn": "playWhenReady(item:on:)",
        "session": "SESSION",
        "meta": {"video_id": "812"},
    }


def read_lines(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


# --- auth -------------------------------------------------------------------


def test_devlog_requires_token(client, log_file):
    resp = client.post("/api/devlog", json={"session": "S", "records": [record(1)]})
    assert resp.status_code == 401
    assert not log_file.exists()


def test_devlog_rejects_wrong_token(client, log_file):
    resp = client.post(
        "/api/devlog",
        json={"session": "S", "records": [record(1)]},
        headers={"Authorization": "Bearer nope"},
    )
    assert resp.status_code == 401
    assert not log_file.exists()


# --- appending --------------------------------------------------------------


def test_devlog_appends_one_line_per_record(client, log_file):
    resp = client.post(
        "/api/devlog",
        json={"session": "S", "records": [record(1, "a"), record(2, "b")]},
        headers=AUTH,
    )
    assert resp.status_code == 204

    lines = read_lines(log_file)
    assert [r["msg"] for r in lines] == ["a", "b"]
    assert [r["seq"] for r in lines] == [1, 2]
    assert lines[0]["meta"] == {"video_id": "812"}


def test_devlog_appends_across_requests(client, log_file):
    for i in (1, 2, 3):
        client.post(
            "/api/devlog",
            json={"session": "S", "records": [record(i, f"m{i}")]},
            headers=AUTH,
        )
    assert [r["msg"] for r in read_lines(log_file)] == ["m1", "m2", "m3"]


def test_devlog_creates_parent_directory(client, log_file):
    assert not log_file.parent.exists()
    client.post("/api/devlog", json={"session": "S", "records": [record(1)]}, headers=AUTH)
    assert log_file.exists()


def test_devlog_keeps_embedded_newlines_on_one_line(client, log_file):
    client.post(
        "/api/devlog",
        json={"session": "S", "records": [record(1, "line1\nline2")]},
        headers=AUTH,
    )
    raw = log_file.read_text().splitlines()
    assert len(raw) == 1, "a record with a newline in it must stay one JSONL line"
    assert json.loads(raw[0])["msg"] == "line1\nline2"


def test_devlog_accepts_empty_batch(client, log_file):
    resp = client.post("/api/devlog", json={"session": "S", "records": []}, headers=AUTH)
    assert resp.status_code == 204


def test_devlog_rejects_malformed_body(client):
    resp = client.post("/api/devlog", json={"records": [record(1)]}, headers=AUTH)
    assert resp.status_code == 422


# --- limits -----------------------------------------------------------------


def test_devlog_rejects_oversize_batch(client, log_file):
    import devlog

    records = [record(i) for i in range(devlog.MAX_RECORDS_PER_REQUEST + 1)]
    resp = client.post(
        "/api/devlog", json={"session": "S", "records": records}, headers=AUTH
    )
    assert resp.status_code == 413
    assert not log_file.exists()


def test_devlog_rejects_oversize_body(client, log_file):
    import devlog

    big = record(1, "x" * (devlog.MAX_REQUEST_BYTES + 100))
    resp = client.post(
        "/api/devlog", json={"session": "S", "records": [big]}, headers=AUTH
    )
    assert resp.status_code == 413
    assert not log_file.exists()


# --- rotation ---------------------------------------------------------------


def test_devlog_rotates_at_cap(client, log_file, monkeypatch):
    import devlog

    monkeypatch.setattr(devlog, "MAX_LOG_BYTES", 50)

    client.post("/api/devlog", json={"session": "S", "records": [record(1, "old")]}, headers=AUTH)
    assert log_file.stat().st_size >= 50, "one record must exceed the test cap"

    client.post("/api/devlog", json={"session": "S", "records": [record(2, "new")]}, headers=AUTH)

    rotated = log_file.with_suffix(log_file.suffix + ".1")
    assert rotated.exists()
    assert [r["msg"] for r in read_lines(rotated)] == ["old"]
    assert [r["msg"] for r in read_lines(log_file)] == ["new"]


def test_devlog_rotation_keeps_only_two_generations(client, log_file, monkeypatch):
    import devlog

    monkeypatch.setattr(devlog, "MAX_LOG_BYTES", 50)
    for i, msg in enumerate(["a", "b", "c"], start=1):
        client.post(
            "/api/devlog", json={"session": "S", "records": [record(i, msg)]}, headers=AUTH
        )

    rotated = log_file.with_suffix(log_file.suffix + ".1")
    assert [r["msg"] for r in read_lines(log_file)] == ["c"]
    assert [r["msg"] for r in read_lines(rotated)] == ["b"], "older generation is discarded"
    assert not log_file.with_suffix(log_file.suffix + ".1.1").exists()


# --- module-level behaviour -------------------------------------------------


def test_append_skips_unserialisable_records_but_keeps_the_rest(monkeypatch, tmp_path):
    import devlog

    path = tmp_path / "ios.jsonl"
    monkeypatch.setenv("IOS_LOG_FILE", str(path))

    written = devlog.append([record(1, "a"), {"bad": {1, 2}}, record(3, "c")])

    assert written == 2
    assert [r["msg"] for r in read_lines(path)] == ["a", "c"]
