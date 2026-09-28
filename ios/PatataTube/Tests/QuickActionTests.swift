import Foundation
import Testing
@testable import PatataTube

@Suite("Quick actions")
struct QuickActionTests {
    @Test
    func installLatestOpensThePinnedOTAManifest() throws {
        let action = try #require(QuickAction(shortcutType: "com.patatatube.app.install-latest"))
        #expect(action == .installLatest)
        #expect(action.url?.absoluteString ==
            "itms-services://?action=download-manifest&url=https://files.chiq.me/files/patatatube-manifest.plist")
    }

    @Test
    func maintenanceActionsOpenNoURL() {
        #expect(QuickAction.clearAll.url == nil)
    }

    @Test
    func unknownShortcutTypeIsNil() {
        #expect(QuickAction(shortcutType: "com.patatatube.nope") == nil)
    }

    @Test
    func everyDeclaredShortcutMapsToAQuickAction() throws {
        let items = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems") as? [[String: Any]]
        )
        #expect(!items.isEmpty)
        for item in items {
            let type = try #require(item["UIApplicationShortcutItemType"] as? String)
            #expect(QuickAction(shortcutType: type) != nil, "unmapped shortcut \(type)")
        }
    }
}
