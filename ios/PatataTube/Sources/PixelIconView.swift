// ios/PatataTube/Sources/PixelIconView.swift
import SwiftUI
import PatataTubeKit

/// A 64x64 PixelLab group icon, scaled up with nearest-neighbour sampling so
/// it stays crisp pixel art instead of a blur (which is what `AuthedImage`'s
/// default interpolation would give it).
///
/// Icon names are random and never reused (`/group-icons/<name>.png`), so the
/// bytes are cached on disk forever under that name: the group screen is
/// offline-first, and a card that shows its icon online must show it offline.
/// Until the icon is loaded — or if it can't be — `placeholder` shows instead.
struct PixelIconView<Placeholder: View>: View {
    let path: String
    @ViewBuilder var placeholder: () -> Placeholder

    @EnvironmentObject var model: AppModel
    @State private var image: UIImage?
    @State private var loadedPath: String?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder()
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        if image != nil && loadedPath == path { return }
        loadedPath = path
        if let cached = ImageMemoryCache.shared.data(for: path), let img = UIImage(data: cached) {
            image = img
            return
        }
        let file = Self.cacheFile(for: path)
        if let file, let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            ImageMemoryCache.shared.store(data, for: path)
            image = img
            return
        }
        guard let data = try? await model.api.imageData(path: path),
              let img = UIImage(data: data) else { return }
        ImageMemoryCache.shared.store(data, for: path)
        if let file {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
        image = img
    }

    /// Caches/group-icons/<name>.png — only for names shaped like the server's.
    static func cacheFile(for path: String) -> URL? {
        let name = (path as NSString).lastPathComponent
        guard name.range(of: #"^[0-9a-f]{32}\.png$"#, options: .regularExpression) != nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appendingPathComponent("group-icons", isDirectory: true)
            .appendingPathComponent(name)
    }
}

/// "Generate pixel icon" sheet. The user types what the icon should show,
/// PixelLab draws it (~30-40s), and the preview appears; they can edit the
/// prompt and regenerate as often as they like. Every preview from this
/// session stays in a strip below, so a good one isn't lost to a worse
/// regeneration. Nothing is attached to the group until "Use".
struct PixelIconGeneratorView: View {
    let group: VideoGroup
    let onUse: (GeneratedIcon) -> Void

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String
    @State private var previews: [GeneratedIcon] = []
    @State private var selected: GeneratedIcon?
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(group: VideoGroup, onUse: @escaping (GeneratedIcon) -> Void) {
        self.group = group
        self.onUse = onUse
        _prompt = State(initialValue: group.label)
    }

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should the icon show?", text: $prompt, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(generate)
                    Button(action: generate) {
                        HStack {
                            Label(previews.isEmpty ? "Generate" : "Regenerate",
                                  systemImage: previews.isEmpty ? "wand.and.stars" : "arrow.clockwise")
                            if generating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(trimmed.isEmpty || generating)
                } footer: {
                    Text("A 64×64 pixel-art icon drawn by PixelLab. Takes about 30 seconds.")
                }

                Section("Preview") {
                    preview
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if previews.count > 1 {
                    Section("Earlier tries") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(previews.reversed(), id: \.icon) { item in
                                    Button { selected = item } label: {
                                        PixelIconView(path: item.iconUrl) { ProgressView() }
                                            .frame(width: 64, height: 64)
                                            .padding(4)
                                            .background(.secondary.opacity(0.15),
                                                        in: RoundedRectangle(cornerRadius: 8))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(Color.accentColor,
                                                                  lineWidth: selected == item ? 3 : 0)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(group.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { if let selected { onUse(selected) } }
                        .disabled(selected == nil)
                }
            }
        }
        .onAppear { if previews.isEmpty { focused = true } }
        .onDisappear { task?.cancel() }
        .interactiveDismissDisabled(generating)
    }

    @ViewBuilder
    private var preview: some View {
        if generating && selected == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("Drawing “\(trimmed)”…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let selected {
            PixelIconView(path: selected.iconUrl) { ProgressView() }
                .frame(width: 192, height: 192)
                .opacity(generating ? 0.4 : 1)
                .overlay { if generating { ProgressView() } }
        } else {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }

    private func generate() {
        guard !trimmed.isEmpty, !generating else { return }
        focused = false
        generating = true
        error = nil
        let text = trimmed
        task = Task {
            defer { generating = false }
            do {
                let icon = try await model.api.generateIcon(prompt: text)
                previews.append(icon)
                selected = icon
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch APIError.badStatus(let status) {
                self.error = switch status {
                case 429: "Out of PixelLab credits."
                case 503: "Icon generation isn't set up on the server (PIXELLABS_API_TOKEN)."
                default: "Generation failed (\(status)). Try again or change the prompt."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
