import Foundation

enum IdentityProbeError: Error, Equatable {
    /// Not a `bytes=0-0` 206 with a strong ETag: the server ignores ranges.
    case invalid
}

/// Learns a remote file's identity with one `bytes=0-0` request.
enum IdentityProbe {
    static func fetch(_ request: URLRequest, session: URLSession) async throws -> MediaIdentity {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IdentityProbeError.invalid }
        if (400..<600).contains(http.statusCode) { throw APIError.badStatus(http.statusCode) }
        return try identity(from: http, bodyCount: body.count)
    }

    static func identity(from response: HTTPURLResponse, bodyCount: Int) throws -> MediaIdentity {
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              bodyCount == 1,
              let etag = response.value(forHTTPHeaderField: "ETag"),
              isValidStrongETag(etag),
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes 0-0/"),
              let total = Int64(contentRange.dropFirst("bytes 0-0/".count)),
              total > 0
        else { throw IdentityProbeError.invalid }
        return MediaIdentity(etag: etag, totalByteCount: total)
    }
}

private func isValidStrongETag(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else { return false }
    return bytes.dropFirst().dropLast().allSatisfy {
        $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80
    }
}
