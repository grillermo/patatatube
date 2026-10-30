# frozen_string_literal: true

# ipa_builder.rb
#
# Builds a PatataTube .ipa from source, together with the OTA manifest.plist an
# `itms-services://` link points at. Used by ../../deploy and ../../ios/refresh-ipa.rb.
#
# The .ipa is signed **ad hoc** with the paid Apple Developer Program team from
# ios/PatataTube/Config/Local.xcconfig (gitignored; it overrides the committed
# defaults in Config/PatataTube.xcconfig). That is what lets iOS install it
# straight from Safari: no AltStore, no cable, and a signature good for a year.
# The price is that an Ad Hoc profile only covers **devices registered on the
# portal when the build is made**: a device added later needs a fresh ./deploy.
#
# PATATATUBE_UNSIGNED=1 falls back to an unsigned Payload/ zip, so a broken
# signing setup never blocks getting a binary. Safari cannot install that one.

require "fileutils"
require "shellwords"
require "tmpdir"

module IpaBuilder
  APP_NAME    = "PatataTube"
  SCHEME      = "PatataTube"
  REPO_ROOT   = File.expand_path("../..", __dir__)
  PROJECT_DIR = File.join(REPO_ROOT, "ios", APP_NAME)   # ios/PatataTube
  PROJECT     = "#{APP_NAME}.xcodeproj"
  PROJECT_YML = File.join(PROJECT_DIR, "project.yml")
  INFO_PLIST  = File.join(PROJECT_DIR, "Sources", "Info.plist")
  LOCAL_XCCONFIG = File.join(PROJECT_DIR, "Config", "Local.xcconfig")
  XCCONFIGS = [LOCAL_XCCONFIG, File.join(PROJECT_DIR, "Config", "PatataTube.xcconfig")].freeze

  module_function

  def bold(str) = "\e[1m#{str}\e[0m"
  def green(str) = "\e[32m#{str}\e[0m"
  def red(str) = "\e[31m#{str}\e[0m"
  def step(msg) = puts "\n#{bold("==> #{msg}")}"

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:, hint: nil)
    puts "    $ #{cmd}"
    return if system(cmd, chdir: chdir)

    die(["command failed: #{cmd}", hint].compact.join("\n"))
  end

  def unsigned? = ENV["PATATATUBE_UNSIGNED"] == "1"

  # A build setting as Xcode resolves it: Local.xcconfig wins over the committed
  # PatataTube.xcconfig. Empty values fall through to the next file.
  def xcconfig_value(key, paths = XCCONFIGS)
    paths.each do |path|
      next unless File.exist?(path)

      value = File.read(path)[/^\s*#{Regexp.escape(key)}\s*=[ \t]*(\S*)/, 1]
      return value if value && !value.empty?
    end
    nil
  end

  def bundle_id = xcconfig_value("PATATATUBE_BUNDLE_ID")

  # PATATATUBE_TEAM_ID overrides Local.xcconfig for a one-off.
  def team_id
    id = ENV["PATATATUBE_TEAM_ID"] || xcconfig_value("DEVELOPMENT_TEAM")
    die("no DEVELOPMENT_TEAM in #{LOCAL_XCCONFIG} and no PATATATUBE_TEAM_ID set (see ios/install.md)") unless id
    id
  end

  # Preflight for a signed build: the committed defaults build in a fresh clone,
  # but cannot be signed for distribution.
  def check_signing_config!
    return if unsigned?

    team_id
    id = bundle_id
    return unless id.nil? || id.start_with?("com.example.")

    die("PATATATUBE_BUNDLE_ID is #{id.inspect}. Create #{LOCAL_XCCONFIG} with your registered " \
        "App ID and team (see ios/install.md), or set PATATATUBE_UNSIGNED=1 for an unsigned build.")
  end

  def signing_hint
    <<~TXT.chomp
      Signing failed. Check:
        - Xcode -> Settings -> Accounts lists the Apple ID for team #{ENV["PATATATUBE_TEAM_ID"] || xcconfig_value("DEVELOPMENT_TEAM")}.
        - The device is registered on developer.apple.com (Devices) BEFORE this build:
          an ad hoc profile only covers devices registered when it is made.
        - The App ID #{bundle_id} exists under Identifiers: automatic signing creates
          certificates and profiles, but never App IDs.
      To get a binary anyway: PATATATUBE_UNSIGNED=1 ./deploy
    TXT
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

  def marketing_version
    m = File.read(PROJECT_YML)[/^\s*MARKETING_VERSION:\s*"?([\d.]+)"?/, 1]
    die("no MARKETING_VERSION in #{PROJECT_YML}") unless m
    m
  end

  def current_project_version
    m = File.read(PROJECT_YML)[/^\s*CURRENT_PROJECT_VERSION:\s*"?(\d+)"?/, 1]
    die("no CURRENT_PROJECT_VERSION in #{PROJECT_YML}") unless m
    m
  end

  # Over SSH, or after the Mac slept, the login keychain is locked and codesign
  # cannot use the signing key. The archive would then die at its first CodeSign
  # step (errSecInternalComponent) after minutes of compiling. Sign a throwaway
  # copy of /usr/bin/true as a probe; if that fails, unlock the keychain (prompts
  # for the login password) and probe again.
  def ensure_codesign_can_sign!
    return if unsigned?

    probe = File.join(Dir.tmpdir, "#{APP_NAME}-codesign-probe-#{Process.pid}")
    FileUtils.cp("/usr/bin/true", probe)
    sign = "codesign -f -s 'Apple Development' #{Shellwords.escape(probe)} >/dev/null 2>&1"
    return if system(sign)

    puts red("    codesign cannot use your signing key -- the login keychain is locked.")
    keychain = File.expand_path("~/Library/Keychains/login.keychain-db")
    system("security unlock-keychain #{Shellwords.escape(keychain)}") or
      die("could not unlock the login keychain")
    system(sign) or
      die("codesign still fails after unlocking; try: codesign -f -s 'Apple Development' /some/file")
  ensure
    FileUtils.rm_f(probe) if probe
  end

  def xml_escape(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # ExportOptions.plist for `xcodebuild -exportArchive`.
  #
  # `release-testing` is Xcode 15.3+'s name for ad hoc: it re-signs with the
  # team's distribution certificate against an Ad Hoc profile that embeds the
  # registered UDIDs. Automatic signing creates the certificate and profile, but
  # NOT the App ID, so PATATATUBE_BUNDLE_ID must already exist on the portal.
  #
  # The `manifest` dict makes xcodebuild write the manifest.plist an
  # itms-services:// link needs, so the manifest can never drift from the binary.
  # Its appURL is the .ipa's final public URL, known before the build.
  #
  # thinning `<none>` keeps one universal .ipa that a single URL can serve.
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

  # Settings passed on the xcodebuild command line. The URLs go here, not in an
  # xcconfig, because xcconfig reads the `//` in a URL as a comment. The command
  # line is also the only place that reaches both the app target and the
  # PatataTubeKit SwiftPM package, which is why DEVLOG goes here too.
  def extra_build_settings(ota_manifest_url:, devlog_url:, instrumented:)
    s = +""
    s << "PATATATUBE_OTA_MANIFEST_URL=#{Shellwords.escape(ota_manifest_url)} " if ota_manifest_url
    s << "PATATATUBE_DEVLOG_URL=#{Shellwords.escape(devlog_url)} " if devlog_url
    s << "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG' " if instrumented
    s
  end

  # Builds the .ipa and returns its path, inside a fresh tmp dir the caller owns
  # and must remove. With `manifest:`, manifest.plist is written beside the .ipa.
  def build(manifest: nil, ota_manifest_url: nil, devlog_url: nil, instrumented: false)
    die("no xcodegen on PATH (brew install xcodegen)") if `which xcodegen`.empty?
    die("project dir not found: #{PROJECT_DIR}") unless Dir.exist?(PROJECT_DIR)

    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    step "Regenerating Xcode project (xcodegen)"
    run("xcodegen generate", chdir: PROJECT_DIR)

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{APP_NAME}.xcarchive")

    signing = unsigned? ? "CODE_SIGNING_ALLOWED=NO " : "DEVELOPMENT_TEAM=#{team_id} "
    extra = extra_build_settings(ota_manifest_url: ota_manifest_url, devlog_url: devlog_url, instrumented: instrumented)

    step "Archiving (xcodebuild)#{instrumented ? ' [DEVLOG]' : ''}#{unsigned? ? ' [UNSIGNED]' : ''}"
    run(
      "xcodebuild " \
      "-project #{Shellwords.escape(PROJECT)} " \
      "-scheme #{Shellwords.escape(SCHEME)} " \
      "-configuration Release " \
      "-destination 'generic/platform=iOS' " \
      "-archivePath #{Shellwords.escape(archive)} " \
      "#{signing}#{extra}" \
      "-allowProvisioningUpdates " \
      "archive",
      chdir: PROJECT_DIR,
      hint: unsigned? ? nil : signing_hint
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
      chdir: PROJECT_DIR,
      hint: signing_hint
    )

    ipa = File.join(work, "#{APP_NAME}.ipa")
    die("export produced no .ipa in #{work}.\n#{signing_hint}") unless File.exist?(ipa)
    ipa
  end

  # PATATATUBE_UNSIGNED=1: zip the .app into a Payload/ by hand.
  def package_unsigned(archive, work)
    app_path = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    die("no #{APP_NAME}.app inside archive: #{app_path}") unless Dir.exist?(app_path)

    step "Packaging .ipa (unsigned)"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app_path, payload)

    ipa = File.join(work, "#{APP_NAME}.ipa")
    # ditto --keepParent keeps Payload/ at the archive root and preserves the
    # symlinks inside embedded frameworks (plain zip can mangle them).
    run("ditto -c -k --sequesterRsrc --keepParent #{Shellwords.escape(payload)} #{Shellwords.escape(ipa)}", chdir: work)
    ipa
  end
end
