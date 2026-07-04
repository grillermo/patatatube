# frozen_string_literal: true

# ipa_builder.rb
#
# Shared build logic for producing a PatataTube .ipa from source. Used by both
# refresh-ipa.rb (drops the .ipa in iCloud for manual sideload) and ../deploy
# (publishes it to an AltStore source).
#
# AltStore re-signs the .ipa on-device, so the archive is built with automatic
# (free Apple ID) signing baked into project.yml (DEVELOPMENT_TEAM /
# CODE_SIGN_STYLE); no Distribute step is needed.

require "fileutils"
require "shellwords"
require "tmpdir"

module IpaBuilder
  APP_NAME    = "PatataTube"
  SCHEME      = "PatataTube"
  PROJECT_DIR = File.join(__dir__, APP_NAME)          # ios/PatataTube
  PROJECT     = "#{APP_NAME}.xcodeproj"
  PROJECT_YML = File.join(PROJECT_DIR, "project.yml")

  module_function

  def bold(str) = "\e[1m#{str}\e[0m"
  def green(str) = "\e[32m#{str}\e[0m"
  def red(str) = "\e[31m#{str}\e[0m"
  def step(msg) = puts "\n#{bold("==> #{msg}")}"

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:)
    puts "    $ #{cmd}"
    system(cmd, chdir: chdir) or die("command failed: #{cmd}")
  end

  # xcodebuild needs a full Xcode, not the Command Line Tools. Honour an existing
  # DEVELOPER_DIR, otherwise point at the newest /Applications/Xcode*.app.
  def resolve_developer_dir
    env = ENV["DEVELOPER_DIR"]
    return env if env && Dir.exist?(env)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    die("no Xcode.app found; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  # MARKETING_VERSION out of project.yml (source of truth for the app version).
  def marketing_version
    m = File.read(PROJECT_YML).match(/^\s*MARKETING_VERSION:\s*"?([\d.]+)"?/)
    die("no MARKETING_VERSION in #{PROJECT_YML}") unless m
    m[1]
  end

  # Build the .ipa from source and return its path (inside a fresh tmp dir the
  # caller is responsible for cleaning up). Steps: xcodegen -> archive -> package.
  def build
    die("no xcodegen on PATH (brew install xcodegen)") if `which xcodegen`.empty?
    die("project dir not found: #{PROJECT_DIR}") unless Dir.exist?(PROJECT_DIR)

    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    step "Regenerating Xcode project (xcodegen)"
    run("xcodegen generate", chdir: PROJECT_DIR)

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{APP_NAME}.xcarchive")

    step "Archiving (xcodebuild)"
    run(
      "xcodebuild " \
      "-project #{Shellwords.escape(PROJECT)} " \
      "-scheme #{Shellwords.escape(SCHEME)} " \
      "-configuration Release " \
      "-destination 'generic/platform=iOS' " \
      "-archivePath #{Shellwords.escape(archive)} " \
      "-allowProvisioningUpdates " \
      "archive",
      chdir: PROJECT_DIR
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)
    puts green("    Built: #{archive}")

    app_path = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    die("no #{APP_NAME}.app inside archive: #{app_path}") unless Dir.exist?(app_path)

    step "Packaging .ipa"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app_path, payload)   # Payload/PatataTube.app

    ipa = File.join(work, "#{APP_NAME}.ipa")
    # ditto --keepParent keeps the Payload/ dir at the archive root and preserves
    # the symlinks inside embedded frameworks (plain zip can mangle them).
    run(
      "ditto -c -k --sequesterRsrc --keepParent " \
      "#{Shellwords.escape(payload)} #{Shellwords.escape(ipa)}",
      chdir: work
    )

    ipa
  end
end
