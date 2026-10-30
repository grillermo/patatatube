# scripts/deploy/uploader.rb
# frozen_string_literal: true

# Publishes release artifacts into the files/ directory that file_server
# (files.chiq.me) serves from this machine.
#
# Publishing is a copy into that directory, not an HTTP upload: request bodies
# over ~12 MB stall in the Cloudflare tunnel and come back as 524s.
#
# Every publish is pinned. The artifact lands at exactly the name given and
# overwrites what was there, which is what keeps the manifest and install page
# URLs fixed, so one Home Screen bookmark keeps installing the newest release.

require "fileutils"
require_relative "ipa_builder"

module Uploader
  DEFAULT_PUBLISH_DIR = File.expand_path("../file_server/files", IpaBuilder::REPO_ROOT)

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

  def check_publish_dir!
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
end
