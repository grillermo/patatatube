// ios/PatataTube/Sources/GroupsView.swift
import SwiftUI
import PatataTubeKit

/// Root of the Videos tab: one poster card per group, sized like `ShowsView`'s
/// show cards (2:3, adaptive 160pt columns). Tapping pushes that group's grid.
///
/// Cards issue no requests: art is the emoji the group mirror holds, and a
/// group without one shows a placeholder tile.
/// Video previews were tried here and removed — `group.emoji` is empty for the
/// first render, so every card flashed the last video's frame before its emoji
/// arrived.
struct GroupsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var groups: GroupStore

    @State private var saveError: String?
    @State private var editing: EditingGroup?
    @State private var renaming: EditingGroup?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(groups.groups) { group in
                card(for: group).id(group.id)
            }
        }
        .padding()
        .task {
            // Groups are server-owned; the mirror is what's on screen until
            // this lands (and all there is, offline).
            if let remote = try? await model.api.groups() {
                groups.apply(remote)
            }
        }
        .sheet(item: $editing) { item in
            CoverPickerView(group: item.group, current: item.group.emoji) { text in
                save(text, for: item.group)
                editing = nil
            }
        }
        .sheet(item: $renaming) { item in
            RenameGroupView(group: item.group) { label in
                rename(label, for: item.group)
                renaming = nil
            }
        }
        .alert("Couldn't save cover", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Optimistic, like `VideoStore`'s group write: the card changes at once
    /// and the write follows. A failed write reverts rather than leaving this
    /// device showing a cover the others will never see.
    private func save(_ text: String?, for group: VideoGroup) {
        let emoji = Self.firstEmoji(in: text ?? "")
        let previous = groups.groups
        groups.apply(groups.groups.map {
            $0.id == group.id
                ? VideoGroup(id: $0.id, name: $0.name, label: $0.label, emoji: emoji, position: $0.position)
                : $0
        })
        Task {
            do {
                _ = try await model.api.updateGroup(id: group.id, label: nil, emoji: emoji)
            } catch {
                groups.apply(previous)
                saveError = error.localizedDescription
            }
        }
    }

    /// Optimistic like `save`: label changes on screen first, write follows,
    /// a failed write reverts.
    private func rename(_ label: String, for group: VideoGroup) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.label else { return }
        let previous = groups.groups
        groups.apply(groups.groups.map {
            $0.id == group.id
                ? VideoGroup(id: $0.id, name: $0.name, label: trimmed, emoji: $0.emoji, position: $0.position)
                : $0
        })
        Task {
            do {
                // `emoji: nil` always serializes to a clearing `null` in the
                // request body (see APIClient.updateGroup) — pass the current
                // value back so renaming doesn't wipe the cover.
                _ = try await model.api.updateGroup(id: group.id, label: trimmed, emoji: group.emoji)
            } catch {
                groups.apply(previous)
                saveError = error.localizedDescription
            }
        }
    }

    /// One grapheme cluster, so flags, skin-tone modifiers and ZWJ families
    /// (👩‍👩‍👧) each count as a single emoji rather than their parts. Moved here
    /// from the deleted GroupCoverStore.
    static func firstEmoji(in text: String) -> String? {
        text.first(where: { char in
            char.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }
        }).map(String.init)
    }

    @ViewBuilder
    private func card(for group: VideoGroup) -> some View {
        // The menu is a sibling of the link, not a child: a Button nested
        // inside a NavigationLink's label is swallowed by the link's tap.
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: Route.group(id: group.id)) {
                Rectangle().fill(.clear)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .overlay { artwork(for: group.emoji) }
                    .background(.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                // The corner belongs to the menu alone. Color.clear with a
                // content shape is hit-testable, so it swallows the taps that
                // land near the button but miss its circle — without it those
                // fall through to the link underneath and open the group,
                // which is exactly the misfire this guards against.
                Color.clear
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) { menu(for: group) }
            }
            Text(group.label)
                .font(.subheadline).lineLimit(1)
        }
    }

    private func menu(for group: VideoGroup) -> some View {
        Menu {
            Button("Rename") { renaming = EditingGroup(group: group) }
            Button("Choose cover") { editing = EditingGroup(group: group) }
            if group.emoji != nil {
                Button("Remove cover", role: .destructive) { save(nil, for: group) }
            }
        } label: {
            // 44pt circle: Apple's minimum touch target, and the whole circle
            // is the hit shape — the old version was a headline glyph with 6pt
            // of padding, roughly half that.
            Image(systemName: "ellipsis")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(6)
    }

    @ViewBuilder
    private func artwork(for emoji: String?) -> some View {
        if let emoji {
            // Scales with the tile: the emoji is the art, not a badge on it.
            GeometryReader { geo in
                Text(emoji)
                    .font(.system(size: geo.size.width * 0.55))
                    .minimumScaleFactor(0.2)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            // No spinner: nothing is loading, there is simply no cover set.
            Color.clear.overlay(
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
        }
    }
}

/// The "choose cover" sheet: one free-text field the user is expected to type a
/// single emoji into. Anything else is handled by `GroupsView` (first emoji
/// wins, no emoji clears), so the field never rejects input outright.
private struct CoverPickerView: View {
    let group: VideoGroup
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
                if let preview = GroupsView.firstEmoji(in: text) {
                    Section("Preview") {
                        Text(preview)
                            .font(.system(size: 96))
                            .frame(maxWidth: .infinity)
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

/// Rename sheet, mirrors `CoverPickerView`'s shape.
private struct RenameGroupView: View {
    let group: VideoGroup
    let onSave: (String) -> Void

    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Emoji keyboard first: group names here are mostly emoji plus a
                // word, and the letters are one keyboard-switch away either way.
                EmojiTextField(placeholder: "Name", text: $text, onSubmit: save)
            }
            .navigationTitle("Rename Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { text = group.label }
    }

    private func save() {
        onSave(text)
    }
}

/// `sheet(item:)` needs an Identifiable, and conforming `String` itself would
/// leak that conformance app-wide.
private struct EditingGroup: Identifiable {
    let group: VideoGroup

    var id: Int { group.id }
}
