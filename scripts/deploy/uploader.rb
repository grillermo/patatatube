# scripts/deploy/uploader.rb
# frozen_string_literal: true

# Publishes release artifacts into the files/ directory that file_server
# (files.chiq.me) serves from the macmini.
#
# Publishing is a copy into that directory, not an HTTP upload: request bodies
# over ~12 MB stall in the Cloudflare tunnel and come back as 524s. On the
# macmini it is a local copy; anywhere else (builds moved off the macmini on
# 2026-11-21, whose Xcode 26.3 crashes compiling the Kit in Release) it is an
# scp into the same directory over the LAN, then a rename on the far side.
#
# Every publish is pinned. The artifact lands at exactly the name given and
# overwrites what was there, which is what keeps the manifest and install page
# URLs fixed, so one Home Screen bookmark keeps installing the newest release.

require "fileutils"
require "socket"
require_relative "ipa_builder"

module Uploader
  DEFAULT_PUBLISH_DIR = File.expand_path("../file_server/files", IpaBuilder::REPO_ROOT)
  # Relative to the remote user's home; `~/c/<project>` on every machine.
  DEFAULT_REMOTE_DIR = "c/file_server/files"
  DEFAULT_REMOTE_HOST = "macmini"

  module_function

  # PATATATUBE_UPLOAD_BASE comes from the repo's gitignored .env (loaded by
  # ../../deploy) or the shell.
  def base_url
    base = ENV["PATATATUBE_UPLOAD_BASE"].to_s
    IpaBuilder.die("set PATATATUBE_UPLOAD_BASE (in .env) to the public URL of your file server, e.g. https://files.chiq.me") if base.empty?
    base.sub(%r{/+\z}, "")
  end

  def url_for(name) = "#{base_url}/files/#{name}"

  def publish_dir = ENV.fetch("PATATATUBE_PUBLISH_DIR", DEFAULT_PUBLISH_DIR)

  # The host to publish to over SSH, or nil to copy locally.
  # PATATATUBE_PUBLISH_HOST wins, then an explicit PATATATUBE_PUBLISH_DIR
  # (local). Otherwise it is local only on the macmini itself: other machines
  # have their own ~/c/file_server checkout, but nothing serves it, and the
  # first build off the macmini (2.9.0) published into the immunemac's copy.
  def publish_host
    host = ENV["PATATATUBE_PUBLISH_HOST"].to_s
    return host unless host.empty?
    return nil if ENV.key?("PATATATUBE_PUBLISH_DIR") || local_host == DEFAULT_REMOTE_HOST

    DEFAULT_REMOTE_HOST
  end

  def local_host = Socket.gethostname.split(".").first.to_s.downcase

  def remote_dir = ENV.fetch("PATATATUBE_PUBLISH_REMOTE_DIR", DEFAULT_REMOTE_DIR)

  # Runs argv, dying with `what` on failure. Swappable in tests.
  def run!(argv, what)
    IpaBuilder.die("#{what} failed: #{argv.join(" ")}") unless system(*argv)
  end

  SSH_OPTS = %w[-o BatchMode=yes -o ConnectTimeout=15].freeze

  # Where releases land, for messages: a local path or host:path.
  def publish_label
    host = publish_host
    host ? "#{host}:#{remote_dir}" : publish_dir
  end

  # Whether `name` is already published (a version must never be overwritten).
  def published?(name)
    host = publish_host
    return File.exist?(File.join(publish_dir, name)) unless host

    system("ssh", *SSH_OPTS, host, "test -e '#{remote_dir}/#{name}'")
  end

  # Dies unless the publish target exists. Returns publish_label.
  def check_publish_dir!
    if (host = publish_host)
      return publish_label if system("ssh", *SSH_OPTS, host, "test -d '#{remote_dir}'")

      IpaBuilder.die("#{publish_label} is not a directory, or #{host} is unreachable over SSH.")
    end

    dir = publish_dir
    return dir if File.directory?(dir)

    IpaBuilder.die(
      "the file_server files/ directory was not found at #{dir}.\n" \
      "  Releases are published by writing into it, because the service serving\n" \
      "  #{base_url} runs on this machine. Set PATATATUBE_PUBLISH_DIR if it moved."
    )
  end

  # Publishes `path` under exactly `name` and returns its public URL. It copies
  # beside the target and renames, so a device downloading a fixed URL never
  # gets a half-written file.
  def upload(path, name:)
    IpaBuilder.die("file to publish not found: #{path}") unless File.file?(path)
    IpaBuilder.die("unsafe publish name: #{name.inspect}") unless name == File.basename(name)

    host = publish_host
    return upload_remote(path, name: name, host: host) if host

    target = File.join(check_publish_dir!, name)
    staged = "#{target}.publishing-#{Process.pid}"
    begin
      FileUtils.cp(path, staged)
      File.rename(staged, target)
    ensure
      FileUtils.rm_f(staged)
    end
    url_for(name)
  end

  # Same staged-copy-then-rename as the local path, across SSH. Names were
  # already checked to be bare filenames, so they are safe to put in a path.
  def upload_remote(path, name:, host:)
    target = "#{remote_dir}/#{name}"
    staged = "#{target}.publishing-#{Process.pid}"
    run!(["scp", "-q", *SSH_OPTS, path, "#{host}:#{staged}"], "publishing #{name} to #{host}")
    run!(["ssh", *SSH_OPTS, host, "mv -f '#{staged}' '#{target}'"], "renaming #{name} on #{host}")
    url_for(name)
  end
end
