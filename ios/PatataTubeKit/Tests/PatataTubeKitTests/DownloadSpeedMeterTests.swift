import Foundation
import Testing
@testable import PatataTubeKit

private func t(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
}

@Suite("Download speed meter")
struct DownloadSpeedMeterTests {
    @Test func steadyTransferReportsThatRate() {
        var meter = DownloadSpeedMeter()
        for second in 0...5 {
            meter.record(byteCount: Int64(second) * 1_000_000, at: t(TimeInterval(second)))
        }
        #expect(meter.bytesPerSecond == 1_000_000)
    }

    @Test func aSingleSampleHasNoRate() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 5_000_000, at: t(0))
        #expect(meter.bytesPerSecond == nil)
    }

    @Test func spanBelowTheMinimumHasNoRate() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 1_000_000, at: t(0.5))
        #expect(meter.bytesPerSecond == nil)
    }

    @Test func idleAfterABurstDecaysToZero() throws {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 5_000_000, at: t(1))
        // Counter flat from here: nothing is transferring.
        meter.record(byteCount: 5_000_000, at: t(3))
        let midWindow = try #require(meter.bytesPerSecond)
        #expect(midWindow > 0)

        for second in 4...6 {
            meter.record(byteCount: 5_000_000, at: t(TimeInterval(second)))
        }
        #expect(meter.bytesPerSecond == 0)
    }

    @Test func samplesOlderThanTheWindowAreEvicted() {
        var meter = DownloadSpeedMeter()
        var bytes: Int64 = 0
        // 5 MB/s for five seconds...
        for second in 0...5 {
            meter.record(byteCount: bytes, at: t(TimeInterval(second)))
            bytes += 5_000_000
        }
        // ...then 1 MB/s for five more. The fast era must fall out of the window.
        bytes = 25_000_000
        for second in 6...10 {
            bytes += 1_000_000
            meter.record(byteCount: bytes, at: t(TimeInterval(second)))
        }
        #expect(meter.bytesPerSecond == 1_000_000)
    }

    @Test func aCompletedDownloadNeverProducesANegativeRate() throws {
        // The counter is monotonic, so a download leaving the active set is
        // simply a flat stretch, not a drop.
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 3_000_000, at: t(1))
        meter.record(byteCount: 3_000_000, at: t(2))
        let rate = try #require(meter.bytesPerSecond)
        #expect(rate == 1_500_000)
    }

    @Test func formatsDecimalMegabytesToOneDecimal() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 24_800_000, at: t(2))
        #expect(meter.formattedRate == "12.4 MB/s")
    }

    @Test func formattedRateIsNilWithoutEnoughSamples() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 1_000, at: t(0))
        #expect(meter.formattedRate == nil)
    }
}
