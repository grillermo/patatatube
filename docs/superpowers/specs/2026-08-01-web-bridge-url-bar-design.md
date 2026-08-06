# Web bridge URL bar — design

Date: 2026-08-01
Status: approved, pending implementation

## Problem

`WebBridgeView` (iOS) hosts one hardcoded page — `https://awh.chiq.me/live` — with
no address UI. Changing the page means editing `WebBridgeView.defaultURL` and
rebuilding. The sheet should let the user type any URL, follow links, and reopen
on whatever page they were last on.

## Scope

- URL bar pinned above the web view inside the existing sheet.
- History of visited pages, persisted across app launches.
- Fuzzy search over that history as you type, with a suggestion list.
- Back / forward / reload controls.

Out of scope: search-engine fallback (no Google query on unparseable input),
tabs, bookmarks UI, per-site settings, changing the `soundBridge` JS contract.

## Behavior

### Address field

- Not focused: shows the live current URL, updated on every committed
  navigation (link taps included).
- Focused with non-empty text: a suggestion list overlays the top of the web
  view, listing fuzzy matches from history, most-recent-first.
- Enter: navigate to the top suggestion if any match exists; otherwise resolve
  the raw text (see below). If it resolves to nothing, do not navigate — revert
  the field text to the current URL.
- Tapping a suggestion navigates to it and dismisses the list.

### Fuzzy matching

Query is lowercased and split on whitespace. Spaces are wildcards: every token
must appear in the candidate URL string **in order**, so `awh live` matches
`https://awh.chiq.me/live`. Matching is over the full URL string (scheme
included, so `https` is itself a legal token). Results are ordered by recency.
Empty query yields the full history, most-recent-first.

### Address resolution (no matches)

- Text already carries a scheme → use as-is.
- Bare host/path (`awh.chiq.me/live`) → prepend `https://`.
- Anything that still fails to parse as a URL with a host → nil, no navigation.

### History

Every committed navigation is recorded, not just typed entries. Entries dedupe
by normalized URL string (the existing entry's timestamp is refreshed rather
than a duplicate appended), newest first, capped at 200. The sheet opens on the
newest entry, falling back to `https://awh.chiq.me/live` when history is empty.

## Components

### `WebHistoryStore` (PatataTubeKit)

The whole logic layer, free of WebKit and SwiftUI so it is testable with
`swift test`.

```swift
struct WebHistoryEntry: Codable, Equatable { let url: String; let lastVisited: Date }

final class WebHistoryStore {
    init(defaults: UserDefaults = .standard, limit: Int = 200)
    var entries: [WebHistoryEntry] { get }     // newest first
    var lastURL: URL? { get }
    func record(_ url: URL)
    func search(_ query: String) -> [WebHistoryEntry]
}
```

Persisted as JSON under `UserDefaults` key `webBridgeHistory`. `UserDefaults` is
injected so tests use a scratch suite.

### `WebAddress` (PatataTubeKit)

```swift
enum WebAddress { static func resolve(_ text: String) -> URL? }
```

Pure function, no state — the scheme-fill rules above.

### `WebBridgeView` / `SoundBridgeWebView` (app target)

- Toolbar row above the web view: back, forward, `TextField`, reload, and a
  recents menu button listing the 15 newest entries so history is reachable
  without typing. `Done` stays where it is, in the navigation bar.
- Back/forward call `goBack()`/`goForward()` and are disabled per
  `canGoBack`/`canGoForward`.
- `Coordinator` gains `WKNavigationDelegate` and becomes an `ObservableObject`
  publishing `currentURL`, `canGoBack`, `canGoForward`; `didCommit` drives both
  the field text and `WebHistoryStore.record`. The existing `soundBridge`
  message handling is unchanged, as is `dismantleUIView`'s handler teardown.
- `WebBridgeView`'s `url` init parameter goes away; the start URL comes from
  `WebHistoryStore.lastURL`. `VideoGridView`'s `.sheet { WebBridgeView() }` call
  site is untouched.

## Logging

`DevLog.event(.nav, "web bridge navigate", ["host": url.host ?? ""])` on commit.
Host only — never full URLs with query strings, per the existing DevLog rule
that records carry ids and statuses, not payloads.

## Error handling

Nothing here can fail loudly. Unparseable input is a no-op with the field
reverting. Corrupt or undecodable persisted JSON is treated as an empty history
and overwritten on the next `record`. A failed page load is WebKit's own error
page; the bar keeps showing the attempted URL.

## Testing

`ios/PatataTubeKit` `swift test`:

- fuzzy match: single token, multi-token wildcard, ordering enforced (`live awh`
  does not match `awh.chiq.me/live`), case insensitivity
- ranking by recency; empty query returns everything
- dedupe refreshes timestamp and reorders instead of appending
- cap at 200 evicts oldest
- `lastURL` empty-history fallback is nil (view supplies the default)
- `WebAddress.resolve`: scheme passthrough, bare host fill, path fill, garbage → nil

No iOS UI test target exists; the bar, suggestion list, and back/forward states
are verified manually per `ios/README.md`.
