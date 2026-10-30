import Foundation
import Testing
@testable import PatataTube

@Suite("Quick actions")
struct QuickActionTests {
    private let deployedInfo: [String: Any] = [
        QuickAction.otaManifestURLInfoKey: "https://files.example.com/files/patatatube-manifest.plist"
    ]

    @Test
    func installLatestStartsTheOTAInstallFromTheBakedInManifest() {
        // ./deploy bakes in the manifest it republishes under the same name on
        // every release, so the link always installs the newest build.
        #expect(QuickAction.installLatest.url(infoDictionary: deployedInfo)
            == URL(string: "itms-services://?action=download-manifest&url=https://files.example.com/files/patatatube-manifest.plist"))
    }

    @Test
    func deployedBuildOffersInstallLatest() {
        #expect(QuickAction.dynamicActions(infoDictionary: deployedInfo) == [.installLatest])
    }

    @Test
    func buildWithoutAManifestOffersNoInstallLatest() {
        let localBuild: [String: Any] = [QuickAction.otaManifestURLInfoKey: ""]
        #expect(QuickAction.dynamicActions(infoDictionary: localBuild).isEmpty)
        #expect(QuickAction.dynamicActions(infoDictionary: nil).isEmpty)
        #expect(QuickAction.installLatest.url(infoDictionary: localBuild) == nil)
    }

    @Test
    func onlyInstallLatestExitsAfterOpening() {
        #expect(QuickAction.installLatest.exitsAfterOpening)
        #expect(!QuickAction.clearAll.exitsAfterOpening)
    }

    @Test
    func maintenanceActionsOpenNoURL() {
        #expect(QuickAction.clearAll.url(infoDictionary: deployedInfo) == nil)
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
            #expect(type != QuickAction.installLatest.rawValue, "Install Latest must be dynamic, not static")
        }
    }

    @Test
    func infoPlistDeclaresTheManifestKey() {
        // Present (empty outside ./deploy), so the build-setting wiring exists.
        #expect(Bundle.main.object(forInfoDictionaryKey: QuickAction.otaManifestURLInfoKey) is String)
    }
}
