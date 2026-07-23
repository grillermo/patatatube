import Foundation
import Testing
import PatataTubeKit
@testable import PatataTube

@Suite("Download stream settings", .serialized)
@MainActor
struct DownloadStreamSettingsTests {
    private func defaults() throws -> UserDefaults {
        let name = "DownloadStreamSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test
    func defaultsToTwoAndClampsStoredValues() throws {
        let defaults = try defaults()
        let settings = DownloadStreamSettings(defaults: defaults)

        #expect(settings.load() == 2)

        defaults.set(-10, forKey: DownloadStreamSettings.key)
        #expect(settings.load() == 1)

        defaults.set(99, forKey: DownloadStreamSettings.key)
        #expect(settings.load() == 4)
    }

    @Test
    func appModelSavesTheSelectedCount() throws {
        let defaults = try defaults()
        let settings = DownloadStreamSettings(defaults: defaults)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: CacheManager(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("model-cache-\(UUID().uuidString)")
            ),
            downloadSettings: settings
        )

        model.downloadStreamCount = 3
        model.saveSettings()

        #expect(settings.load() == 3)
    }
}
