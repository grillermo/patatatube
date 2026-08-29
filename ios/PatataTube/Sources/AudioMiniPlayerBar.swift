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

    /// How far the bar has been dragged down, in points. Only downward drags
    /// move it — dragging up would uncover the tab bar it is docked over.
    @State private var dragOffset: CGFloat = 0

    /// A downward flick past this distance dismisses; anything shorter
    /// springs back. A fast flick counts even when short, via the gesture's
    /// predicted end translation.
    private static let dismissDistance: CGFloat = 60

    private var video: Video? {
        if let current = audio.currentVideo { return current }
        guard let id = audio.currentID else { return nil }
        return store.videos.first(where: { $0.id == id })
    }

    var body: some View {
        if let video, let scope = audio.currentScope {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
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

                    closeButton
                }

                HStack {
                    toggleButton(systemImage: "shuffle", isOn: model.randomizeBinding(for: scope))
                    Spacer()
                    Button(action: audio.skipBackward) {
                        Image(systemName: "backward.fill")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                    Button(action: audio.toggle) {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36))
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                    Button(action: audio.skipForward) {
                        Image(systemName: "forward.fill")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                    toggleButton(systemImage: "play.circle", filledSystemImage: "play.circle.fill",
                                 isOn: model.autoplayBinding(for: scope))
                }
                .font(.system(size: 26))
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .offset(y: dragOffset)
            .gesture(dismissDrag)
        }
    }

    /// Flick-down-to-dismiss. `minimumDistance` keeps a tap on any of the
    /// buttons underneath from being read as a drag, and the offset is
    /// clamped at 0 so only downward movement tracks the finger.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let travelled = max(value.translation.height, value.predictedEndTranslation.height)
                if travelled > Self.dismissDistance {
                    dismiss(reason: "flick")
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { dragOffset = 0 }
                }
            }
    }

    /// Deliberately smaller than the transport controls below it: dismissing
    /// is the one action here you never want to hit by accident while
    /// reaching for play/pause.
    private var closeButton: some View {
        Button {
            dismiss(reason: "button")
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close mini player")
    }

    /// Stopping the queue is what removes the bar — it renders only while
    /// `audio.currentID` is non-nil — so the offset has to be reset here or
    /// the next track's bar would appear already dragged away.
    private func dismiss(reason: String) {
        DevLog.event(.tap, "audio bar dismissed", ["reason": reason])
        audio.stop()
        dragOffset = 0
    }

    private func thumbnail(for video: Video) -> some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil {
                AuthedImage(path: video.previewUrl, fill: !video.isPlexItem)
                    .id(video.id)
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
            Group {
                if let filledSystemImage {
                    Image(systemName: on ? filledSystemImage : systemImage)
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .background {
                            if on {
                                Circle().fill(Color.accentColor).frame(width: 40, height: 40)
                            }
                        }
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}
