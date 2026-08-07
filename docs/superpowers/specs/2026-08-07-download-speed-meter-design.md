# Download speed meter in the Downloads view

**Date:** 2026-08-07
**Status:** approved design, not yet implemented

## Goal

Show the aggregate download throughput of all in-flight offline downloads at
the top right of the Downloads view's "In Progress" section, as a rolling
average over the last 5 seconds.

## Scope

Counted: bytes transferred by `CacheManager` in-flight downloads — plain MP4
downloads, segmented downloads, and HLS asset fetches. This is exactly the set
of transfers the "In Progress" section lists, so the number always describes
the rows beneath it.

Not counted: `StreamProxy` playback traffic, server-side conversion progress
(`JobsStore`), preview/poster fetches. `StreamProxy` never registers in
`CacheManager.inFlight`, so this falls out of the design rather than needing a
filter.

## The problem the design exists to solve

`CacheManager.activeDownloads()` reports each in-flight transfer's *absolute*
`transferredByteCount`. Summing that across the active set and differencing the
sum over time yields a **negative** rate whenever a download finishes or is
cancelled, because its bytes leave the set. A speed meter needs a monotonic
byte counter, not a snapshot sum.

## Design

### 1. Monotonic byte counter in `CacheManager`

`inFlight` is written at ~19 call sites (`inFlight[key] = …`, `inFlight[key] =
nil`, `inFlight[key]?.record(…)`). Rather than funnel all of them through a new
helper, wrap the dictionary in a small struct whose subscript computes the
delta:

```swift
struct InFlightActivities {
    private(set) var cumulativeByteCount: Int64 = 0
    private var storage: [String: DownloadActivityAccumulator] = [:]

    subscript(key: String) -> DownloadActivityAccumulator? {
        get { storage[key] }
        set {
            let before = storage[key]?.activity.transferredByteCount ?? 0
            let after = newValue?.activity.transferredByteCount ?? before   // removal contributes 0
            cumulativeByteCount += max(after - before, 0)
            storage[key] = newValue
        }
    }

    var values: some Collection<DownloadActivityAccumulator> { storage.values }
}
```

`private var inFlight = InFlightActivities()` replaces the dictionary. Every
existing call site keeps its exact syntax: `inFlight[key]?.record(…)` is a
get-modify-set through the subscript, so the setter observes the new value and
accumulates the delta. This covers all three progress paths —
`updateExternalActivity` (HLS), `updateSegmentProgress` (segmented), and the
plain `URLSessionDownloadTask` path — with no edits to any of them.

Removal (`inFlight[key] = nil`) contributes zero, so the counter never
decreases. It is a per-process counter; it is never persisted and never reset.

New public accessor, taking the existing `lock`:

```swift
public func downloadedByteCount() -> Int64 {
    lock.withLock { inFlight.cumulativeByteCount }
}
```

### 2. `DownloadSpeedMeter` (PatataTubeKit, pure value type)

```swift
public struct DownloadSpeedMeter {
    public init(window: TimeInterval = 5, minimumSpan: TimeInterval = 1)
    public mutating func record(byteCount: Int64, at date: Date)
    public var bytesPerSecond: Double? { get }
}
```

Holds a ring of `(Date, Int64)` samples. On `record`, appends the sample and
drops samples older than `newest - window`, retaining the single sample that
straddles the window edge so the measured span stays close to a full 5s.

`bytesPerSecond` = `(newest.bytes - oldest.bytes) / (newest.date -
oldest.date)`, or `nil` when the span is under `minimumSpan` (1s). The `nil`
case prevents a wild first reading in the quarter-second after the view opens.
The result can never be negative, because the input counter is monotonic.

No clock ownership, no concurrency: the caller supplies the date. This is what
makes it testable without sleeps.

### 3. `DownloadsView` presentation

The meter is `@State private var meter = DownloadSpeedMeter()` on
`DownloadsView` — view-owned, so it resets when the view is dismissed and there
is no always-on timer in `CacheManager`.

It is fed from a `Timer.publish(every: 0.25, on: .main, in: .common)
.autoconnect()` observed with `.onReceive` on the `List`, calling
`meter.record(byteCount: model.cache.downloadedByteCount(), at: date)`. The
existing `TimelineView(.periodic(by: 0.25))` drives the rows and stays as is;
the meter deliberately does **not** update from inside the `TimelineView` body,
because mutating `@State` there is a render-phase write.

The "In Progress" section gains a header:

```swift
Section {
    ForEach(activeItems) { activeRow($0) }
} header: {
    HStack {
        Text("In Progress")
        Spacer()
        if let rate = meter.bytesPerSecond {
            Text(String(format: "%.1f MB/s", rate / 1_000_000))
                .monospacedDigit()
        }
    }
}
```

Format: decimal megabytes (`bytes / 1_000_000`), one decimal place,
`monospacedDigit()` so the value does not jitter horizontally as it changes.

Idle behaviour follows from the placement: the section only exists while there
are active downloads, so the readout disappears with it. Within the window,
finished transfers decay the average toward zero rather than dropping it
instantly.

## Testing

`PatataTubeKit` (`swift test`) — `DownloadSpeedMeterTests`, all with injected
dates:

- steady rate over a full window reports that rate
- a burst followed by idle decays toward 0 as the window slides
- a download completing mid-window keeps the rate non-negative
- span under `minimumSpan` returns `nil`
- samples older than the window are evicted, straddling sample retained

`PatataTubeKit` — `CacheManager` counter test: drive
`beginExternalActivity` / `updateExternalActivity` / removal and assert
`downloadedByteCount()` is monotonic across the removal and matches the bytes
recorded.

No app-target (`xcodebuild`) test. Per `CLAUDE.md`, ViewInspector writes
sentinel bytes at guessed offsets and segfaults the test process on larger
SwiftUI views; the formatting and rate logic all live in the Kit types, which
are covered above.

## Out of scope

- Per-download speed on individual rows.
- Persisting the counter or the rolling window across launches.
- Counting playback/proxy traffic.
- Any change to the "Converting" section, which reports server-side job
  progress and involves no client network transfer.
