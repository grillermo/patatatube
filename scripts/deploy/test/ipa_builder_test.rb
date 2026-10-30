# scripts/deploy/test/ipa_builder_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../ipa_builder"

class IpaBuilderTest < Minitest::Test
  def test_paths_point_into_the_repo
    assert File.file?(File.join(IpaBuilder::REPO_ROOT, "deploy"))
    assert File.file?(IpaBuilder::PROJECT_YML)
    assert_equal File.join(IpaBuilder::PROJECT_DIR, "Sources", "Info.plist"), IpaBuilder::INFO_PLIST
  end

  def test_local_xcconfig_wins_and_empty_values_fall_through
    Dir.mktmpdir do |dir|
      local = File.join(dir, "Local.xcconfig")
      shared = File.join(dir, "PatataTube.xcconfig")
      File.write(local, "// mine\nPATATATUBE_BUNDLE_ID = com.me.app\nDEVELOPMENT_TEAM =\n")
      File.write(shared, "PATATATUBE_BUNDLE_ID = com.example.patatatube\nDEVELOPMENT_TEAM = SHARED123\n")
      paths = [local, shared]
      assert_equal "com.me.app", IpaBuilder.xcconfig_value("PATATATUBE_BUNDLE_ID", paths)
      assert_equal "SHARED123", IpaBuilder.xcconfig_value("DEVELOPMENT_TEAM", paths)
      assert_nil IpaBuilder.xcconfig_value("MISSING", paths)
    end
  end

  def test_export_options_are_ad_hoc_universal_with_manifest
    Dir.mktmpdir do |dir|
      ENV["PATATATUBE_TEAM_ID"] = "TEAM123456"
      path = IpaBuilder.export_options_plist(File.join(dir, "E.plist"),
        manifest: { app_url: "https://f.example/files/PatataTube-1.0.0.ipa", icon_url: "https://f.example/files/i.png?a&b" })
      xml = File.read(path)
      assert_includes xml, "<key>method</key><string>release-testing</string>"
      assert_includes xml, "<key>thinning</key><string>&lt;none&gt;</string>"
      assert_includes xml, "<key>teamID</key><string>TEAM123456</string>"
      assert_includes xml, "<key>signingStyle</key><string>automatic</string>"
      assert_includes xml, "<key>appURL</key><string>https://f.example/files/PatataTube-1.0.0.ipa</string>"
      assert_includes xml, "<string>https://f.example/files/i.png?a&amp;b</string>"
      assert system("plutil -lint #{path} >/dev/null")
    ensure
      ENV.delete("PATATATUBE_TEAM_ID")
    end
  end

  def test_build_settings_put_urls_on_the_command_line
    s = IpaBuilder.extra_build_settings(ota_manifest_url: "https://f.example/files/patatatube-manifest.plist",
                                        devlog_url: "http://mac.local:19485/api/devlog", instrumented: true)
    assert_includes s, "PATATATUBE_OTA_MANIFEST_URL=https://f.example/files/patatatube-manifest.plist"
    assert_includes s, "PATATATUBE_DEVLOG_URL=http://mac.local:19485/api/devlog"
    assert_includes s, "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG'"
    assert_equal "", IpaBuilder.extra_build_settings(ota_manifest_url: nil, devlog_url: nil, instrumented: false)
  end

  def test_signing_hint_names_the_three_causes
    ENV["PATATATUBE_TEAM_ID"] = "TEAM123456"
    hint = IpaBuilder.signing_hint
    assert_includes hint, "Xcode -> Settings -> Accounts"
    assert_includes hint, "registered"
    assert_includes hint, "App ID"
    assert_includes hint, "PATATATUBE_UNSIGNED=1"
  ensure
    ENV.delete("PATATATUBE_TEAM_ID")
  end
end
