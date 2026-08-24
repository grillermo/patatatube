// ios/PatataTube/Sources/AudioMiniPlayerBar.swift
import SwiftUI
import PatataTubeKit

/// A persistent now-playing bar for audio-only playback (`AppModel.audio`),
/// docked above the tab bar in `RootTabView`. Visible app-wide for exactly as
/// long as `audio.currentID` is non-nil — the audio session itself already
/// outlives the list view that started it, so the bar follows the same
/// lifetime rather than the screen's.
struct AudioMiniPlayerBar: View {
    @ObservedObject var audio: AudioQueuePlayer
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    private var video: Video? {
        guard let id = audio.currentID else { return nil }
        return store.videos.first(where: { $0.id == id })
    }

    var body: some View {
        if let video, let scope = audio.currentScope {
            VStack(spacing: 10) {
                Button(action: audio.openFullScreen) {
                    HStack(spacing: 10) {
                        thumbnail(for: video)
                        Text(video.title ?? video.url)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack {
                    toggleButton(systemImage: "shuffle", isOn: model.randomizeBinding(for: scope))
                    Spacer()
                    Button(action: audio.skipBackward) {
                        Image(systemName: "backward.fill")
                    }
                    Spacer()
                    Button(action: audio.toggle) {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Spacer()
                    Button(action: audio.skipForward) {
                        Image(systemName: "forward.fill")
                    }
                    Spacer()
                    toggleButton(systemImage: "play.circle", filledSystemImage: "play.circle.fill",
                                 isOn: model.autoplayBinding(for: scope))
                }
                .font(.body)
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func thumbnail(for video: Video) -> some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil {
                AuthedImage(path: video.previewUrl, fill: !video.isPlexItem)
            }
        }
        .frame(width: 44, height: 44)
        .clipped()
        .cornerRadius(6)
    }

    /// A toggle drawn as a plain icon button: filled + accent-tinted when on,
    /// outline + secondary when off. `shuffle` has no SF Symbols fill variant,
    /// so it gets a filled accent circle behind it instead (icon turns white
    /// on that circle) to read as "active" the same way
    /// `play.circle`/`play.circle.fill` does on its own.
    private func toggleButton(systemImage: String, filledSystemImage: String? = nil, isOn: Binding<Bool>) -> some View {
        let on = isOn.wrappedValue
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            if let filledSystemImage {
                Image(systemName: on ? filledSystemImage : systemImage)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .background {
                        if on {
                            Circle().fill(Color.accentColor).frame(width: 26, height: 26)
                        }
                    }
            }
        }
    }
}
