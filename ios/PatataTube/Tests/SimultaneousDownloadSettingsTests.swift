import Foundation
import Testing
import PatataTubeKit
@testable import PatataTube

@Suite("Simultaneous download settings", .serialized)
@MainActor
struct SimultaneousDownloadSettingsTests {
    private func defaults() throws -> UserDefaults {
        let name = "SimultaneousDownloadSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test
    func defaultsToThreeAndClampsStoredValues() throws {
        let defaults = try defaults()
        let settings = SimultaneousDownloadSettings(defaults: defaults)

        #expect(settings.load() == 3)

        defaults.set(-10, forKey: SimultaneousDownloadSettings.key)
        #expect(settings.load() == 1)

        defaults.set(99, forKey: SimultaneousDownloadSettings.key)
        #expect(settings.load() == 4)
    }

    @Test
    func saveClampsBeforePersisting() throws {
        let defaults = try defaults()
        let settings = SimultaneousDownloadSettings(defaults: defaults)

        settings.save(99)
        #expect(settings.load() == 4)

        settings.save(0)
        #expect(settings.load() == 1)
    }

    @Test
    func appModelSavesAndPushesConcurrencyToCache() throws {
        let defaults = try defaults()
        let settings = SimultaneousDownloadSettings(defaults: defaults)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cacheRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("concurrency-cache-\(UUID().uuidString)"),
            simultaneousSettings: settings
        )

        // Loaded default is pushed to the cache on init.
        #expect(model.downloadConcurrency == 3)
        #expect(model.cache.maxConcurrentDownloads == 3)

        model.downloadConcurrency = 2
        model.saveSettings()

        #expect(settings.load() == 2)
        #expect(model.cache.maxConcurrentDownloads == 2)
    }
}
