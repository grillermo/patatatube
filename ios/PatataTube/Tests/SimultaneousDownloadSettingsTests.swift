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
}
