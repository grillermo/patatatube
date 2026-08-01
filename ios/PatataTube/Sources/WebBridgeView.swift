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
                    model.setAddressFocused(focused)
                }
                .onChange(of: model.addressText) { _, _ in model.refreshSuggestions() }

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
    /// Tracks whether the address `TextField` is focused, so a background page
    /// commit (redirect, `didFinish` chatter) never clobbers text the user is
    /// still typing. Kept in the model — not `@FocusState` — because
    /// `didCommit` runs from the coordinator, outside the view.
    private var isAddressFieldFocused = false

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

    /// Called by the view whenever the address field's focus changes. Losing
    /// focus normally reverts the field to the current URL, but not when a
    /// navigation is already in flight (`pendingURL != nil`) — otherwise the
    /// field would flash back to the old URL for the moment between submit
    /// and the new page's `didCommit`.
    func setAddressFocused(_ focused: Bool) {
        isAddressFieldFocused = focused
        if !focused && pendingURL == nil {
            resetAddressText()
        }
    }

    func refreshSuggestions() {
        suggestions = addressText == currentURL.absoluteString ? [] : history.search(addressText)
    }

    /// Called by the coordinator once WebKit commits a page.
    func didCommit(url: URL, canGoBack: Bool, canGoForward: Bool) {
        currentURL = url
        if !isAddressFieldFocused {
            addressText = url.absoluteString
        }
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

    /// `@Published` fires `objectWillChange` on every set, changed or not.
    /// Both consumers below must not write when the value is already at rest
    /// (`nil` / `.none`) — an unconditional `= nil` here would re-publish on
    /// every `updateUIView` call, including the ones it itself triggers,
    /// turning that into a self-sustaining re-render loop.
    fileprivate func consumePending() -> URL? {
        guard let url = pendingURL else { return nil }
        pendingURL = nil
        return url
    }

    fileprivate func consumeCommand() -> Command {
        guard command != .none else { return .none }
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
