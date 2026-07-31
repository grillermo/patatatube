import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Device storage")
struct DeviceStorageTests {

    @Test
    func reportsAvailableBytesForARealDirectory() {
        let bytes = DeviceStorage.availableBytes(at: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(bytes != nil)
        #expect((bytes ?? 0) > 0)
    }

    @Test
    func returnsNilForAMissingPath() {
        let missing = URL(fileURLWithPath: "/no-such-volume-\(UUID().uuidString)/x")

        #expect(DeviceStorage.availableBytes(at: missing) == nil)
    }
}
