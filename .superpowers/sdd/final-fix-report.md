# Final review fixes — 2026-07-19

## Review findings resolved

1. **P1: Reconversion output collision**
   - `convert_library_video` now gives `conversion_target` the chosen version's
     tracked `converted_path`. Reconversions therefore write a hidden temporary
     sibling and atomically replace that same owned output instead of producing
     an untracked `.ios.mp4` sibling.
   - Regression: `test_reconversion_replaces_the_tracked_output` verifies the
     original output is replaced and no `.ios.mp4` is left for a later scan to
     import.

2. **P1: Multi-audio passthrough compatibility**
   - Passthrough now requires every selected audio stream to be compatible.
     If any selected stream (for example DTS) is incompatible, normal conversion
     transcodes only that output audio stream.
   - Regression: `test_passthrough_transcodes_a_selected_incompatible_audio_stream`.

3. **P2: Invalid audio selection after version switch**
   - `set_chosen_version` validates the saved `audio_lang` against the new
     version's discovered tracks and clears it when unavailable. The serialized
     UI/API value therefore cannot retain an invalid selected language.
   - Regression: `test_changing_version_clears_audio_lang_missing_from_new_version`.

## TDD evidence

The three focused regressions were added before production changes and were
observed failing for their intended reasons: passthrough incorrectly returned
true for selected DTS, reconversion preserved the old target, and `audio_lang`
remained `eng` after switching to a Spanish-only version. After the minimal
implementation changes, all three passed.

## Verification

- Focused regressions:
  `python -m pytest tests/test_library.py::test_passthrough_transcodes_a_selected_incompatible_audio_stream tests/test_library.py::test_reconversion_replaces_the_tracked_output tests/test_db.py::test_changing_version_clears_audio_lang_missing_from_new_version -q`
  — **3 passed**.
- Full project test suite:
  `python -m pytest tests -q` — **242 passed**.
- `git diff --check` — clean.

The pre-existing test virtualenv was missing declared `Jinja2` and
`python-multipart`; installing those two declared requirements enabled API
collection. Installing the complete requirements file could not build the
unrelated `watchfiles==0.24.0` on Python 3.14 because its PyO3 dependency only
supports Python through 3.13; the test suite does not require `watchfiles` and
passed after the two required packages were installed.
