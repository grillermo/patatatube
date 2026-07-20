import Clocks
import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

private func episode(_ id: Int, season: Int, number: Int) -> Video {
    Video(
        id: id,
        url: "/episode/\(id)",
        title: "Episode \(number)",
        platform: nil,
        sourceKey: nil,
        previewUrl: nil,
        classification: "tv",
        position: id,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/\(id)/stream",
        source: "library",
        showTitle: "The Show",
        season: season,
        episode: number
    )
}

private func show(from episodes: [Video]) -> ShowGroup {
    ShowGroup.group(episodes).first!
}

private actor EpisodeDownloadProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedIDs: [Int] = []

    func download(_ video: Video) async -> Bool {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedIDs.append(video.id)
        await Task.yield()
        activeCount -= 1
        return video.id != 1
    }

    func snapshot() -> (startedIDs: [Int], maximumActiveCount: Int) {
        (startedIDs, maximumActiveCount)
    }
}

@Suite("Episode download all batch", .serialized)
@MainActor
struct EpisodesDownloadAllBatchTests {
    @Test func skipsIneligibleEpisodesRunsInOrderAndContinuesAfterFalse() async {
        let grouped = show(from: [
            episode(4, season: 2, number: 1),
            episode(3, season: 1, number: 3),
            episode(1, season: 1, number: 1),
            episode(2, season: 1, number: 2),
        ])
        let states: [Int: CacheState] = [
            1: .notCached,
            2: .cached,
            3: .downloading(0.4),
            4: .notCached,
        ]
        let probe = EpisodeDownloadProbe()

        #expect(EpisodesView.hasEligibleEpisode(
            in: grouped.episodes,
            currentCacheState: { states[$0.id] ?? .notCached }
        ))

        await EpisodesView.downloadEligibleEpisodes(
            grouped.episodes,
            currentCacheState: { states[$0.id] ?? .notCached },
            onDownload: { await probe.download($0) }
        )

        let snapshot = await probe.snapshot()
        #expect(snapshot.startedIDs == [1, 4])
        #expect(snapshot.maximumActiveCount == 1)
        #expect(!EpisodesView.hasEligibleEpisode(
            in: grouped.episodes,
            currentCacheState: { _ in .cached }
        ))
    }
}
