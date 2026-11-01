import Foundation

enum SourceMetadata {
    static func spotify(html: String, url: URL) throws -> SpotifyTrack {
        let pattern = "<script[^>]*id=[\"']__NEXT_DATA__[\"'][^>]*>"
        guard let tag = html.range(of: pattern, options: .regularExpression),
              let end = html.range(of: "</script>", range: tag.upperBound..<html.endIndex),
              let data = String(html[tag.upperBound..<end.lowerBound]).data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let page = props["pageProps"] as? [String: Any],
              let state = page["state"] as? [String: Any],
              let content = state["data"] as? [String: Any],
              let entity = content["entity"] as? [String: Any],
              let title = (entity["name"] ?? entity["title"]) as? String,
              !title.isEmpty else { throw SourceError.metadataUnavailable }
        let artists = entity["artists"] as? [[String: Any]] ?? []
        return SpotifyTrack(
            title: title,
            artist: artists.compactMap { $0["name"] as? String }.joined(separator: ", "),
            duration: (entity["duration"] as? Double).map { $0 / 1_000 },
            url: url
        )
    }

}
