#!/usr/bin/env ruby
# frozen_string_literal: true

# refresh-ipa.rb
#
# Automates the boring parts of producing a fresh PatataTube .ipa for AltStore
# and drops it in iCloud Downloads. Delegates the one step that needs a human in
# Xcode (Product -> Archive, which needs interactive free-Apple-ID signing).
#
# Flow:
#   1. xcodegen generate            (auto)
#   2. YOU: Product -> Archive       (manual, in Xcode)
#   3. extract .app from newest .xcarchive, package into .ipa  (auto)
#   4. copy .ipa to iCloud Downloads (auto)
#
# Usage: ruby ios/refresh-ipa.rb

require "fileutils"
require "shellwords"
require "tmpdir"
require "time"

APP_NAME     = "PatataTube"
PROJECT_DIR  = File.join(__dir__, APP_NAME)                     # ios/PatataTube
ARCHIVES_DIR = File.expand_path("~/Library/Developer/Xcode/Archives")
DEST_DIR     = File.expand_path(
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

# Newest *.xcarchive for this app, or nil.
def latest_archive
  Dir.glob(File.join(ARCHIVES_DIR, "*", "#{APP_NAME}*.xcarchive"))
     .max_by { |p| File.mtime(p) }
end

# --- preflight -------------------------------------------------------------

die("no xcodegen on PATH (brew install xcodegen)") if `which xcodegen`.empty?
die("project dir not found: #{PROJECT_DIR}") unless Dir.exist?(PROJECT_DIR)
FileUtils.mkdir_p(DEST_DIR)

# --- 1. regenerate the Xcode project --------------------------------------

step "Regenerating Xcode project (xcodegen)"
run("xcodegen generate", chdir: PROJECT_DIR)

# Remember the newest archive *before* you touch Xcode, so we can detect the
# new one you're about to create.
archive_before = latest_archive
before_mtime   = archive_before ? File.mtime(archive_before) : Time.at(0)

# --- 2. delegate the archive step -----------------------------------------

step "Manual step: create the archive in Xcode"
puts <<~INSTRUCTIONS
    Xcode is about to open. Then:
      1. Scheme #{bold(APP_NAME)} -> destination: #{bold("Any iOS Device (arm64)")}.
      2. #{bold("Product -> Archive")}.
      3. Wait for the Organizer window to appear (archive done).

    Do #{bold("NOT")} click "Distribute App" — free Apple ID can't. This script
    packages the .ipa for you once the archive exists.
INSTRUCTIONS

run("open #{APP_NAME}.xcodeproj", chdir: PROJECT_DIR)

print yellow("\nPress ENTER once the archive has finished building... ")
$stdin.gets

# --- 3. locate the fresh archive ------------------------------------------

step "Locating the new archive"
archive = latest_archive
die("no #{APP_NAME} archive found under #{ARCHIVES_DIR}") unless archive

if File.mtime(archive) <= before_mtime
  puts yellow("    Warning: newest archive isn't newer than before you started:")
  puts yellow("      #{archive}")
  puts yellow("    (Archive may have failed, or you didn't archive.)")
  print yellow("    Use it anyway? [y/N] ")
  die("aborted — no fresh archive") unless $stdin.gets.strip.casecmp?("y")
end
puts green("    Using: #{archive}")

app_path = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
die("no #{APP_NAME}.app inside archive: #{app_path}") unless Dir.exist?(app_path)

# --- 4. package into an .ipa ----------------------------------------------

step "Packaging .ipa"
work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
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

# --- 5. copy to iCloud Downloads ------------------------------------------

step "Copying to iCloud Downloads"
stamp     = Time.now.strftime("%Y%m%d-%H%M%S")
dest_ipa  = File.join(DEST_DIR, "#{APP_NAME}-#{stamp}.ipa")
FileUtils.cp(ipa, dest_ipa)
FileUtils.remove_entry(work)

size_mb = (File.size(dest_ipa).to_f / 1_048_576).round(1)
puts green("\n✓ Done: #{dest_ipa} (#{size_mb} MB)")
puts "  On the iPad: AltStore -> My Apps -> + -> pick this .ipa from Files (iCloud Drive/Downloads)."
