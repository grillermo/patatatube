#!/usr/bin/env ruby
# frozen_string_literal: true

# refresh-ipa.rb
#
# Produces a fresh PatataTube .ipa for AltStore and drops it in iCloud
# Downloads — fully unattended. AltStore re-signs the .ipa on-device.
#
# For automated updates over an AltStore *source* (version bump + GitHub
# release + push), use ../deploy instead. This script is the manual "AirDrop
# it once" path.
#
# Usage: ruby ios/refresh-ipa.rb

require_relative "ipa_builder"
require "time"

DEST_DIR = File.expand_path(
  "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
)

FileUtils.mkdir_p(DEST_DIR)

ipa  = IpaBuilder.build
work = File.dirname(ipa)

IpaBuilder.step "Copying to iCloud Downloads"
stamp    = Time.now.strftime("%Y%m%d-%H%M%S")
dest_ipa = File.join(DEST_DIR, "#{IpaBuilder::APP_NAME}-#{stamp}.ipa")
FileUtils.cp(ipa, dest_ipa)
FileUtils.remove_entry(work)

size_mb = (File.size(dest_ipa).to_f / 1_048_576).round(1)
puts IpaBuilder.green("\n✓ Done: #{dest_ipa} (#{size_mb} MB)")
puts "  On the iPad: AltStore -> My Apps -> + -> pick this .ipa from Files (iCloud Drive/Downloads)."
