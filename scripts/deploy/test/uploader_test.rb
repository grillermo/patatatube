# scripts/deploy/test/uploader_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../uploader"

class UploaderTest < Minitest::Test
  KEYS = %w[PATATATUBE_UPLOAD_BASE PATATATUBE_PUBLISH_DIR PATATATUBE_PUBLISH_HOST
            PATATATUBE_PUBLISH_REMOTE_DIR].freeze

  def setup
    @dir = Dir.mktmpdir
    @saved = ENV.to_h.slice(*KEYS)
    ENV["PATATATUBE_UPLOAD_BASE"] = "https://files.example/"
    ENV["PATATATUBE_PUBLISH_DIR"] = @dir
    ENV.delete("PATATATUBE_PUBLISH_HOST")
    ENV.delete("PATATATUBE_PUBLISH_REMOTE_DIR")
  end

  # Minitest 6 dropped minitest/mock; swap a module function by hand.
  def with_stub(name, impl)
    original = Uploader.method(name)
    Uploader.define_singleton_method(name, &impl)
    yield
  ensure
    Uploader.define_singleton_method(name, original)
  end

  def teardown
    KEYS.each { |k| @saved.key?(k) ? ENV[k] = @saved[k] : ENV.delete(k) }
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

  def test_explicit_publish_dir_means_local
    assert_nil Uploader.publish_host
  end

  def test_publish_host_env_wins
    ENV["PATATATUBE_PUBLISH_HOST"] = "box"
    assert_equal "box", Uploader.publish_host
  end

  def test_no_local_checkout_defaults_to_the_macmini
    ENV.delete("PATATATUBE_PUBLISH_DIR")
    missing = File.join(@dir, "missing")
    with_stub(:default_publish_dir, -> { missing }) do
      assert_equal "macmini", Uploader.publish_host
    end
  end

  def test_remote_upload_stages_then_renames
    ENV["PATATATUBE_PUBLISH_HOST"] = "box"
    ENV["PATATATUBE_PUBLISH_REMOTE_DIR"] = "c/files"
    src = File.join(@dir, "src.txt")
    File.write(src, "x")
    calls = []
    with_stub(:run!, ->(argv, _what) { calls << argv }) do
      assert_equal "https://files.example/files/a.ipa", Uploader.upload(src, name: "a.ipa")
    end
    scp, ssh = calls
    assert_equal "scp", scp.first
    assert_equal src, scp[-2]
    assert_match %r{\Abox:c/files/a\.ipa\.publishing-\d+\z}, scp.last
    assert_equal "ssh", ssh.first
    assert_equal "box", ssh[-2]
    assert_match %r{\Amv -f 'c/files/a\.ipa\.publishing-\d+' 'c/files/a\.ipa'\z}, ssh.last
  end
end
