import importlib

import httpx
import pytest


@pytest.fixture()
def classifier_env(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.setenv("JEV_API_KEY", "test-key")

    import db
    import classifier

    importlib.reload(db)
    importlib.reload(classifier)
    db.init_db()
    db.create_group(db.DEFAULT_UPLOAD_GROUP, "Inbox")
    return db, classifier


def _answer(choice, confidence):
    return {"answers": {"group": {"type": "choice", "choice": choice, "confidence": confidence}}}


def test_format_duration():
    import classifier

    assert classifier.format_duration(45) == "45s"
    assert classifier.format_duration(600) == "10m"
    assert classifier.format_duration(4320) == "1h 12m"
    assert classifier.format_duration(3600) == "1h"


def test_build_state_includes_every_field():
    import classifier

    state = classifier.build_state("A title", "A channel", 4320, "About the video")

    assert state == (
        "Title: A title\nChannel: A channel\nDuration: 1h 12m\nDescription: About the video"
    )


def test_build_state_skips_missing_fields():
    import classifier

    assert classifier.build_state("Only title", None, None, None) == "Title: Only title"


def test_build_state_truncates_a_long_description():
    import classifier

    state = classifier.build_state("t", None, None, "x" * 10_000)

    assert len(state) < classifier.DESCRIPTION_MAX_CHARS + 100


@pytest.mark.asyncio
async def test_classify_returns_the_chosen_group(monkeypatch, classifier_env):
    db, classifier = classifier_env
    seen = {}

    async def fake_post(payload):
        seen["payload"] = payload
        return _answer("asmr", 0.9)

    monkeypatch.setattr(classifier, "_post", fake_post)

    group = await classifier.classify("Rain sounds", "Calm", 3600, "sleep")

    assert group["name"] == "asmr"
    question = seen["payload"]["questions"]["group"]
    assert question["type"] == "choice"
    # Every group is offered except the inbox it would be moved out of.
    assert "asmr" in question["criteria"]
    assert question["criteria"]["asmr"] == "ASMR"
    assert db.DEFAULT_UPLOAD_GROUP not in question["criteria"]
    assert seen["payload"]["model"] == "jev-latest"
    assert "Duration: 1h" in seen["payload"]["state"]


@pytest.mark.asyncio
async def test_classify_describes_a_group_by_its_description_when_it_has_one(
    monkeypatch, classifier_env
):
    db, classifier = classifier_env
    db.update_group(db.get_group_by_name("children")["id"], description="Kids' songs, under 5 min")
    seen = {}

    async def fake_post(payload):
        seen["criteria"] = payload["questions"]["group"]["criteria"]
        return _answer("asmr", 0.9)

    monkeypatch.setattr(classifier, "_post", fake_post)
    await classifier.classify("t", None, None, None)

    assert seen["criteria"]["children"] == "Kids' songs, under 5 min"
    # No description: the label still stands in.
    assert seen["criteria"]["asmr"] == "ASMR"


@pytest.mark.asyncio
async def test_classify_below_the_threshold_returns_none(monkeypatch, classifier_env):
    _db, classifier = classifier_env

    async def fake_post(payload):
        return _answer("asmr", 0.59)

    monkeypatch.setattr(classifier, "_post", fake_post)

    assert await classifier.classify("t", None, None, None) is None


@pytest.mark.asyncio
async def test_classify_at_the_threshold_is_accepted(monkeypatch, classifier_env):
    _db, classifier = classifier_env

    async def fake_post(payload):
        return _answer("asmr", 0.6)

    monkeypatch.setattr(classifier, "_post", fake_post)

    assert (await classifier.classify("t", None, None, None))["name"] == "asmr"


@pytest.mark.asyncio
async def test_classify_ignores_a_choice_that_is_not_a_group(monkeypatch, classifier_env):
    _db, classifier = classifier_env

    async def fake_post(payload):
        return _answer("made-up", 0.99)

    monkeypatch.setattr(classifier, "_post", fake_post)

    assert await classifier.classify("t", None, None, None) is None


@pytest.mark.asyncio
async def test_classify_without_an_api_key_never_calls_the_api(monkeypatch, classifier_env):
    _db, classifier = classifier_env
    monkeypatch.delenv("JEV_API_KEY")

    async def fake_post(payload):
        raise AssertionError("must not be called")

    monkeypatch.setattr(classifier, "_post", fake_post)

    assert await classifier.classify("t", None, None, None) is None


@pytest.mark.asyncio
async def test_classify_swallows_api_errors(monkeypatch, classifier_env):
    _db, classifier = classifier_env

    async def fake_post(payload):
        raise httpx.ConnectError("boom")

    monkeypatch.setattr(classifier, "_post", fake_post)

    assert await classifier.classify("t", None, None, None) is None


@pytest.mark.asyncio
async def test_classify_swallows_a_malformed_response(monkeypatch, classifier_env):
    _db, classifier = classifier_env

    async def fake_post(payload):
        return {"answers": {}}

    monkeypatch.setattr(classifier, "_post", fake_post)

    assert await classifier.classify("t", None, None, None) is None


@pytest.mark.asyncio
async def test_the_client_never_reads_the_system_proxy_configuration(classifier_env, monkeypatch):
    """Regression: trust_env=True makes httpx call _scproxy.get_proxies(),
    whose XPC round trip segfaults a forked gunicorn worker on macOS and kills
    the download's BackgroundTask with it (2026-09-20, video 809)."""
    import classifier

    seen = {}
    real_init = httpx.AsyncClient.__init__

    def spy(self, *args, **kwargs):
        seen.update(kwargs)
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.AsyncClient, "__init__", spy)
    monkeypatch.setattr(
        httpx.AsyncClient, "post",
        lambda self, *a, **kw: (_ for _ in ()).throw(httpx.ConnectError("no network")),
    )

    await classifier.classify("T", "C", 60, "d")

    assert seen.get("trust_env") is False
