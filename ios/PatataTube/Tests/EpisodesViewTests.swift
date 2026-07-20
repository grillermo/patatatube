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

@MainActor
private final class EpisodeCacheStateSource {
    var values: [Int: CacheState]
    private(set) var readCount = 0

    init(_ values: [Int: CacheState]) {
        self.values = values
    }

    func read(_ video: Video) -> CacheState {
        readCount += 1
        return values[video.id] ?? .notCached
    }
}

@MainActor
private final class EpisodeDownloadGate {
    private(set) var startedIDs: [Int] = []
    private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var bufferedResults: [Int: Bool] = [:]

    func wait(for video: Video) async -> Bool {
        startedIDs.append(video.id)
        if let result = bufferedResults.removeValue(forKey: video.id) {
            return result
        }
        return await withCheckedContinuation { continuation in
            continuations[video.id] = continuation
        }
    }

    func finish(_ videoID: Int, result: Bool) {
        if let continuation = continuations.removeValue(forKey: videoID) {
            continuation.resume(returning: result)
        } else {
            bufferedResults[videoID] = result
        }
    }
}

@MainActor
private func eventually(
    _ message: String,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record(Comment(rawValue: message))
}

@MainActor
private func downloadAllButton<V: View>(
    in sut: V,
    function: String = #function
) throws -> InspectableView<ViewType.Button> {
    try sut.inspect(function: function).find(ViewType.Button.self) { button in
        try button.accessibilityLabel().string() == "Download all episodes"
    }
}

@Suite("Episode download all view", .serialized)
@MainActor
struct EpisodesDownloadAllViewTests {
    @Test func toolbarIsAccessibleAndTracksEligibility() async throws {
        let grouped = show(from: [episode(1, season: 1, number: 1)])
        let source = EpisodeCacheStateSource([1: .notCached])
        let clock = TestClock()
        let sut = EpisodesView(
            show: grouped,
            onPlay: { _, _ in },
            onDownload: { _ in true },
            currentCacheState: { source.read($0) }
        )
        .environmentObject(AppModel())
        .environment(\.continuousClock, clock)

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }

        await eventually("Eligibility observation never read cache state") {
            source.readCount > 0
        }
        await eventually("Eligible show never enabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }

        var button = try downloadAllButton(in: sut)
        #expect(try button.accessibilityLabel().string() == "Download all episodes")

        source.values[1] = .cached
        await clock.advance(by: .milliseconds(500))
        await eventually("Fully cached show never disabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == true
        }

        button = try downloadAllButton(in: sut)
        #expect(try button.isDisabled())
    }

    @Test func activeBatchShowsSpinnerDisablesAndRecoversAfterFalse() async throws {
        let grouped = show(from: [episode(1, season: 1, number: 1)])
        let source = EpisodeCacheStateSource([1: .notCached])
        let gate = EpisodeDownloadGate()
        let clock = TestClock()
        let sut = EpisodesView(
            show: grouped,
            onPlay: { _, _ in },
            onDownload: { await gate.wait(for: $0) },
            currentCacheState: { source.read($0) }
        )
        .environmentObject(AppModel())
        .environment(\.continuousClock, clock)

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }

        await eventually("Eligible show never enabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }
        try downloadAllButton(in: sut).tap()
        await eventually("Batch never started the first episode") {
            gate.startedIDs == [1]
        }

        var button = try downloadAllButton(in: sut)
        #expect(try button.isDisabled())
        #expect((try? button.find(ViewType.ProgressView.self)) != nil)

        gate.finish(1, result: false)
        await eventually("Failed episode left the batch button disabled") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }

        button = try downloadAllButton(in: sut)
        #expect((try? button.find(ViewType.Image.self)) != nil)
    }

    @Test func removingEpisodeViewDoesNotCancelStartedBatch() async throws {
        let grouped = show(from: [
            episode(2, season: 1, number: 2),
            episode(1, season: 1, number: 1),
        ])
        let source = EpisodeCacheStateSource([1: .notCached, 2: .notCached])
        let gate = EpisodeDownloadGate()
        let sut = EpisodesView(
            show: grouped,
            onPlay: { _, _ in },
            onDownload: { await gate.wait(for: $0) },
            currentCacheState: { source.read($0) }
        )
        .environmentObject(AppModel())

        ViewHosting.host(view: sut)
        await eventually("Eligible show never enabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }
        try downloadAllButton(in: sut).tap()
        await eventually("Batch never started episode 1") {
            gate.startedIDs == [1]
        }

        ViewHosting.expel()
        gate.finish(1, result: true)
        await eventually("Leaving the view cancelled the remaining batch") {
            gate.startedIDs == [1, 2]
        }
        gate.finish(2, result: true)
    }
}
