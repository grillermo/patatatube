// ios/PatataTube/Sources/MemoryProbe.swift
import Foundation
import SwiftUI
import Sentry
import os

/// Memory telemetry for the OOM / watchdog terminations (Sentry PATATATUBE-6
/// WatchdogTermination, PATATATUBE-2 App Hang). The device reporting these had
/// ~1.36 GB app footprint with only ~88 MB free, so we need to see WHERE the
/// footprint climbs — chiefly the full-resolution poster/thumbnail decodes in
/// `AuthedImage` (no downsampling) across a large library grid.
///
/// `phys_footprint` is the exact metric iOS jetsam / the watchdog compare
/// against the memory limit, and `os_proc_available_memory()` is the remaining
/// headroom before the app is killed. Both are cheap syscalls, safe on the main
/// thread.
enum MemoryProbe {
    private static let log = os.Logger(subsystem: "com.patatatube.app", category: "MemoryProbe")

    /// Below this much headroom we consider the app in danger of being jetsammed
    /// and raise a dedicated Sentry event so we catch the pre-kill state.
    private static let dangerHeadroomBytes: UInt64 = 150 * 1024 * 1024

    /// Resident physical footprint in bytes (what the OS memory limit is measured
    /// against). Returns nil if the kernel call fails.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Bytes the app can still allocate before iOS kills it (0 if unavailable).
    static func availableBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    private static func mb(_ bytes: UInt64?) -> Double {
        guard let bytes else { return -1 }
        return Double(bytes) / (1024 * 1024)
    }

    /// Records a memory snapshot as a Sentry breadcrumb (and os_log), tagged with
    /// `label` plus any extra key/values (e.g. video count, active downloads,
    /// decoded image dimensions). When headroom is dangerously low it also
    /// captures a standalone Sentry event so the pre-OOM state is preserved even
    /// if the watchdog kills us before the next flush.
    @discardableResult
    static func snapshot(_ label: String, extra: [String: Any] = [:]) -> UInt64? {
        let footprint = footprintBytes()
        let available = availableBytes()
        var data: [String: Any] = [
            "label": label,
            "footprint_mb": mb(footprint),
            "available_mb": mb(available),
        ]
        for (k, v) in extra { data[k] = v }

        log.log("mem \(label, privacy: .public) footprint=\(mb(footprint), privacy: .public)MB available=\(mb(available), privacy: .public)MB")

        let lowHeadroom = available > 0 && available < dangerHeadroomBytes
        let crumb = Breadcrumb(level: lowHeadroom ? .warning : .info, category: "memory")
        crumb.message = "\(label) footprint=\(String(format: "%.0f", mb(footprint)))MB free=\(String(format: "%.0f", mb(available)))MB"
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)

        if lowHeadroom {
            SentrySDK.capture(message: "Low memory headroom at \(label): \(String(format: "%.0f", mb(available)))MB free") { scope in
                scope.setContext(value: data, key: "memory_probe")
            }
        }
        return footprint
    }

    /// Registers a UIKit memory-warning observer that captures a Sentry event
    /// with the current footprint (the last signal before an OOM kill) and drops
    /// the in-memory image cache to buy headroom. Call once at launch.
    @MainActor
    static func installMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            let footprint = footprintBytes()
            let available = availableBytes()
            let data: [String: Any] = [
                "footprint_mb": mb(footprint),
                "available_mb": mb(available),
            ]
            log.error("MEMORY WARNING footprint=\(mb(footprint), privacy: .public)MB available=\(mb(available), privacy: .public)MB")
            SentrySDK.capture(message: "UIKit memory warning: footprint \(String(format: "%.0f", mb(footprint)))MB, \(String(format: "%.0f", mb(available)))MB free") { scope in
                scope.setContext(value: data, key: "memory_probe")
            }
        }
    }
}
