// ios/PatataTube/Sources/GroupsView.swift
import SwiftUI
import PatataTubeKit

/// Root of the Videos tab: one poster card per group, laid out exactly like
/// `ShowsView`'s show cards. Tapping pushes that group's grid.
///
/// Issues no requests: art comes from `GroupPosterStore` (written whenever a
/// group's list was fetched anyway) plus the preview disk cache, so a group
/// never opened on this device simply shows a placeholder tile.
struct GroupsView: View {
    let posters: GroupPosterStore
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(MediaTab.videoGroups, id: \.self) { group in
                NavigationLink(value: Route.group(name: group)) {
                    VStack(alignment: .leading, spacing: 6) {
                        artwork(for: group)
                            .aspectRatio(2.0/3.0, contentMode: .fit)
                            .background(.secondary.opacity(0.2))
                            .cornerRadius(8)
                            .clipped()
                        Text(MediaTab.label(forGroup: group))
                            .font(.subheadline).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .id(group)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func artwork(for group: String) -> some View {
        if let poster = posters.poster(for: group),
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
