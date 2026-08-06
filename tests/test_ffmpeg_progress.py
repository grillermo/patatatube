import os
import stat
import pytest

import ffmpeg_progress


def test_parse_progress_line_reads_out_time_us():
    assert ffmpeg_progress.parse_progress_line("out_time_us=1500000") == 1_500_000


def test_parse_progress_line_reads_out_time_ms_as_microseconds():
    # ffmpeg's out_time_ms is microseconds despite the name; older builds emit
    # only that key, so it is the fallback, not a millisecond conversion.
    assert ffmpeg_progress.parse_progress_line("out_time_ms=2000000") == 2_000_000


def test_parse_progress_line_ignores_other_keys_and_garbage():
    assert ffmpeg_progress.parse_progress_line("frame=120") is None
    assert ffmpeg_progress.parse_progress_line("out_time_us=N/A") is None
    assert ffmpeg_progress.parse_progress_line("") is None


def test_probe_duration_reads_format_duration():
    assert ffmpeg_progress.probe_duration({"format": {"duration": "42.5"}}) == 42.5


def test_probe_duration_is_zero_when_missing_or_bad():
    assert ffmpeg_progress.probe_duration({}) == 0.0
    assert ffmpeg_progress.probe_duration({"format": {"duration": "N/A"}}) == 0.0


def test_throttle_emits_first_value_then_only_on_delta():
    seen = []
    clock = [0.0]
    throttle = ffmpeg_progress.ProgressThrottle(seen.append, now=lambda: clock[0])
    throttle.emit(0.0)      # first value always goes out
    throttle.emit(0.005)    # +0.5%, too small, too soon
    throttle.emit(0.02)     # +2%, over the 1% delta
    assert seen == [0.0, 0.02]


def test_throttle_emits_on_interval_even_without_delta():
    seen = []
    clock = [0.0]
    throttle = ffmpeg_progress.ProgressThrottle(seen.append, now=lambda: clock[0])
    throttle.emit(0.0)
    clock[0] = 2.5
    throttle.emit(0.001)
    assert seen == [0.0, 0.001]


def test_throttle_flush_always_emits():
    seen = []
    throttle = ffmpeg_progress.ProgressThrottle(seen.append, now=lambda: 0.0)
    throttle.emit(0.0)
    throttle.flush(1.0)
    assert seen == [0.0, 1.0]


def _fake_binary(tmp_path, script: str):
    path = tmp_path / "fake_ffmpeg"
    path.write_text("#!/bin/sh\n" + script)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


def test_run_ffmpeg_reports_fractions_from_stdout(tmp_path):
    # The fake ignores the -progress flags appended to its argv and just emits
    # what real ffmpeg would emit on stdout.
    binary = _fake_binary(tmp_path, """
echo "frame=1"
echo "out_time_us=5000000"
echo "out_time_us=10000000"
echo "progress=end"
""")
    seen = []
    ffmpeg_progress.run_ffmpeg([binary], duration=20.0, on_progress=seen.append)
    assert seen[0] == pytest.approx(0.25)
    assert seen[-1] == pytest.approx(1.0)


def test_run_ffmpeg_clamps_fraction_to_one(tmp_path):
    binary = _fake_binary(tmp_path, 'echo "out_time_us=30000000"\n')
    seen = []
    ffmpeg_progress.run_ffmpeg([binary], duration=10.0, on_progress=seen.append)
    assert max(seen) == 1.0


def test_run_ffmpeg_appends_progress_flags_only_when_wanted(tmp_path):
    binary = _fake_binary(tmp_path, 'echo "ARGS:$@"\n')
    seen_args = []
    ffmpeg_progress.run_ffmpeg(
        [binary], duration=10.0, on_progress=lambda _f: None,
        _debug_line_sink=seen_args.append,
    )
    assert "-progress pipe:1 -nostats" in seen_args[0]

    seen_args.clear()
    ffmpeg_progress.run_ffmpeg([binary], _debug_line_sink=seen_args.append)
    assert seen_args[0] == "ARGS:"


def test_run_ffmpeg_raises_with_stderr_text_on_failure(tmp_path):
    binary = _fake_binary(tmp_path, 'echo "boom: bad codec" 1>&2\nexit 1\n')
    with pytest.raises(RuntimeError) as excinfo:
        ffmpeg_progress.run_ffmpeg([binary])
    assert "boom: bad codec" in str(excinfo.value)


def test_run_ffmpeg_raises_generic_message_when_stderr_is_empty(tmp_path):
    binary = _fake_binary(tmp_path, "exit 1\n")
    with pytest.raises(RuntimeError) as excinfo:
        ffmpeg_progress.run_ffmpeg([binary])
    assert "ffmpeg failed" in str(excinfo.value)


def test_run_ffmpeg_survives_a_flood_of_stderr(tmp_path):
    # A full stderr pipe must not deadlock the stdout reader, and the message
    # must stay bounded.
    binary = _fake_binary(tmp_path, 'i=0\nwhile [ $i -lt 5000 ]; do echo "line $i" 1>&2; i=$((i+1)); done\nexit 1\n')
    with pytest.raises(RuntimeError) as excinfo:
        ffmpeg_progress.run_ffmpeg([binary])
    message = str(excinfo.value)
    assert "line 4999" in message
    assert len(message.splitlines()) <= 50
