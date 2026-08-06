# Web Bridge URL Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the in-app web view (`WebBridgeView`) an address bar with fuzzy history search, back/forward/reload, and a start page remembered across launches.

**Architecture:** All logic lands in the `PatataTubeKit` SwiftPM package as two
new units — `WebAddress` (pure text → URL resolution) and `WebHistoryStore`
(UserDefaults-backed visit history + fuzzy search) — both testable with
`swift test`. The SwiftUI/WebKit layer in `ios/PatataTube/Sources/WebBridgeView.swift`
grows a toolbar row and a suggestion overlay, and its existing `Coordinator`
becomes a `WKNavigationDelegate` + `ObservableObject` that publishes the current
URL and back/forward availability. The `soundBridge` JS message contract is
untouched.

**Tech Stack:** Swift 6, SwiftUI, WebKit, swift-testing (`import Testing`,
`@Test`, `#expect`), SwiftPM (`ios/PatataTubeKit`), XcodeGen (`ios/PatataTube/project.yml`).

Spec: `docs/superpowers/specs/2026-08-01-web-bridge-url-bar-design.md`.

## Global Constraints

- Package target platforms are `.iOS(.v17), .macOS(.v14)` — no API newer than iOS 17.
- New PatataTubeKit types are `public`; the app target imports the package.
- Tests use swift-testing (`import Testing`, `struct` suites, `@Test`, `#expect`),
  **not** XCTest. Match `Tests/PatataTubeKitTests/BoundedTaskGroupTests.swift`.
- Run `swift test` from `ios/PatataTubeKit`. A pre-existing, unrelated
  `Fatal error: Index out of range` prints during full parallel runs; every test
  still reports passing. Ignore it.
- No new SwiftPM dependencies.
- Instrumentation uses `DevLog.event` / `DevLog.error` only — never `print`.
  Records carry hosts, ids and statuses; **never full URLs with query strings,
  never tokens.**
- History cap is 200 entries. UserDefaults key is exactly `webBridgeHistory`.
- Fallback start page is exactly `https://awh.chiq.me/live`.
- `docs/` is gitignored in this repo; plan and spec files are not committed. Do
  not `git add -f` them.

## File Structure

| File | Responsibility |
|---|---|
| `ios/PatataTubeKit/Sources/PatataTubeKit/WebAddress.swift` (create) | Pure `resolve(_ text:) -> URL?`: scheme passthrough, `https://` fill, nil for garbage. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift` (create) | `WebHistoryEntry` model + UserDefaults-backed store: `record`, `entries`, `lastURL`, `search`. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebAddressTests.swift` (create) | Resolution rules. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift` (create) | Dedupe, cap, ordering, fuzzy search, persistence round-trip. |
| `ios/PatataTube/Sources/WebBridgeView.swift` (modify) | Toolbar row, address field, suggestion overlay, navigation-delegate coordinator. |

`VideoGridView.swift:233` (`.sheet(isPresented: $showWebBridge) { WebBridgeView() }`)
needs no change — `WebBridgeView()` keeps working after its `url` parameter is
replaced by a store-derived start URL.

---

### Task 1: `WebAddress` — text to URL resolution

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/WebAddress.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebAddressTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum WebAddress { public static func resolve(_ text: String) -> URL? }`

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebAddressTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

struct WebAddressTests {
    @Test func keepsAnExplicitScheme() {
        #expect(WebAddress.resolve("https://awh.chiq.me/live")?.absoluteString
                == "https://awh.chiq.me/live")
        #expect(WebAddress.resolve("http://example.com")?.absoluteString
                == "http://example.com")
    }

    @Test func fillsHTTPSForABareHost() {
        #expect(WebAddress.resolve("awh.chiq.me")?.absoluteString
                == "https://awh.chiq.me")
    }

    @Test func fillsHTTPSForABareHostWithPath() {
        #expect(WebAddress.resolve("awh.chiq.me/live")?.absoluteString
                == "https://awh.chiq.me/live")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(WebAddress.resolve("  awh.chiq.me/live  ")?.absoluteString
                == "https://awh.chiq.me/live")
    }

    @Test func rejectsTextWithoutAHost() {
        #expect(WebAddress.resolve("cat videos") == nil)
        #expect(WebAddress.resolve("") == nil)
        #expect(WebAddress.resolve("   ") == nil)
        #expect(WebAddress.resolve("localpage") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter WebAddressTests`
Expected: FAIL — `cannot find 'WebAddress' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/WebAddress.swift`:

```swift
import Foundation

/// Turns whatever the user typed in the web bridge's address bar into a URL.
///
/// There is no search-engine fallback here by design: text that is not an
/// address resolves to `nil` and the caller declines to navigate.
public enum WebAddress {
    /// - Returns: the text as a URL, prepending `https://` when it carries no
    ///   scheme, or `nil` when the result would have no host (`"cat videos"`,
    ///   `"localpage"`, empty input).
    public static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter WebAddressTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/WebAddress.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/WebAddressTests.swift
git commit -m "feat(ios): resolve typed text into web bridge URLs"
```

---

### Task 2: `WebHistoryStore` — persistence, dedupe, cap

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `public struct WebHistoryEntry: Codable, Equatable, Sendable { public let url: String; public let lastVisited: Date }`
  - `public final class WebHistoryStore: @unchecked Sendable`
    - `public init(defaults: UserDefaults = .standard, limit: Int = 200)`
    - `public var entries: [WebHistoryEntry] { get }` — newest first
    - `public var lastURL: URL? { get }`
    - `public func record(_ url: URL)`
    - `public func search(_ query: String) -> [WebHistoryEntry]` (added in Task 3)

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

/// Each test gets its own defaults suite so runs never bleed into each other
/// or into the developer's real `standard` defaults.
private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func url(_ s: String) -> URL { URL(string: s)! }

struct WebHistoryStoreTests {
    @Test func startsEmpty() {
        let store = WebHistoryStore(defaults: makeDefaults())
        #expect(store.entries.isEmpty)
        #expect(store.lastURL == nil)
    }

    @Test func recordsNewestFirst() {
        let store = WebHistoryStore(defaults: makeDefaults())
        store.record(url("https://a.example.com/one"))
        store.record(url("https://b.example.com/two"))

        #expect(store.entries.map(\.url) == ["https://b.example.com/two",
                                             "https://a.example.com/one"])
        #expect(store.lastURL == url("https://b.example.com/two"))
    }

    @Test func revisitingMovesToFrontWithoutDuplicating() {
        let store = WebHistoryStore(defaults: makeDefaults())
        store.record(url("https://a.example.com/one"))
        store.record(url("https://b.example.com/two"))
        store.record(url("https://a.example.com/one"))

        #expect(store.entries.map(\.url) == ["https://a.example.com/one",
                                             "https://b.example.com/two"])
        #expect(store.entries.count == 2)
    }

    @Test func evictsTheOldestBeyondTheLimit() {
        let store = WebHistoryStore(defaults: makeDefaults(), limit: 3)
        for i in 1...5 { store.record(url("https://example.com/\(i)")) }

        #expect(store.entries.map(\.url) == ["https://example.com/5",
                                             "https://example.com/4",
                                             "https://example.com/3"])
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        WebHistoryStore(defaults: defaults).record(url("https://a.example.com/one"))

        let reopened = WebHistoryStore(defaults: defaults)
        #expect(reopened.lastURL == url("https://a.example.com/one"))
    }

    @Test func treatsCorruptStorageAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "webBridgeHistory")

        let store = WebHistoryStore(defaults: defaults)
        #expect(store.entries.isEmpty)

        store.record(url("https://a.example.com/one"))
        #expect(store.entries.map(\.url) == ["https://a.example.com/one"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter WebHistoryStoreTests`
Expected: FAIL — `cannot find 'WebHistoryStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift`:

```swift
import Foundation

/// One visited page in the web bridge's address history.
public struct WebHistoryEntry: Codable, Equatable, Sendable {
    public let url: String
    public let lastVisited: Date

    public init(url: String, lastVisited: Date) {
        self.url = url
        self.lastVisited = lastVisited
    }
}

/// Address history for the in-app web view, backed by `UserDefaults`.
///
/// Every committed navigation is recorded — link taps included — deduped by
/// absolute URL string, newest first, capped at `limit`. Nothing here throws:
/// unreadable storage is treated as an empty history and overwritten on the
/// next `record`, because a broken history must never block browsing.
public final class WebHistoryStore: @unchecked Sendable {
    public static let storageKey = "webBridgeHistory"

    private let defaults: UserDefaults
    private let limit: Int
    private let lock = NSLock()
    private var cache: [WebHistoryEntry]

    public init(defaults: UserDefaults = .standard, limit: Int = 200) {
        self.defaults = defaults
        self.limit = max(1, limit)
        let data = defaults.data(forKey: Self.storageKey)
        self.cache = data.flatMap { try? JSONDecoder().decode([WebHistoryEntry].self, from: $0) } ?? []
    }

    /// Newest first.
    public var entries: [WebHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// The page the web view should open on, or `nil` when nothing was visited yet.
    public var lastURL: URL? {
        entries.first.flatMap { URL(string: $0.url) }
    }

    public func record(_ url: URL, now: Date = Date()) {
        let key = url.absoluteString
        lock.lock()
        cache.removeAll { $0.url == key }
        cache.insert(WebHistoryEntry(url: key, lastVisited: now), at: 0)
        if cache.count > limit { cache.removeLast(cache.count - limit) }
        let snapshot = cache
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter WebHistoryStoreTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift
git commit -m "feat(ios): persist web bridge address history"
```

---

### Task 3: Fuzzy search over history

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift` (add `search`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift` (add a suite)

**Interfaces:**
- Consumes: `WebHistoryStore` and `WebHistoryEntry` from Task 2.
- Produces: `public func search(_ query: String) -> [WebHistoryEntry]` — whitespace-separated
  tokens act as wildcards that must appear **in order**, case-insensitively, within the
  full URL string; results newest first; empty/blank query returns all entries.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift`:

```swift
struct WebHistorySearchTests {
    private func seeded() -> WebHistoryStore {
        let store = WebHistoryStore(defaults: makeDefaults())
        store.record(url("https://awh.chiq.me/live"))
        store.record(url("https://example.com/videos/cats"))
        store.record(url("https://awh.chiq.me/archive"))
        return store   // newest first: archive, cats, live
    }

    @Test func blankQueryReturnsEverythingNewestFirst() {
        #expect(seeded().search("   ").map(\.url) == ["https://awh.chiq.me/archive",
                                                      "https://example.com/videos/cats",
                                                      "https://awh.chiq.me/live"])
    }

    @Test func matchesASingleSubstring() {
        #expect(seeded().search("cats").map(\.url) == ["https://example.com/videos/cats"])
    }

    @Test func spacesActAsWildcards() {
        #expect(seeded().search("awh live").map(\.url) == ["https://awh.chiq.me/live"])
    }

    @Test func tokensMustAppearInOrder() {
        #expect(seeded().search("live awh").isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(seeded().search("AWH ARCHIVE").map(\.url) == ["https://awh.chiq.me/archive"])
    }

    @Test func multipleMatchesStayNewestFirst() {
        #expect(seeded().search("awh").map(\.url) == ["https://awh.chiq.me/archive",
                                                      "https://awh.chiq.me/live"])
    }

    @Test func noMatchesIsEmpty() {
        #expect(seeded().search("nonesuch").isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter WebHistorySearchTests`
Expected: FAIL — `value of type 'WebHistoryStore' has no member 'search'`.

- [ ] **Step 3: Write minimal implementation**

Add to `WebHistoryStore` in `ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift`,
after `record`:

```swift
    /// Fuzzy-matches history by treating whitespace in `query` as wildcards:
    /// every token must occur, in order, somewhere in the URL string. So
    /// `"awh live"` finds `https://awh.chiq.me/live` but `"live awh"` does not.
    /// A blank query returns the whole history. Results stay newest first.
    public func search(_ query: String) -> [WebHistoryEntry] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return entries }

        return entries.filter { entry in
            var remainder = Substring(entry.url.lowercased())
            for token in tokens {
                guard let hit = remainder.range(of: token) else { return false }
                remainder = remainder[hit.upperBound...]
            }
            return true
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter WebHistory`
Expected: PASS, 13 tests (6 from Task 2 + 7 here).

- [ ] **Step 5: Run the whole package suite in both configurations**

Run: `cd ios/PatataTubeKit && swift test && swift test -c release`
Expected: every test passes in both. The pre-existing unrelated
`Fatal error: Index out of range` may print; it is not a failure.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/WebHistoryStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/WebHistoryStoreTests.swift
git commit -m "feat(ios): fuzzy-search web bridge history with wildcard spaces"
```

---

### Task 4: Address bar UI in `WebBridgeView`

**Files:**
- Modify: `ios/PatataTube/Sources/WebBridgeView.swift` (whole file rewritten below)
- Test: none automated — no iOS UI test target exists. Manual checklist in Step 4.

**Interfaces:**
- Consumes: `WebAddress.resolve(_:) -> URL?` (Task 1); `WebHistoryStore` with
  `entries`, `lastURL`, `record(_:now:)`, `search(_:) -> [WebHistoryEntry]`
  (Tasks 2–3).
- Produces: `WebBridgeView()` — same no-argument initializer `VideoGridView.swift:233`
  already calls. The `url:` parameter is gone; the start page comes from
  `WebHistoryStore.lastURL`, falling back to `https://awh.chiq.me/live`.

- [ ] **Step 1: Rewrite the view**

Replace the entire contents of `ios/PatataTube/Sources/WebBridgeView.swift`:

```swift
// ios/PatataTube/Sources/WebBridgeView.swift
import SwiftUI
import WebKit
import MediaPlayer
import PatataTubeKit

/// A web page hosted in-app that can drive native audio through a JS bridge.
///
/// The page posts `window.webkit.messageHandlers.soundBridge.postMessage("playSound")`
/// and the coordinator toggles `MPMusicPlayerController.systemMusicPlayer`.
/// Nothing else crosses the bridge — unknown message bodies are ignored.
///
/// The address bar on top drives navigation: typing fuzzy-searches visited
/// pages (spaces are wildcards), and text matching nothing is resolved as a
/// URL instead. The sheet reopens on whatever page was last committed.
struct WebBridgeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: WebBridgeModel
    @FocusState private var addressFocused: Bool

    static let defaultURL = URL(string: "https://awh.chiq.me/live")!

    init(history: WebHistoryStore = WebHistoryStore()) {
        _model = StateObject(wrappedValue: WebBridgeModel(history: history,
                                                          fallback: WebBridgeView.defaultURL))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                Divider()
                ZStack(alignment: .top) {
                    SoundBridgeWebView(model: model)
                        .ignoresSafeArea(edges: .bottom)
                    if addressFocused && !model.suggestions.isEmpty {
                        suggestionList
                    }
                }
            }
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 12) {
            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward)

            TextField("Address", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    model.submit()
                    addressFocused = false
                }
                .onChange(of: addressFocused) { _, focused in
                    if !focused { model.resetAddressText() }
                }

            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }

            Menu {
                if model.history.entries.isEmpty {
                    Text("No history yet")
                } else {
                    ForEach(model.history.entries.prefix(15), id: \.url) { entry in
                        Button(entry.url) { model.open(entry) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var suggestionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.suggestions, id: \.url) { entry in
                    Button {
                        model.open(entry)
                        addressFocused = false
                    } label: {
                        Text(entry.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 260)
        .background(.regularMaterial)
    }
}

/// Owns the address-bar state and the navigation commands the web view obeys.
///
/// The view never touches `WKWebView` directly: it mutates `pendingURL` and
/// `command`, and `SoundBridgeWebView.updateUIView` applies them.
@MainActor
final class WebBridgeModel: ObservableObject {
    enum Command: Equatable { case none, back, forward, reload }

    @Published var addressText: String
    @Published private(set) var suggestions: [WebHistoryEntry] = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published fileprivate var pendingURL: URL?
    @Published fileprivate var command: Command = .none

    let history: WebHistoryStore
    private(set) var currentURL: URL

    init(history: WebHistoryStore, fallback: URL) {
        self.history = history
        let start = history.lastURL ?? fallback
        self.currentURL = start
        self.addressText = start.absoluteString
        self.pendingURL = start
    }

    /// Enter: the top fuzzy match wins; with no matches the text is resolved as
    /// an address; unresolvable text navigates nowhere and the field reverts.
    func submit() {
        if let top = suggestions.first, let url = URL(string: top.url) {
            navigate(to: url)
        } else if let url = WebAddress.resolve(addressText) {
            navigate(to: url)
        } else {
            resetAddressText()
        }
    }

    func open(_ entry: WebHistoryEntry) {
        guard let url = URL(string: entry.url) else { return }
        navigate(to: url)
    }

    func goBack() { command = .back }
    func goForward() { command = .forward }
    func reload() { command = .reload }

    func resetAddressText() {
        addressText = currentURL.absoluteString
        suggestions = []
    }

    func refreshSuggestions() {
        suggestions = addressText == currentURL.absoluteString ? [] : history.search(addressText)
    }

    /// Called by the coordinator once WebKit commits a page.
    func didCommit(url: URL, canGoBack: Bool, canGoForward: Bool) {
        currentURL = url
        addressText = url.absoluteString
        suggestions = []
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        history.record(url)
        DevLog.event(.nav, "web bridge navigate", ["host": url.host ?? ""])
    }

    func updateNavigationState(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    private func navigate(to url: URL) {
        suggestions = []
        addressText = url.absoluteString
        pendingURL = url
    }

    fileprivate func consumePending() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    fileprivate func consumeCommand() -> Command {
        defer { command = .none }
        return command
    }
}

struct SoundBridgeWebView: UIViewRepresentable {
    @ObservedObject var model: WebBridgeModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "soundBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        if let url = model.consumePending() {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        switch model.consumeCommand() {
        case .back where uiView.canGoBack: uiView.goBack()
        case .forward where uiView.canGoForward: uiView.goForward()
        case .reload: uiView.reload()
        default: break
        }
        if let url = model.consumePending() {
            uiView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // The user content controller retains the handler; drop it so the
        // coordinator (and the web view) can deallocate with the sheet.
        uiView.configuration.userContentController
            .removeScriptMessageHandler(forName: "soundBridge")
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let model: WebBridgeModel

        init(model: WebBridgeModel) { self.model = model }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "soundBridge",
                  let body = message.body as? String,
                  body == "playSound" else { return }

            let musicPlayer = MPMusicPlayerController.systemMusicPlayer
            if musicPlayer.playbackState == .playing {
                musicPlayer.pause()
            } else {
                musicPlayer.play()
            }
            DevLog.event(.tap, "sound bridge toggle",
                         ["state": String(musicPlayer.playbackState.rawValue)])
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            MainActor.assumeIsolated {
                model.didCommit(url: url,
                                canGoBack: webView.canGoBack,
                                canGoForward: webView.canGoForward)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                model.updateNavigationState(canGoBack: webView.canGoBack,
                                            canGoForward: webView.canGoForward)
            }
        }
    }
}
```

- [ ] **Step 2: Wire live suggestions**

`refreshSuggestions()` needs a trigger. Add this modifier to the `TextField` in
`addressBar`, directly after `.onSubmit { … }`:

```swift
                .onChange(of: model.addressText) { _, _ in model.refreshSuggestions() }
```

- [ ] **Step 3: Build**

Run:

```bash
cd ios/PatataTubeKit && swift build
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: BUILD SUCCEEDED. `xcodegen` picks up `WebBridgeView.swift` automatically —
sources are globbed, so no `project.yml` edit is needed.

- [ ] **Step 4: Manual verification in the Simulator**

Run the app from Xcode, tap the live-page button in the grid
(`VideoGridView.swift:177`), and confirm each of:

1. Sheet opens on `https://awh.chiq.me/live` on a fresh install.
2. Typing `awh` after visiting a couple of pages shows a suggestion list;
   tapping a row navigates and dismisses the list.
3. Typing `awh live` (space as wildcard) matches `awh.chiq.me/live`.
4. Typing `example.com` with no history match and hitting Go navigates to
   `https://example.com`.
5. Typing `cat videos` and hitting Go does nothing and the field reverts to the
   current URL.
6. Tapping a link inside the page updates the address field.
7. Back/forward enable and disable correctly; reload reloads.
7b. The clock button lists recent pages (up to 15) without typing; picking one
    navigates. On a fresh install it reads "No history yet".
8. Closing and reopening the sheet — and force-quitting and relaunching the app —
   reopens on the last committed page.
9. The existing sound bridge still toggles music from the page.
10. `grep '"kind":"nav"' log/ios.jsonl` shows `web bridge navigate` records
    carrying a `host` and **no full URL**.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/WebBridgeView.swift
git commit -m "feat(ios): address bar with history search in the web bridge"
```

---

### Task 5: Document the feature

**Files:**
- Modify: `CLAUDE.md` (iOS section)

- [ ] **Step 1: Add the note**

In `CLAUDE.md`, under `### iOS`, append a bullet:

```markdown
- **The in-app web bridge has an address bar.** `WebBridgeView` opens on the
  last committed page (`WebHistoryStore.lastURL`, `UserDefaults` key
  `webBridgeHistory`, 200 entries) rather than a hardcoded URL. Typing
  fuzzy-searches that history — whitespace is a wildcard, tokens must match in
  order — and text matching nothing goes through `WebAddress.resolve`, which
  fills in `https://` and refuses anything without a host. There is deliberately
  no search-engine fallback.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note the web bridge address bar"
```

---

## Notes for the implementer

- `MainActor.assumeIsolated` in the coordinator is safe: `WKNavigationDelegate`
  callbacks arrive on the main thread. Do not swap it for a `Task { @MainActor }`,
  which would let the address bar lag a page behind.
- `WebHistoryStore()` defaults to `UserDefaults.standard`; `WebBridgeView.init`
  takes it as a parameter purely so a future preview or test can inject a scratch suite.
- Do not touch the `soundBridge` message name, its `"playSound"` body, or the
  `removeScriptMessageHandler` teardown — the retain cycle that teardown breaks
  is the reason it exists.
