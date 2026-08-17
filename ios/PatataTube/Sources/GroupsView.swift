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
    @State private var creating = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(groups.groups) { group in
                card(for: group).id(group.id)
            }
            createCard
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
        .sheet(isPresented: $creating) {
            CreateGroupView { label, emoji in
                create(label: label, emoji: emoji)
                creating = false
            }
        }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
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
                ? VideoGroup(id: $0.id, name: $0.name, label: $0.label, emoji: emoji,
                             position: $0.position, displayTitles: $0.displayTitles)
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
                ? VideoGroup(id: $0.id, name: $0.name, label: trimmed, emoji: $0.emoji,
                             position: $0.position, displayTitles: $0.displayTitles)
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

    /// A group is server-owned, so this one isn't optimistic: there is no id to
    /// mirror until the POST answers with the row. On success the whole list is
    /// re-fetched rather than appended locally, so `position` matches what the
    /// other devices will see.
    private func create(label: String, emoji: String?) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await model.api.createGroup(
                    name: Self.slug(for: trimmed), label: trimmed,
                    emoji: Self.firstEmoji(in: emoji ?? "")
                )
                if let remote = try? await model.api.groups() {
                    groups.apply(remote)
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// The `name` the server keys the group by, derived from what the user
    /// typed: lowercase, runs of anything non-alphanumeric collapsed to a
    /// single "-". A collision is the server's 400 to report, not something to
    /// paper over here with a suffix the user never asked for.
    static func slug(for label: String) -> String {
        let mapped = label.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
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

    /// Last tile in the grid, shaped like the group cards so the row stays
    /// even. A toolbar button was the alternative; this sits where the user is
    /// already looking when they notice the group they want is missing.
    private var createCard: some View {
        Button { creating = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(.clear)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                .secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                            )
                    }
                Text("New Group")
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
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

    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    // The current cover has to be in the field *before* it takes first
    // responder, or there is nothing for the select-all to highlight. An
    // `onAppear` assignment lands too late for that.
    init(group: VideoGroup, current: String?, onSave: @escaping (String?) -> Void) {
        self.group = group
        self.current = current
        self.onSave = onSave
        _text = State(initialValue: current ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The field only ever wants an emoji, so it opens on the
                    // emoji keyboard instead of making the user find the globe.
                    EmojiTextField(
                        placeholder: "Emoji",
                        text: $text,
                        font: .systemFont(ofSize: 48),
                        alignment: .center,
                        onSubmit: { onSave(text) }
                    )
                    .frame(height: 60)
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
    }
}

/// The "new group" sheet: a name plus an optional cover emoji, both of which
/// the server takes in one POST. The `name` it is keyed by is derived from the
/// label (`GroupsView.slug`) rather than asked for — two fields for one concept
/// is a form nobody fills in twice the same way.
private struct CreateGroupView: View {
    let onCreate: (String, String?) -> Void

    @State private var label = ""
    @State private var emoji = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $label)
                        .focused($focused)
                        .onSubmit(create)
                } footer: {
                    if !trimmed.isEmpty {
                        Text(verbatim: GroupsView.slug(for: trimmed))
                            .font(.footnote.monospaced())
                    }
                }
                Section {
                    EmojiTextField(
                        placeholder: "Emoji",
                        text: $emoji,
                        font: .systemFont(ofSize: 48),
                        alignment: .center,
                        onSubmit: create
                    )
                    .frame(height: 60)
                } footer: {
                    Text("Optional. One emoji, shown enlarged as this group's cover.")
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, emoji.isEmpty ? nil : emoji)
    }
}

/// Rename sheet, mirrors `CoverPickerView`'s shape.
private struct RenameGroupView: View {
    let group: VideoGroup
    let onSave: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $text)
                    .focused($focused)
                    .onSubmit(save)
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
        .onAppear {
            text = group.label
            focused = true
        }
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
