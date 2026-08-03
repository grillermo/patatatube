// ios/PatataTube/Sources/GroupsView.swift
import SwiftUI
import PatataTubeKit

/// Root of the Videos tab: one poster card per group, sized like `ShowsView`'s
/// show cards (2:3, adaptive 160pt columns). Tapping pushes that group's grid.
///
/// Issues no requests: art comes from `GroupPosterStore` (written whenever a
/// group's list was fetched anyway) plus the preview disk cache, so a group
/// never opened on this device simply shows a placeholder tile. A card's menu
/// can override that with an emoji (`GroupCoverStore`), which wins over the
/// poster.
struct GroupsView: View {
    let posters: GroupPosterStore
    let covers: GroupCoverStore
    @EnvironmentObject var model: AppModel

    /// Mirrors `covers` so an edit redraws — the store itself is a plain
    /// UserDefaults wrapper and publishes nothing.
    @State private var cover: [String: String] = [:]
    /// Set while a cover write is in flight, so a failed POST can be reported
    /// without the card silently disagreeing with the other devices.
    @State private var saveError: String?
    /// The group whose "choose cover" sheet is open, if any.
    @State private var editing: EditingGroup?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(MediaTab.videoGroups, id: \.self) { group in
                card(for: group)
                    .id(group)
            }
        }
        .padding()
        .onAppear { cover = covers.covers() }
        .task {
            // Covers are server-owned; the mirror above is what's on screen
            // until this lands (and all there is, offline).
            if let remote = try? await model.api.groupCovers() {
                cover = covers.apply(remote)
            }
        }
        .sheet(item: $editing) { item in
            CoverPickerView(group: item.id, current: cover[item.id]) { text in
                save(text, for: item.id)
                editing = nil
            }
        }
        .alert("Couldn't save cover", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Optimistic, like `VideoStore`'s classify: the card changes at once and
    /// the write follows. A failed write reverts the card rather than leaving
    /// this device showing a cover the others will never see.
    private func save(_ text: String?, for group: String) {
        let previous = cover[group]
        let emoji = covers.setCover(text, for: group)
        cover[group] = emoji
        Task {
            do {
                _ = try await model.api.setGroupCover(emoji, for: group)
            } catch {
                cover[group] = covers.setCover(previous, for: group)
                saveError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func card(for group: String) -> some View {
        // The menu is a sibling of the link, not a child: a Button nested
        // inside a NavigationLink's label is swallowed by the link's tap.
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: Route.group(name: group)) {
                // A group's art is a 16:9 video preview, not a 2:3 Plex
                // poster, so scaledToFill's covering size is far wider
                // than this tile. Sizing the frame from the clear
                // rectangle keeps the overflow out of layout (an overlay
                // never sizes its parent) and clipping to the rounded
                // rect keeps it out of the neighbouring cell. Doing it
                // ShowsView's way — aspectRatio on the image itself —
                // is what let the art bleed across the grid.
                Rectangle().fill(.clear)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .overlay { artwork(for: group) }
                    .background(.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                menu(for: group)
            }
            Text(MediaTab.label(forGroup: group))
                .font(.subheadline).lineLimit(1)
        }
    }

    private func menu(for group: String) -> some View {
        Menu {
            Button("Choose cover") { editing = EditingGroup(id: group) }
            if cover[group] != nil {
                Button("Remove cover", role: .destructive) { save(nil, for: group) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(8)
    }

    @ViewBuilder
    private func artwork(for group: String) -> some View {
        if let emoji = cover[group] {
            // Scales with the tile: the emoji is the art, not a badge on it.
            GeometryReader { geo in
                Text(emoji)
                    .font(.system(size: geo.size.width * 0.55))
                    .minimumScaleFactor(0.2)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else if let poster = posters.poster(for: group),
                  let localFileURL = model.cache.cachedPreviewURL(for: poster.videoID, path: poster.path) {
            AuthedImage(
                path: poster.path,
                localFileURL: localFileURL
            )
        } else {
            // No spinner: nothing is loading, there is simply nothing recorded yet.
            Color.clear.overlay(
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
        }
    }
}

/// The "choose cover" sheet: one free-text field the user is expected to type a
/// single emoji into. Anything else is handled by `GroupCoverStore` (first
/// emoji wins, no emoji clears), so the field never rejects input outright.
private struct CoverPickerView: View {
    let group: String
    let current: String?
    let onSave: (String?) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Emoji", text: $text)
                        .font(.system(size: 48))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .onSubmit { onSave(text) }
                } footer: {
                    Text("One emoji, shown enlarged as this group's cover.")
                }
                if let preview = GroupCoverStore.firstEmoji(in: text) {
                    Section("Preview") {
                        Text(preview)
                            .font(.system(size: 96))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(MediaTab.label(forGroup: group))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text) }
                }
            }
        }
        .onAppear {
            text = current ?? ""
            focused = true
        }
    }
}

/// `sheet(item:)` needs an Identifiable, and conforming `String` itself would
/// leak that conformance app-wide.
private struct EditingGroup: Identifiable {
    let id: String
}
