import Clocks
import Foundation
import Observation
import PatataTubeKit
import SwiftUI

struct DownloadButtonIdentity: Hashable, Sendable {
    let videoID: Int
    let versionID: Int?
    let audioLanguage: String?
}

@MainActor
@Observable
final class DownloadButtonState {
    enum Phase: Equatable {
        case idle
        case loading
        case done
    }

    private(set) var phase: Phase = .idle
    private(set) var observedCacheState: CacheState?
    private(set) var progress: Double = 0
    private(set) var activeAttemptID: UUID?
    private(set) var isArmed: Bool = false
    private(set) var armGeneration: Int = 0

    init(initialCacheState: CacheState = .notCached) {
        observe(initialCacheState)
    }

    var effectiveState: CacheState {
        let observedState = observedCacheState ?? .notCached
        switch phase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done:
            return .cached
        case .idle:
            return observedState
        }
    }

    var clampedProgress: Double {
        let value: Double
        if case .downloading(let progress) = effectiveState {
            value = progress
        } else {
            value = self.progress
        }
        return min(max(value, 0), 1)
    }

    var isDownloading: Bool {
        if case .downloading = effectiveState { return true }
        return false
    }

    var showsArmedDelete: Bool {
        isArmed && effectiveState == .cached
    }

    @discardableResult
    func begin(attemptID: UUID = UUID()) -> UUID {
        activeAttemptID = attemptID
        phase = .loading
        observedCacheState = .downloading(0)
        progress = 0
        return attemptID
    }

    func finish(attemptID: UUID, succeeded: Bool) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        phase = succeeded ? .done : .idle
        observedCacheState = succeeded ? .cached : .notCached
        progress = succeeded ? 1 : 0
    }

    func cancel() {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = .notCached
        progress = 0
    }

    func reset(to cacheState: CacheState) {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = nil
        progress = 0
        observe(cacheState)
        if cacheState != .cached { isArmed = false }
    }

    func observe(_ cacheState: CacheState) {
        if cacheState != .cached { isArmed = false }
        observedCacheState = cacheState
        switch cacheState {
        case .downloading(let progress):
            self.progress = progress
        case .cached:
            progress = 1
        case .notCached:
            if phase == .idle { progress = 0 }
        }
    }

    func arm() {
        isArmed = true
        armGeneration += 1
    }

    func disarm() {
        isArmed = false
    }

    func poll(
        currentCacheState: @escaping () -> CacheState,
        clock: any Clock<Duration>
    ) async {
        while !Task.isCancelled {
            observe(currentCacheState())
            let interval: Duration = isDownloading ? .milliseconds(150) : .milliseconds(500)
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}

@MainActor
struct DownloadButton: View {
    let identity: DownloadButtonIdentity
    var refreshToken: Int = 0
    let currentCacheState: () -> CacheState
    let onDownload: () async -> Bool
    let onCancel: () -> Void
    let onDeleteCache: () -> Void
    // Optional lifecycle seam for hosted inspection of SwiftUI-resolved environment values.
    var didAppear: ((Self) -> Void)? = nil

    @Environment(\.continuousClock) private var clock
    @Environment(VideoPreparationTracker.self) private var preparationTracker
    @State private var state: DownloadButtonState

    private struct ObservationID: Hashable {
        let identity: DownloadButtonIdentity
        let refreshToken: Int
    }

    init(
        identity: DownloadButtonIdentity,
        refreshToken: Int = 0,
        currentCacheState: @escaping () -> CacheState,
        onDownload: @escaping () async -> Bool,
        onCancel: @escaping () -> Void,
        onDeleteCache: @escaping () -> Void,
        state: DownloadButtonState? = nil
    ) {
        self.identity = identity
        self.refreshToken = refreshToken
        self.currentCacheState = currentCacheState
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onDeleteCache = onDeleteCache
        _state = State(initialValue: state ?? DownloadButtonState(
            initialCacheState: currentCacheState()
        ))
    }

    @ViewBuilder
    var body: some View {
        if let didAppear {
            control
                .onAppear { didAppear(self) }
        } else {
            activeControl
        }
    }

    private var activeControl: some View {
        control
            .task(id: ObservationID(identity: identity, refreshToken: refreshToken)) {
                state.reset(to: currentCacheState())
                await state.poll(currentCacheState: currentCacheState, clock: clock)
            }
            .task(id: state.armGeneration) {
                guard state.isArmed else { return }
                do {
                    try await clock.sleep(for: .seconds(3))
                } catch {
                    return
                }
                withAnimation { state.disarm() }
            }
    }

    @ViewBuilder
    private var control: some View {
        if preparationTracker.isPreparing(videoID: identity.videoID) {
            ProgressView()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Preparing video")
        } else {
            cacheControl
        }
    }

    @ViewBuilder
    private var cacheControl: some View {
        switch state.effectiveState {
        case .cached:
            Button {
                if state.showsArmedDelete {
                    onDeleteCache()
                    withAnimation { state.reset(to: .notCached) }
                } else {
                    withAnimation { state.arm() }
                }
            } label: {
                Image(systemName: state.showsArmedDelete ? "x.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.showsArmedDelete ? .red : .green)
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .transition(.scale.combined(with: .opacity))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.showsArmedDelete ? "Delete download" : "Downloaded")

        case .downloading:
            Button {
                withAnimation { state.cancel() }
                onCancel()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: state.clampedProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: state.clampedProgress)
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
            .accessibilityValue("\(Int(state.clampedProgress * 100))%")

        case .notCached:
            Button {
                Task { @MainActor in
                    let attemptID = withAnimation { state.begin() }
                    let succeeded = await onDownload()
                    withAnimation {
                        state.finish(attemptID: attemptID, succeeded: succeeded)
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Download")
        }
    }
}
