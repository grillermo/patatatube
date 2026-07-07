import plex


SECTIONS = {"MediaContainer": {"Directory": [
    {"key": "1", "type": "movie", "title": "Movies"},
    {"key": "2", "type": "show", "title": "TV Shows"},
]}}

MOVIES = {"MediaContainer": {"Metadata": [
    {
        "ratingKey": "42",
        "title": "Akira",
        "summary": "Neo-Tokyo.",
        "Media": [{"Part": [{"file": "/Volumes/Media/media/movies/Akira/Akira.mkv"}]}],
    },
]}}

SHOWS = {"MediaContainer": {"Metadata": [{"ratingKey": "1262", "title": "The Bear"}]}}

EPISODES = {"MediaContainer": {"Metadata": [
    {
        "ratingKey": "1264",
        "grandparentRatingKey": "1262",
        "grandparentTitle": "The Bear",
        "title": "System",
        "parentIndex": 1,
        "index": 1,
        "summary": "Carmy retrains the crew.",
        "Media": [{"Part": [{"file": "/Volumes/Media/media/tv/The.Bear/S01E01.mkv"}]}],
    },
]}}


def fake_get_json(path, params=None):
    if path == "/library/sections":
        return SECTIONS
    if path == "/library/sections/1/all":
        return MOVIES
    if path == "/library/sections/2/all":
        return SHOWS
    if path == "/library/metadata/1262/allLeaves":
        return EPISODES
    raise AssertionError(f"unexpected path {path}")


def test_fetch_library_items(monkeypatch):
    monkeypatch.setattr(plex, "_get_json", fake_get_json)
    items = plex.fetch_library_items()
    assert len(items) == 2

    movie = next(i for i in items if i["classification"] == "movies")
    assert movie == {
        "source_path": "/Volumes/Media/media/movies/Akira/Akira.mkv",
        "title": "Akira",
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": "Neo-Tokyo.",
        "plex_rating_key": "42",
        "show_rating_key": None,
    }

    ep = next(i for i in items if i["classification"] == "tv")
    assert ep == {
        "source_path": "/Volumes/Media/media/tv/The.Bear/S01E01.mkv",
        "title": "System",
        "classification": "tv",
        "show_title": "The Bear",
        "season": 1,
        "episode": 1,
        "summary": "Carmy retrains the crew.",
        "plex_rating_key": "1264",
        "show_rating_key": "1262",
    }


def test_item_without_file_is_skipped(monkeypatch):
    broken = {"MediaContainer": {"Metadata": [{"ratingKey": "9", "title": "NoFile", "Media": []}]}}

    def fake(path, params=None):
        if path == "/library/sections":
            return SECTIONS
        if path == "/library/sections/1/all":
            return broken
        if path == "/library/sections/2/all":
            return {"MediaContainer": {"Metadata": []}}
        raise AssertionError(path)

    monkeypatch.setattr(plex, "_get_json", fake)
    assert plex.fetch_library_items() == []


def test_parse_json_tolerates_control_chars():
    # Plex responses contain raw control characters; strict parsing must be off.
    raw = '{"MediaContainer": {"summary": "line1\x01line2"}}'
    assert plex._parse_json(raw)["MediaContainer"]["summary"] == "line1\x01line2"
