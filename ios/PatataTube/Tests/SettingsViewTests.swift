import Foundation
import Testing
import ViewInspector
import PatataTubeKit
@testable import PatataTube

@Suite("Settings view", .serialized)
@MainActor
struct SettingsViewTests {
    @Test
    func showsTheSelectedStreamsPerVideo() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)")
        )
        defaults.set(3, forKey: DownloadStreamSettings.key)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: CacheManager(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("settings-cache-\(UUID().uuidString)")
            ),
            downloadSettings: DownloadStreamSettings(defaults: defaults)
        )
        let sut = SettingsView().environmentObject(model)

        let content = try sut.inspect().find(text: "Streams per video")
        #expect(try content.string() == "Streams per video")
        #expect(try sut.inspect().find(text: "3").string() == "3")
        #expect((try? sut.inspect().find(ViewType.Stepper.self)) != nil)
    }

    @Test
    func showsTheSelectedSimultaneousDownloads() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)")
        )
        defaults.set(2, forKey: SimultaneousDownloadSettings.key)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: CacheManager(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("settings-cache-\(UUID().uuidString)")
            ),
            simultaneousSettings: SimultaneousDownloadSettings(defaults: defaults)
        )
        let sut = SettingsView().environmentObject(model)

        let content = try sut.inspect().find(text: "Simultaneous downloads")
        #expect(try content.string() == "Simultaneous downloads")
        #expect(try sut.inspect().find(text: "2").string() == "2")
    }
}
