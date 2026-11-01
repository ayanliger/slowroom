import Foundation

public enum LibraryKind: String, Codable, CaseIterable, Sendable {
    case mix = "Slowed + Reverb"
    case source = "Sources"
}

public struct LibraryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var artist: String
    public var relativePath: String
    public let kind: LibraryKind
    public let addedAt: Date
    public let duration: Double
    public let waveform: [Float]
    public let originalBytes: Int64
    public let storedBytes: Int64
    public let originalName: String
    public let fingerprint: String
    public let storedFingerprint: String?
    public let sourceURL: URL?
    public let effects: EffectSettings?

    public func audioTrack(in directory: URL) -> AudioTrack {
        AudioTrack(fileURL: directory.appendingPathComponent(relativePath), title: title, author: artist,
                   sourceURL: sourceURL, duration: duration, waveform: waveform)
    }
}

public struct LibraryImportReport: Sendable {
    public var added: [LibraryItem] = []
    public var duplicates = 0
    public var failures: [String] = []
    public var cancelled = false
    public var originalBytes: Int64 { added.reduce(0) { $0 + $1.originalBytes } }
    public var storedBytes: Int64 { added.reduce(0) { $0 + $1.storedBytes } }
    public init() {}
}

public enum LibraryNaming {
    public static func clean(_ text: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\u{0}").union(.controlCharacters)
        let result = text.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String(result.prefix(100))
    }

    public static func infer(from filename: String) -> (title: String, artist: String) {
        var stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let mix = stem.localizedCaseInsensitiveContains("slowedandreverbstudio")
        stem = replace(#"(?i)-?slowedandreverbstudio"#, in: stem, with: "")
        var copySuffix = ""
        if let range = stem.range(of: #"\s*\([0-9]+\)\s*$"#, options: .regularExpression) {
            copySuffix = " " + stem[range].trimmingCharacters(in: .whitespaces)
            stem.removeSubrange(range)
        }
        let downloader = stem.range(of: #"(?i)^(spotidown\.app|spotidownloader\.com|spotifydown\.com)\s*-\s*"#,
                                    options: .regularExpression) != nil
        stem = replace(#"(?i)^(spotidown\.app|spotidownloader\.com|spotifydown\.com)\s*-\s*"#, in: stem, with: "")
        stem = replace(#"(?i)\s+-\s+[^\r\n]+?\s+\(youtube\)\s*$"#, in: stem, with: "", backwards: true)
        let videoID = stem.range(of: #"\[[A-Za-z0-9_-]{11}\]"#, options: .regularExpression) != nil
        stem = replace(#"\s*\[[A-Za-z0-9_-]{11}\]"#, in: stem, with: "")
        stem = replace(#"(?i)\s*[\[(](official\s+)?(music\s+)?(video|audio)[\])]"#, in: stem, with: "")
        if videoID { stem = replace(#"(?i)\s*-\s*SOUNDTRACK\s*$"#, in: stem, with: "") }
        stem = replace(#"(?i)\s+Music-\s*"#, in: stem, with: " - ")
        stem = replace(#"(?<=\p{L})_s\b"#, in: stem, with: "'s").replacingOccurrences(of: "_", with: " ")
        let parts = stem.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        let artist: String
        var title: String
        if parts.count >= 2 {
            artist = downloader ? parts.last! : parts[0]
            title = (downloader ? Array(parts.dropLast()) : Array(parts.dropFirst())).joined(separator: " - ")
        } else { title = stem; artist = "" }
        title = clean(title)
        if title.isEmpty { title = "Untitled" }
        if mix && !title.localizedCaseInsensitiveContains("slowed") { title += " (Slowed + Reverb)" }
        return (clean(title + copySuffix), clean(artist))
    }

    public static func containsExportArtifacts(title: String, artist: String) -> Bool {
        let text = (title + " " + artist).lowercased()
        return ["slowedandreverbstudio", "spotidown.app", "spotidownloader.com", "spotifydown.com"].contains { text.contains($0) }
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String, backwards: Bool = false) -> String {
        if backwards {
            // Remove only the final uploader field, retaining hyphens inside the song title.
            guard let suffix = text.range(of: " - ", options: .backwards),
                  text[suffix.lowerBound...].range(of: pattern, options: .regularExpression) != nil else { return text }
            return String(text[..<suffix.lowerBound])
        }
        return text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    public static func basename(title: String, artist: String, kind: LibraryKind) -> String {
        let title = clean(title).isEmpty ? "Untitled" : clean(title)
        let artist = clean(artist)
        let suffix = kind == .mix && !title.localizedCaseInsensitiveContains("slowed")
            && !title.localizedCaseInsensitiveContains("reverb") ? " (Slowed + Reverb)" : ""
        var base = artist.isEmpty ? title : artist + " - " + title
        while base.utf8.count > 180 { base.removeLast() }
        return base + suffix
    }
}
