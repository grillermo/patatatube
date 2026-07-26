import XCTest
@testable import PatataTubeKit

final class StreamCacheLRUTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeEntry(_ name: String, bytes: Int) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data(repeating: 0, count: bytes).write(to: dir.appendingPathComponent("blob"))
        return dir
    }

    func testEvictsOldestTouchedFirstUntilUnderBudget() async {
        let a = makeEntry("a", bytes: 600)
        let b = makeEntry("b", bytes: 600)
        let c = makeEntry("c", bytes: 600)
        let lru = StreamCacheLRU(managedDirs: [root], budgetBytes: 1_300)
        await lru.touch(a)
        try? await Task.sleep(for: .milliseconds(50))
        await lru.touch(b)
        try? await Task.sleep(for: .milliseconds(50))
        await lru.touch(c)
        await lru.enforce()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
    }

    func testUnderBudgetEvictsNothing() async {
        let a = makeEntry("a", bytes: 100)
        let lru = StreamCacheLRU(managedDirs: [root], budgetBytes: 1_000_000)
        await lru.touch(a)
        await lru.enforce()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testContinuesEvictionWhenOldestEntryCannotBeRemoved() async {
        let protectedRoot = root.appendingPathComponent("protected", isDirectory: true)
        let removableRoot = root.appendingPathComponent("removable", isDirectory: true)
        try! FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: removableRoot, withIntermediateDirectories: true)
        let protected = protectedRoot.appendingPathComponent("a", isDirectory: true)
        let removable = removableRoot.appendingPathComponent("b", isDirectory: true)
        try! FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: removable, withIntermediateDirectories: true)
        try! Data(repeating: 0, count: 600).write(to: protected.appendingPathComponent("blob"))
        try! Data(repeating: 0, count: 600).write(to: removable.appendingPathComponent("blob"))

        let lru = StreamCacheLRU(managedDirs: [protectedRoot, removableRoot], budgetBytes: 600)
        await lru.touch(protected)
        try? await Task.sleep(for: .milliseconds(50))
        await lru.touch(removable)
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protectedRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedRoot.path)
        }

        await lru.enforce()

        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
    }
}
