import Foundation

public enum SourceLink: Equatable, Sendable {
    case youtube(String)
    case spotify(String)
    case spotifyShort(URL)

    public init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("spotify:track:") {
            let id = String(text.dropFirst("spotify:track:".count))
            guard Self.valid(id, length: 22, extra: "") else { throw SourceError.invalidLink }
            self = .spotify(id)
            return
        }
        guard let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { throw SourceError.invalidLink }
        let parts = url.pathComponents.filter { $0 != "/" }
        if ["spotify.link", "spotify.app.link"].contains(host) {
            guard url.scheme == "https" else { throw SourceError.invalidLink }
            self = .spotifyShort(url)
            return
        }
        if host == "open.spotify.com" {
            let normalized = parts.first?.hasPrefix("intl-") == true ? Array(parts.dropFirst()) : parts
            guard normalized.count == 2, normalized[0] == "track",
                  Self.valid(normalized[1], length: 22, extra: "") else {
                throw SourceError.spotifyTrackOnly
            }
            self = .spotify(normalized[1])
            return
        }
        let videoID: String?
        if host == "youtu.be" {
            videoID = parts.count == 1 ? parts.first : nil
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if parts == ["watch"] {
                videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if parts.count == 2, ["shorts", "embed", "live"].contains(parts[0]) {
                videoID = parts[1]
            } else {
                videoID = nil
            }
        } else {
            videoID = nil
        }
        guard let videoID, Self.valid(videoID, length: 11, extra: "_-") else {
            throw SourceError.invalidLink
        }
        self = .youtube(videoID)
    }

    public var url: URL {
        switch self {
        case .youtube(let id): URL(string: "https://www.youtube.com/watch?v=\(id)")!
        case .spotify(let id): URL(string: "https://open.spotify.com/track/\(id)")!
        case .spotifyShort(let url): url
        }
    }

    private static func valid(_ value: String, length: Int, extra: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" + extra)
        return value.count == length && value.allSatisfy(allowed.contains)
    }
}

public struct SpotifyTrack: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let duration: Double?
    public let url: URL

    public var youtubeQuery: String { [artist, title, "audio"].filter { !$0.isEmpty }.joined(separator: " ") }
}

public enum SourceError: LocalizedError {
    case invalidLink
    case spotifyTrackOnly
    case metadataUnavailable
    case unavailable
    case downloadFailed
    case downloadTooLarge
    case requestFailed(Int)
    case searchUnavailable
    case noMatches

    public var errorDescription: String? {
        switch self {
        case .invalidLink: "Paste a YouTube video or Spotify track link."
        case .spotifyTrackOnly: "Use a Spotify song link. Albums and playlists are not supported yet."
        case .metadataUnavailable: "The track details could not be read. Try the link again in a moment."
        case .unavailable: "This video has no accessible audio stream. Try another upload."
        case .downloadFailed: "The audio could not be loaded. Try this link again."
        case .downloadTooLarge: "This audio exceeds the 500 MB limit. Choose a shorter upload."
        case .requestFailed(let code): "The source returned HTTP \(code). Try again in a moment."
        case .searchUnavailable: "YouTube search could not be read. Try again or paste a YouTube link."
        case .noMatches: "No matching YouTube videos were found. Try a different search or paste a YouTube link."
        }
    }
}
