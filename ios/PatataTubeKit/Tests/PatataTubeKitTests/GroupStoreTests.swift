import XCTest
@testable import PatataTubeKit

final class GroupStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "GroupStoreTests-\(UUID().uuidString)")!
    }

    private let sample = [
        VideoGroup(id: 1, name: "children", label: "Children", emoji: "🧒", position: 0),
        VideoGroup(id: 2, name: "adults", label: "Adults", emoji: nil, position: 1),
    ]

    func testStartsEmptyWithNoMirror() {
        XCTAssertEqual(GroupStore(defaults: makeDefaults()).groups, [])
    }

    func testApplyPersistsAndRepublishes() {
        let defaults = makeDefaults()
        let store = GroupStore(defaults: defaults)
        store.apply(sample)
        XCTAssertEqual(store.groups.map(\.name), ["children", "adults"])
        XCTAssertEqual(GroupStore(defaults: defaults).groups, sample)
    }

    func testApplySortsByPosition() {
        let store = GroupStore(defaults: makeDefaults())
        store.apply([sample[1], sample[0]])
        XCTAssertEqual(store.groups.map(\.id), [1, 2])
    }

    func testApplyDropsGroupsTheServerNoLongerHas() {
        let defaults = makeDefaults()
        let store = GroupStore(defaults: defaults)
        store.apply(sample)
        store.apply([sample[0]])
        XCTAssertEqual(store.groups.map(\.id), [1])
    }

    func testLookupByIDAndName() {
        let store = GroupStore(defaults: makeDefaults())
        store.apply(sample)
        XCTAssertEqual(store.group(id: 2)?.name, "adults")
        XCTAssertEqual(store.group(named: "children")?.id, 1)
        XCTAssertNil(store.group(id: 99))
    }

    func testSurvivesACorruptMirror() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: GroupStore.defaultsKey)
        XCTAssertEqual(GroupStore(defaults: defaults).groups, [])
    }
}
