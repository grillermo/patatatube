#!/usr/bin/env ruby
# frozen_string_literal: true

# refresh-ipa.rb
#
# Produces a fresh PatataTube .ipa for AltStore and drops it in iCloud
# Downloads — fully unattended. AltStore re-signs the .ipa on-device, so the
# archive is built with automatic (free Apple ID) signing baked into project.yml
# (DEVELOPMENT_TEAM / CODE_SIGN_STYLE); no Distribute step is needed.
#
# Flow (all automatic):
#   1. xcodegen generate
#   2. xcodebuild ... archive   (headless, generic/platform=iOS)
#   3. extract .app from the archive, package into .ipa
#   4. copy .ipa to iCloud Downloads
#
# Usage: ruby ios/refresh-ipa.rb

require "fileutils"
require "shellwords"
require "tmpdir"
require "time"

APP_NAME    = "PatataTube"
SCHEME      = "PatataTube"
PROJECT_DIR = File.join(__dir__, APP_NAME)                     # ios/PatataTube
PROJECT     = "#{APP_NAME}.xcodeproj"
DEST_DIR    = File.expand_path(
  "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
)

def bold(str) = "\e[1m#{str}\e[0m"
def green(str) = "\e[32m#{str}\e[0m"
def yellow(str) = "\e[33m#{str}\e[0m"
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

# --- preflight -------------------------------------------------------------

die("no xcodegen on PATH (brew install xcodegen)") if `which xcodegen`.empty?
die("project dir not found: #{PROJECT_DIR}") unless Dir.exist?(PROJECT_DIR)
FileUtils.mkdir_p(DEST_DIR)

ENV["DEVELOPER_DIR"] = resolve_developer_dir
puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

# --- 1. regenerate the Xcode project --------------------------------------

step "Regenerating Xcode project (xcodegen)"
run("xcodegen generate", chdir: PROJECT_DIR)

# --- 2. archive (headless) ------------------------------------------------

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

# --- 3. package into an .ipa ----------------------------------------------

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

# --- 4. copy to iCloud Downloads ------------------------------------------

step "Copying to iCloud Downloads"
stamp     = Time.now.strftime("%Y%m%d-%H%M%S")
dest_ipa  = File.join(DEST_DIR, "#{APP_NAME}-#{stamp}.ipa")
FileUtils.cp(ipa, dest_ipa)
FileUtils.remove_entry(work)

size_mb = (File.size(dest_ipa).to_f / 1_048_576).round(1)
puts green("\n✓ Done: #{dest_ipa} (#{size_mb} MB)")
puts "  On the iPad: AltStore -> My Apps -> + -> pick this .ipa from Files (iCloud Drive/Downloads)."
