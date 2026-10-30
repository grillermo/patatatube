# scripts/deploy/test/install_page_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../install_page"

class InstallPageTest < Minitest::Test
  def render(notes: "• a")
    InstallPage.render(
      version: "2.7.29", build: 211,
      icon_url: "https://files.example/files/patatatube-icon.png",
      itms_url: "itms-services://?action=download-manifest&url=https://files.example/files/patatatube-manifest.plist",
      notes: notes, min_os: "18.0"
    )
  end

  def test_has_install_link_version_and_safari_note
    html = render
    assert_includes html, 'href="itms-services://?action=download-manifest&amp;url=https://files.example/files/patatatube-manifest.plist"'
    assert_includes html, "Version 2.7.29 (build 211)"
    assert_includes html, "Safari"
    assert_includes html, "Add this page to your Home Screen"
    assert_includes html, "registered"
    assert_includes html, "iOS 18.0 or later"
    assert_includes html, "color-scheme: dark"
  end

  def test_escapes_release_notes
    html = render(notes: %(<script>alert("x")</script> & co))
    refute_includes html, "<script>alert"
    assert_includes html, "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; co"
  end
end
