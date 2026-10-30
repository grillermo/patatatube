# scripts/deploy/release.rb
# frozen_string_literal: true

# Pure helpers for ../../deploy: nothing here touches git, Xcode or the network,
# so all of it is unit-tested (scripts/deploy/test/release_test.rb).

module Release
  class UsageError < StandardError; end

  TAG_PREFIX = "patatatube-ota-v"

  # Merge/release/chore noise that says nothing about what changed on the device.
  # "Release iOS v" is the pre-2.7.32 release commit title; keep filtering it.
  NOTE_NOISE = /\A(Release (iOS v|PatataTube OTA )|Merge |Commit pending changes|Bump |wip\b)/i
  MAX_NOTES = 8

  module_function

  # Minimal dotenv: KEY=VALUE lines, "#" comments, optional surrounding quotes.
  # Never overrides a variable already exported in the shell, so a one-off
  # `PATATATUBE_PUBLISH_DIR=/tmp/x ./deploy` beats the file. The .env is shared
  # with the Python backend; this only reads the keys it is asked for later.
  def load_dotenv(path)
    return unless File.exist?(path)

    File.readlines(path).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next unless key && value && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

      ENV[key] ||= value.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  # Repeatable "--flag value" / "--flag=value" options, removed from argv so the
  # version argument stays positional wherever it sits.
  def take_option(argv, *names)
    values = []
    i = 0
    while i < argv.length
      arg = argv[i]
      if names.include?(arg)
        value = argv[i + 1]
        raise UsageError, "#{arg} needs a value" if value.nil? || value.start_with?("--")

        values << value
        argv.slice!(i, 2)
      elsif (eq = arg.match(/\A(--[a-z-]+)=(.*)\z/m)) && names.include?(eq[1])
        values << eq[2]
        argv.slice!(i, 1)
      else
        i += 1
      end
    end
    values
  end

  def clean_notes(raw)
    raw.flat_map { |n| n.split("\n") }
       .map { |n| n.strip.sub(/\A[-*•]\s*/, "") }
       .reject(&:empty?)
  end

  def bump(current, arg)
    return arg if arg.to_s.match?(/\A\d+\.\d+\.\d+\z/)

    major, minor, patch = current.split(".").map(&:to_i)
    case arg
    when "major" then "#{major + 1}.0.0"
    when "minor" then "#{major}.#{minor + 1}.0"
    when "patch", nil then "#{major}.#{minor}.#{patch.to_i + 1}"
    else raise UsageError, "bad argument '#{arg}' (use patch|minor|major or an X.Y.Z version)"
    end
  end

  def tag_for(version) = "#{TAG_PREFIX}#{version}"

  # Releases up to 2.7.31 were tagged plain vX.Y.Z. Still checked so an old
  # version number can never be released a second time.
  def legacy_tag_for(version) = "v#{version}"

  def filter_subjects(subjects)
    subjects.map(&:strip).reject { |s| s.empty? || s.match?(NOTE_NOISE) }.uniq.first(MAX_NOTES)
  end

  def release_notes(version:, summary:, notes:, subjects:, devlog:)
    bullets = notes.empty? ? filter_subjects(subjects) : notes
    headline = summary || (bullets.empty? ? "Release #{version}." : "What's new in #{version}:")
    headline = "[DEVLOG] #{headline}" if devlog
    lines = [headline]
    lines << "" unless bullets.empty?
    lines.concat(bullets.map { |b| "• #{b}" })
    if devlog
      lines << ""
      lines << "Diagnostics build: sends DevLog records to the Mac's devlog server."
    end
    lines.join("\n")
  end

  # project.yml (XcodeGen) is the version's source of truth here; the
  # .xcodeproj is generated and gitignored, so the bump goes into the YAML.
  def bump_project_yml(yml, version:, build:)
    unless yml.match?(/^\s*MARKETING_VERSION:/) && yml.match?(/^\s*CURRENT_PROJECT_VERSION:/)
      raise UsageError, "project.yml needs both MARKETING_VERSION and CURRENT_PROJECT_VERSION"
    end

    yml.sub(/^(\s*MARKETING_VERSION:\s*)"?[\d.]+"?/, "\\1\"#{version}\"")
       .sub(/^(\s*CURRENT_PROJECT_VERSION:\s*)"?\d+"?/, "\\1\"#{build}\"")
  end
end
