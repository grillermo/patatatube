# scripts/deploy/test/uploader_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../uploader"

class UploaderTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @saved = ENV.to_h.slice("PATATATUBE_UPLOAD_BASE", "PATATATUBE_PUBLISH_DIR")
    ENV["PATATATUBE_UPLOAD_BASE"] = "https://files.example/"
    ENV["PATATATUBE_PUBLISH_DIR"] = @dir
  end

  def teardown
    %w[PATATATUBE_UPLOAD_BASE PATATATUBE_PUBLISH_DIR].each { |k| @saved.key?(k) ? ENV[k] = @saved[k] : ENV.delete(k) }
    FileUtils.remove_entry(@dir)
  end

  def test_base_url_strips_trailing_slash_and_builds_file_urls
    assert_equal "https://files.example", Uploader.base_url
    assert_equal "https://files.example/files/a.png", Uploader.url_for("a.png")
  end

  def test_base_url_is_required
    ENV["PATATATUBE_UPLOAD_BASE"] = ""
    assert_raises(SystemExit) { capture_io { Uploader.base_url } }
  end

  def test_upload_replaces_target_atomically_and_leaves_no_staging_file
    src = File.join(@dir, "src.txt")
    File.write(src, "new")
    File.write(File.join(@dir, "pinned.txt"), "old")
    assert_equal "https://files.example/files/pinned.txt", Uploader.upload(src, name: "pinned.txt")
    assert_equal "new", File.read(File.join(@dir, "pinned.txt"))
    assert_empty Dir.glob(File.join(@dir, "*.publishing-*"))
  end

  def test_upload_rejects_path_names
    src = File.join(@dir, "src.txt")
    File.write(src, "x")
    assert_raises(SystemExit) { capture_io { Uploader.upload(src, name: "../evil.txt") } }
  end

  def test_missing_publish_dir_dies
    ENV["PATATATUBE_PUBLISH_DIR"] = File.join(@dir, "nope")
    assert_raises(SystemExit) { capture_io { Uploader.check_publish_dir! } }
  end
end
