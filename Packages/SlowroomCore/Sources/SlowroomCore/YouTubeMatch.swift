import Foundation

public struct YouTubeMatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let duration: Double
    let verifiedChannel: Bool

    public var url: URL { SourceLink.youtube(id).url }
}

enum YouTubeMatching {
    static func ranked(_ videos: [YouTubeMatch], for track: SpotifyTrack) -> [YouTubeMatch] {
        let title = words(track.title)
        let artist = words(track.artist.components(separatedBy: ",").first ?? track.artist)
        let requested = words(track.title)
        let variants: Set<String> = ["live", "cover", "karaoke", "remix", "acoustic", "instrumental",
                                     "slowed", "sped", "nightcore", "8d", "432hz"]
        return videos.enumerated().compactMap { index, video -> (Int, Double, YouTubeMatch)? in
            let videoTitle = words(video.title)
            let channel = words(video.author)
            let titleMatch = coverage(title, in: videoTitle)
            let artistMatch = coverage(artist, in: videoTitle.union(channel))
            guard titleMatch >= 0.6, artist.isEmpty || artistMatch >= 0.5 else { return nil }
            var score = titleMatch * 65 + artistMatch * 25
            if let duration = track.duration, duration > 0 {
                guard video.duration < max(duration * 2, duration + 120) else { return nil }
                score += max(0, 25 - abs(video.duration - duration) * 1.5)
            }
            if videoTitle.isSuperset(of: ["official", "audio"]) { score += 12 }
            if !artist.isEmpty, coverage(artist, in: channel) >= 0.8 { score += 6 }
            if channel.contains("topic") { score += 8 }
            if video.verifiedChannel { score += 4 }
            score -= Double(videoTitle.intersection(variants).subtracting(requested).count) * 45
            return (index, score, video)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }.map(\.2)
    }

    private static func coverage(_ expected: Set<String>, in actual: Set<String>) -> Double {
        expected.isEmpty ? 0 : Double(expected.intersection(actual).count) / Double(expected.count)
    }

    private static func words(_ value: String) -> Set<String> {
        Set(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}
