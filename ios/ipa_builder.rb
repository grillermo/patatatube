# frozen_string_literal: true

# ipa_builder.rb
#
# Shared build logic for producing a PatataTube .ipa from source. Used by both
# refresh-ipa.rb (drops the .ipa in iCloud for manual sideload) and ../deploy
# (publishes it to a GitHub release + the AltStore source).
#
# The .ipa is signed **ad hoc** with the paid Apple Developer Program team in
# project.yml's DEVELOPMENT_TEAM. That is what lets iOS install it straight
# from Safari over an `itms-services://` link — no AltStore, no AltServer, and
# a signature good for a year instead of the free tier's 7 days. The price is
# that an Ad Hoc profile only covers **devices registered on the portal**: a
# phone whose UDID was added after this .ipa was built cannot install it, so
# adding a device means registering it and then re-running ../deploy.
#
# Set PATATATUBE_UNSIGNED=1 to fall back to the old unsigned archive (AltStore
# re-signs on-device, so that path still works). Useful if signing breaks and a
# release still has to go out.

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

  def unsigned? = ENV["PATATATUBE_UNSIGNED"] == "1"

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

  # The Apple Developer team the .ipa is signed for. project.yml is the source
  # of truth — it is what xcodegen writes into the project, so a build and this
  # export can never disagree. PATATATUBE_TEAM_ID overrides it for a one-off.
  def team_id
    id = ENV["PATATATUBE_TEAM_ID"] ||
         File.read(PROJECT_YML)[/^\s*DEVELOPMENT_TEAM:\s*"?([A-Z0-9]+)"?/, 1]
    die("no DEVELOPMENT_TEAM in #{PROJECT_YML} and no PATATATUBE_TEAM_ID set") unless id
    id
  end

  def xml_escape(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # ExportOptions.plist for `xcodebuild -exportArchive`.
  #
  # `release-testing` re-signs the archive with the team's *distribution*
  # certificate against an Ad Hoc provisioning profile, which embeds the UDIDs
  # registered on the portal. It is Xcode 15.3+'s name for what used to be
  # `ad-hoc`; that older spelling still works but xcodebuild now warns on it.
  #
  # Automatic signing will create the certificate and the profile on its own,
  # but it will NOT create the App ID: "Automatic signing cannot register bundle
  # identifiers with Apple." So PRODUCT_BUNDLE_IDENTIFIER must already exist as
  # an Identifier on the portal or the export fails with "No profiles for
  # 'com.patatatube.app' were found". Archiving does not hit this, because it is
  # happy with the team's wildcard development profile — only distribution needs
  # the explicit App ID. See ios/install.md.
  #
  # The `manifest` dict is why we export at all rather than zipping a Payload/
  # by hand: it makes xcodebuild emit the `manifest.plist` that an
  # `itms-services://` link points at, so the OTA manifest can never drift from
  # the binary it describes. Its appURL must be the .ipa's final public URL,
  # which the caller knows before the build — the GitHub release asset URL is
  # derived from the version being released.
  #
  # thinning `<none>` keeps it one universal .ipa; a thinned export produces
  # per-device variants that a single download URL cannot serve.
  def export_options_plist(path, manifest:)
    entries = [
      "<key>method</key><string>release-testing</string>",
      "<key>teamID</key><string>#{xml_escape(team_id)}</string>",
      "<key>signingStyle</key><string>automatic</string>",
      "<key>stripSwiftSymbols</key><true/>",
      "<key>thinning</key><string>&lt;none&gt;</string>",
      "<key>destination</key><string>export</string>",
    ]

    if manifest
      entries << <<~PLIST.chomp
        <key>manifest</key>
        <dict>
          <key>appURL</key><string>#{xml_escape(manifest[:app_url])}</string>
          <key>displayImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
          <key>fullSizeImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
        </dict>
      PLIST
    end

    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      #{entries.join("\n")}
      </dict>
      </plist>
    PLIST
    path
  end

  # Build the .ipa from source and return its path. It sits in a fresh tmp dir
  # the caller owns and must clean up; when `manifest:` is given, the OTA
  # `manifest.plist` is written **as a sibling** of the .ipa in that same dir,
  # so `File.dirname(ipa)` covers both and one remove_entry cleans up.
  #
  # `manifest:` is `{app_url:, icon_url:}` — the public URLs the .ipa and its
  # icon will live at once published. Omit it for a build nobody installs OTA.
  #
  # `instrumented: true` compiles in DevLog (see
  # ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift) by defining the DEVLOG
  # condition. It goes on the xcodebuild command line because that is the only
  # place that reaches BOTH the app target and the PatataTubeKit SwiftPM package
  # — a project-level setting does not reach the package, and most of the
  # instrumented code (CacheManager, StreamProxy) lives there.
  #
  # DEVLOG is deliberately independent of Debug/Release: the build that has to
  # be instrumented is the Release .ipa that gets installed on the iPad.
  def build(instrumented: false, manifest: nil)
    die("no xcodegen on PATH (brew install xcodegen)") if `which xcodegen`.empty?
    die("project dir not found: #{PROJECT_DIR}") unless Dir.exist?(PROJECT_DIR)

    if instrumented
      puts "\n#{red(bold('  ⚠  INSTRUMENTED BUILD — DEVLOG active'))}"
      puts "     The app will post runtime logs to the backend (POST /api/devlog)."
      puts "     Ship a clean build over it when you are done debugging.\n\n"
    end

    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    step "Regenerating Xcode project (xcodegen)"
    run("xcodegen generate", chdir: PROJECT_DIR)

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{APP_NAME}.xcarchive")

    devlog = instrumented ? "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG' " : ""
    # Unsigned archives skip signing entirely; signed ones let Xcode fetch or
    # create the certificate and profile it needs (-allowProvisioningUpdates).
    signing = unsigned? ? "CODE_SIGNING_ALLOWED=NO " : "DEVELOPMENT_TEAM=#{team_id} "

    step "Archiving (xcodebuild)#{instrumented ? ' [DEVLOG]' : ''}#{unsigned? ? ' [UNSIGNED]' : ''}"
    run(
      "xcodebuild " \
      "-project #{Shellwords.escape(PROJECT)} " \
      "-scheme #{Shellwords.escape(SCHEME)} " \
      "-configuration Release " \
      "-destination 'generic/platform=iOS' " \
      "-archivePath #{Shellwords.escape(archive)} " \
      "#{signing}" \
      "#{devlog}" \
      "-allowProvisioningUpdates " \
      "archive",
      chdir: PROJECT_DIR
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)
    puts green("    Built: #{archive}")

    return package_unsigned(archive, work) if unsigned?

    step "Exporting signed .ipa (ad hoc)"
    options = export_options_plist(File.join(work, "ExportOptions.plist"), manifest: manifest)
    run(
      "xcodebuild -exportArchive " \
      "-archivePath #{Shellwords.escape(archive)} " \
      "-exportPath #{Shellwords.escape(work)} " \
      "-exportOptionsPlist #{Shellwords.escape(options)} " \
      "-allowProvisioningUpdates",
      chdir: PROJECT_DIR
    )

    ipa = File.join(work, "#{APP_NAME}.ipa")
    unless File.exist?(ipa)
      die("export produced no .ipa in #{work} (see the xcodebuild output above). " \
          "If this is a signing failure, check that the Apple ID for team " \
          "#{team_id} is added in Xcode -> Settings -> Accounts.")
    end
    ipa
  end

  # The pre-signing packaging path, kept for PATATATUBE_UNSIGNED=1: zip the
  # .app into a Payload/ by hand so AltStore can re-sign it on-device.
  def package_unsigned(archive, work)
    app_path = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    die("no #{APP_NAME}.app inside archive: #{app_path}") unless Dir.exist?(app_path)

    step "Packaging .ipa (unsigned)"
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
