import Foundation

/// Minimal parser for the playlists our own server generates (`hls.py`):
/// single variant, relative URIs, fMP4 init via EXT-X-MAP, subtitle groups
/// via EXT-X-MEDIA. Not a general M3U8 parser.
enum HLSManifestParser {
    static func mediaAssets(inMediaPlaylist text: String) -> [String] {
        var assets: [String] = []
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attributeValue("URI", in: line), !assets.contains(uri) {
                    assets.insert(uri, at: 0)
                }
            } else if !line.hasPrefix("#"), !assets.contains(line) {
                assets.append(line)
            }
        }
        return assets
    }

    static func referencedPlaylists(inMasterPlaylist text: String) -> [String] {
        var playlists: [String] = []
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                if let uri = attributeValue("URI", in: line), !playlists.contains(uri) {
                    playlists.append(uri)
                }
            } else if !line.hasPrefix("#"), !playlists.contains(line) {
                playlists.append(line)
            }
        }
        return playlists
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func attributeValue(_ name: String, in line: String) -> String? {
        guard let nameRange = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[nameRange.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }
}
