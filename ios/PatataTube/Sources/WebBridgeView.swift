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
struct WebBridgeView: View {
    @Environment(\.dismiss) private var dismiss

    static let defaultURL = URL(string: "https://awh.chiq.me/live")!

    let url: URL

    init(url: URL = WebBridgeView.defaultURL) {
        self.url = url
    }

    var body: some View {
        NavigationStack {
            SoundBridgeWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Live")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct SoundBridgeWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "soundBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // The user content controller retains the handler; drop it so the
        // coordinator (and the web view) can deallocate with the sheet.
        uiView.configuration.userContentController
            .removeScriptMessageHandler(forName: "soundBridge")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
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
    }
}
