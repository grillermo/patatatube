# scripts/deploy/test/release_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../release"

class ReleaseTest < Minitest::Test
  def test_bump_patch_minor_major_and_explicit
    assert_equal "2.7.29", Release.bump("2.7.28", nil)
    assert_equal "2.7.29", Release.bump("2.7.28", "patch")
    assert_equal "2.8.0", Release.bump("2.7.28", "minor")
    assert_equal "3.0.0", Release.bump("2.7.28", "major")
    assert_equal "4.1.2", Release.bump("2.7.28", "4.1.2")
  end

  def test_bump_rejects_garbage
    assert_raises(Release::UsageError) { Release.bump("2.7.28", "huge") }
  end

  def test_tags
    assert_equal "patatatube-ota-v2.7.29", Release.tag_for("2.7.29")
    assert_equal "v2.7.29", Release.legacy_tag_for("2.7.29")
  end

  def test_take_option_pulls_values_anywhere_and_keeps_positionals
    argv = ["minor", "--note", "a", "--note=b", "-s", "head"]
    assert_equal %w[a b], Release.take_option(argv, "--note", "-n")
    assert_equal ["head"], Release.take_option(argv, "--summary", "-s")
    assert_equal ["minor"], argv
  end

  def test_take_option_needs_a_value
    assert_raises(Release::UsageError) { Release.take_option(["--note"], "--note") }
    assert_raises(Release::UsageError) { Release.take_option(["--note", "--yes"], "--note") }
  end

  def test_clean_notes_strips_bullets_and_splits_lines
    assert_equal %w[one two three], Release.clean_notes(["- one\n* two", "  • three ", "   "])
  end

  def test_filter_subjects_drops_noise_dedupes_and_caps_at_eight
    noise = ["Release iOS v2.7.28", "Release PatataTube OTA patatatube-ota-v2.7.29",
             "Merge branch x", "Bump rack", "wip stuff", "Commit pending changes before iOS deploy", ""]
    real = (1..10).map { |i| "feat: thing #{i}" }
    out = Release.filter_subjects(noise + ["feat: thing 1"] + real)
    assert_equal (1..8).map { |i| "feat: thing #{i}" }, out
  end

  def test_release_notes_from_explicit_notes
    text = Release.release_notes(version: "2.7.29", summary: "Faster", notes: %w[a b], subjects: ["ignored"], devlog: false)
    assert_equal "Faster\n\n• a\n• b", text
  end

  def test_release_notes_from_subjects_and_devlog_marker
    text = Release.release_notes(version: "2.7.29", summary: nil, notes: [], subjects: ["feat: x"], devlog: true)
    assert_equal "[DEVLOG] What's new in 2.7.29:\n\n• feat: x\n\nDiagnostics build: sends DevLog records to the Mac's devlog server.", text
  end

  def test_release_notes_with_nothing
    assert_equal "Release 2.7.29.", Release.release_notes(version: "2.7.29", summary: nil, notes: [], subjects: [], devlog: false)
  end

  def test_bump_project_yml
    yml = "        MARKETING_VERSION: \"2.7.28\"\n        CURRENT_PROJECT_VERSION: \"210\"\n"
    out = Release.bump_project_yml(yml, version: "2.7.29", build: 211)
    assert_equal "        MARKETING_VERSION: \"2.7.29\"\n        CURRENT_PROJECT_VERSION: \"211\"\n", out
  end

  def test_bump_project_yml_requires_both_keys
    assert_raises(Release::UsageError) { Release.bump_project_yml("MARKETING_VERSION: \"1.0.0\"\n", version: "1.0.1", build: 2) }
  end

  def test_load_dotenv_never_overrides_exported_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "# c\nRELEASE_TEST_A=from_file\nRELEASE_TEST_B=\"quoted\"\n\nnot a pair\n")
      ENV["RELEASE_TEST_A"] = "exported"
      ENV.delete("RELEASE_TEST_B")
      Release.load_dotenv(path)
      assert_equal "exported", ENV["RELEASE_TEST_A"]
      assert_equal "quoted", ENV["RELEASE_TEST_B"]
    ensure
      ENV.delete("RELEASE_TEST_A")
      ENV.delete("RELEASE_TEST_B")
    end
  end

  def test_load_dotenv_missing_file_is_fine
    Release.load_dotenv("/nonexistent/.env")
  end
end
