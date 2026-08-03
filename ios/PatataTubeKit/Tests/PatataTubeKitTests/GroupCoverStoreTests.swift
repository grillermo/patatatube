import XCTest
@testable import PatataTubeKit

final class GroupCoverStoreTests: XCTestCase {
    private func makeStore() -> GroupCoverStore {
        let suite = "groupcover.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return GroupCoverStore(defaults: defaults)
    }

    func testUnsetGroupHasNoCover() {
        XCTAssertNil(makeStore().cover(for: "children"))
    }

    func testStoresASingleEmoji() {
        let store = makeStore()
        store.setCover("🐸", for: "children")
        XCTAssertEqual(store.cover(for: "children"), "🐸")
    }

    func testKeepsOnlyTheFirstEmojiOfLongerText() {
        let store = makeStore()
        store.setCover("🐸 frogs 🎈", for: "children")
        XCTAssertEqual(store.cover(for: "children"), "🐸")
    }

    func testTextWithoutEmojiClearsTheCover() {
        let store = makeStore()
        store.setCover("🐸", for: "children")
        store.setCover("frogs", for: "children")
        XCTAssertNil(store.cover(for: "children"))
    }

    func testEmptyAndNilClearTheCover() {
        let store = makeStore()
        store.setCover("🐸", for: "children")
        store.setCover("", for: "children")
        XCTAssertNil(store.cover(for: "children"))
        store.setCover("🐸", for: "children")
        store.setCover(nil, for: "children")
        XCTAssertNil(store.cover(for: "children"))
    }

    func testCompositeEmojiStaysOneGrapheme() {
        let store = makeStore()
        store.setCover("👩‍👩‍👧", for: "adults")
        XCTAssertEqual(store.cover(for: "adults"), "👩‍👩‍👧")
        store.setCover("🇪🇸", for: "asmr")
        XCTAssertEqual(store.cover(for: "asmr"), "🇪🇸")
    }

    func testIgnoresNonVideoGroups() {
        let store = makeStore()
        store.setCover("🐸", for: "tv")
        XCTAssertNil(store.cover(for: "tv"))
    }

    func testApplyMirrorsTheServer() {
        let store = makeStore()
        let covers = store.apply(["children": "🐸", "asmr": "🎧"])
        XCTAssertEqual(store.cover(for: "children"), "🐸")
        XCTAssertEqual(store.cover(for: "asmr"), "🎧")
        XCTAssertNil(store.cover(for: "adults"))
        XCTAssertEqual(covers, ["children": "🐸", "asmr": "🎧"])
    }

    func testApplyClearsCoversTheServerNoLongerHas() {
        let store = makeStore()
        store.setCover("🐸", for: "children")
        store.apply([:])
        XCTAssertNil(store.cover(for: "children"))
    }

    func testApplyIgnoresUnknownGroups() {
        let store = makeStore()
        store.apply(["tv": "📺"])
        XCTAssertNil(store.cover(for: "tv"))
    }

    func testGroupsGetSeparateKeys() {
        XCTAssertNotEqual(GroupCoverStore.key("children"), GroupCoverStore.key("adults"))
    }
}
