# Task 7: Audio-aware prepare endpoint

`POST /api/videos/{id}/prepare` now accepts an optional `audio_lang` JSON field.
It remains Bearer-token gated and preserves the legacy empty-body readiness
behavior. For an explicit language it verifies that the language is both in
`LIBRARY_AUDIO_LANGS` and present in the chosen version's source tracks, stores
the choice, and invalidates the video's HLS package when the choice changes.

Completed conversions are returned as done only when their recorded
`converted_langs` contains every track required by the current conversion
plan. Legacy conversions without that metadata, or conversions missing an
allowlisted source track, are requeued. Passthrough files instead have their
source-track metadata recorded without a needless conversion.

TDD: the three new tests initially failed against the prior endpoint: it did
not save an audio selection, did not reject invalid languages, and did not
requeue a legacy conversion. They pass after the implementation.

Verification (required interpreter):

```
/Users/grillermo/c/patatatube/python_env/bin/python -m pytest tests/test_api.py -v -k 'prepare or single'
# 14 passed, 76 deselected

/Users/grillermo/c/patatatube/python_env/bin/python -m pytest tests/
# 234 passed
```
