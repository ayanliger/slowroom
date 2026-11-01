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
        let stem = clean(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "_", with: " ")
        let parts = stem.components(separatedBy: " - ")
        if parts.count >= 2 {
            return (clean(parts.dropFirst().joined(separator: " - ")), clean(parts[0]))
        }
        return (stem.isEmpty ? "Untitled" : stem, "")
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
