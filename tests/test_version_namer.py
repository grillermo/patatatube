import json

import pytest

import version_namer
import library


class FakeResponse:
    def __init__(self, content=None, status_code=200, body=None):
        self.status_code = status_code
        self._content = content
        self.text = body if body is not None else json.dumps(content or {})

    def json(self):
        return {"choices": [{"message": {"content": self._content}}]}


def _stub_post(monkeypatch, *, content=None, status_code=200):
    def fake_post(*args, **kwargs):
        return FakeResponse(content=content, status_code=status_code)

    monkeypatch.setattr(version_namer.httpx, "post", fake_post)


def test_label_versions_happy_path(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content='["720p Dual Lat", "DVDRip Lat"]')
    labels = version_namer.label_versions(["Kiki.720p-Dual-Lat", "Kiki.DVDRip-Lat"])
    assert labels == ["720p Dual Lat", "DVDRip Lat"]


def test_label_versions_strips_and_tolerates_fence(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content='```json\n[" 720p ", "1080p"]\n```')
    assert version_namer.label_versions(["a", "b"]) == ["720p", "1080p"]


def test_label_versions_empty_input_skips_call(monkeypatch):
    # No key, no HTTP: empty input returns [] before anything happens.
    monkeypatch.delenv("VERSION_NAME_LLM_API_KEY", raising=False)
    assert version_namer.label_versions([]) == []


def test_label_versions_missing_key_raises(monkeypatch):
    monkeypatch.delenv("VERSION_NAME_LLM_API_KEY", raising=False)
    with pytest.raises(version_namer.VersionNamerError):
        version_namer.label_versions(["a"])


def test_label_versions_non_200_raises(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content="[]", status_code=500)
    with pytest.raises(version_namer.VersionNamerError):
        version_namer.label_versions(["a"])


def test_label_versions_count_mismatch_raises(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content='["only one"]')
    with pytest.raises(version_namer.VersionNamerError):
        version_namer.label_versions(["a", "b"])


def test_label_versions_non_list_raises(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content='{"a": 1}')
    with pytest.raises(version_namer.VersionNamerError):
        version_namer.label_versions(["a"])


def test_label_versions_empty_entry_raises(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content='["720p", "  "]')
    with pytest.raises(version_namer.VersionNamerError):
        version_namer.label_versions(["a", "b"])


def test_label_versions_not_json_raises(monkeypatch):
    monkeypatch.setenv("VERSION_NAME_LLM_API_KEY", "key")
    _stub_post(monkeypatch, content="720p, 1080p")
    with pytest.raises(version_namer.VersionNamerError):
        version_namer.label_versions(["a", "b"])


# --- library._relabel_versions -------------------------------------------------


def test_relabel_single_version_is_noop(monkeypatch):
    called = []
    monkeypatch.setattr(version_namer, "label_versions", lambda names: called.append(names) or names)
    versions = [{"source_path": "/m/Kiki.mkv", "label": "1080p"}]
    library._relabel_versions(versions)
    assert versions[0]["label"] == "1080p"
    assert called == []


def test_relabel_multi_version_calls_llm(monkeypatch):
    monkeypatch.setattr(library.db, "get_version_labels", lambda paths: {})
    monkeypatch.setattr(
        version_namer, "label_versions", lambda names: ["720p Dual Lat", "DVDRip Lat"]
    )
    versions = [
        {"source_path": "/m/Kiki.720p-Dual-Lat.mkv", "label": "720p"},
        {"source_path": "/m/Kiki.DVDRip-Lat.mkv", "label": "Version 2"},
    ]
    library._relabel_versions(versions)
    assert [v["label"] for v in versions] == ["720p Dual Lat", "DVDRip Lat"]


def test_relabel_reuses_stored_labels_and_skips_llm(monkeypatch):
    stored = {"/m/a.mkv": "720p Dual Lat", "/m/b.mkv": "DVDRip Lat"}
    monkeypatch.setattr(library.db, "get_version_labels", lambda paths: stored)
    called = []
    monkeypatch.setattr(version_namer, "label_versions", lambda names: called.append(names) or [])
    versions = [
        {"source_path": "/m/a.mkv", "label": "old"},
        {"source_path": "/m/b.mkv", "label": "old"},
    ]
    library._relabel_versions(versions)
    assert [v["label"] for v in versions] == ["720p Dual Lat", "DVDRip Lat"]
    assert called == []


def test_relabel_calls_llm_when_one_label_missing(monkeypatch):
    # Only one of the two paths has a stored label -> must re-run the LLM for the set.
    monkeypatch.setattr(library.db, "get_version_labels", lambda paths: {"/m/a.mkv": "720p"})
    monkeypatch.setattr(version_namer, "label_versions", lambda names: ["X", "Y"])
    versions = [
        {"source_path": "/m/a.mkv", "label": "old"},
        {"source_path": "/m/b.mkv", "label": "old"},
    ]
    library._relabel_versions(versions)
    assert [v["label"] for v in versions] == ["X", "Y"]
