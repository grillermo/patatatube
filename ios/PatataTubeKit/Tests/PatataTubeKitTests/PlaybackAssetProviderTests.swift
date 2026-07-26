import Foundation
import Testing
@testable import PatataTubeKit

private func entry(
    kind: HLSCacheEntry.Kind = .temp, complete: Bool = false
) -> HLSCacheEntry {
    HLSCacheEntry(
        cacheKey: "1", videoId: 1, versionId: nil, bookmark: Data([0x1]),
        kind: kind, isComplete: complete, fractionComplete: complete ? 1 : 0.4,
        byteCount: 1_000, lastPlayedAt: Date(), audioLang: "eng")
}

@Suite("Playback asset decisions")
struct PlaybackAssetProviderTests {
    @Test func completePackagePlaysLocally() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: entry(kind: .permanent, complete: true),
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: false
        ) == .localPackage)
    }

    @Test func completePackageWinsOverPackagingErrors() {
        // The package is already on disk; the server's inability to repackage
        // must not block offline playback.
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "error", entry: entry(kind: .permanent, complete: true),
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .localPackage)
    }

    @Test func staleAudioLanguageIsNotPlayedLocally() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: entry(kind: .permanent, complete: true),
            entryAudioLangMatches: false, isOnWiFi: true, hasNetwork: true
        ) == .fillAhead)
    }

    @Test func partialPackageOfflinePlaysWhatIsOnDisk() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: entry(complete: false),
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: false
        ) == .localPackage)
    }

    @Test func wifiWithoutAPackageFillsAhead() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .fillAhead)
    }

    @Test func cellularWithoutAPackageStreamsWithoutCaching() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: true
        ) == .remoteOnly)
    }

    @Test func packagingErrorWithoutAPackageIsUnplayable() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "error", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .unplayable(reason: "HLS packaging failed"))
    }

    @Test func notYetPackagedWithoutAPackageIsUnplayable() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "converting", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .unplayable(reason: "HLS not ready"))
    }

    @Test func offlineWithoutAPackageIsUnplayable() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: false
        ) == .unplayable(reason: "Offline and not downloaded"))
    }
}
