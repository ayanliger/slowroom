import AVFoundation
import Foundation
import SlowroomCore

@main
struct SourceProbe {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let text = arguments.first else {
            print("Usage: swift run SourceProbe <YouTube or Spotify URL> [output directory] [--load-match]")
            return
        }
        let link = try SourceLink(text)
        let folder = arguments.dropFirst().first(where: { !$0.hasPrefix("--") }).map { URL(fileURLWithPath: $0) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("slowroom-source-probe")
        switch link {
        case .spotify, .spotifyShort:
            let track = try await SourceService.spotifyTrack(from: link)
            print("Spotify: \(track.title) / \(track.artist)")
            let matches = try await SourceService.youtubeMatches(for: track)
            for match in matches { print("YouTube: \(match.title) / \(match.author) / \(match.duration)s / \(match.url)") }
            if arguments.contains("--load-match"), let match = matches.first {
                let audio = try await SourceService.loadYouTube(videoID: match.id, directory: folder) { print($0) }
                try describe(audio)
            }
        case .youtube(let id):
            let track = try await SourceService.loadYouTube(videoID: id, directory: folder) { print($0) }
            try describe(track)
        }
    }

    private static func describe(_ track: AudioTrack) throws {
        let file = try AVAudioFile(forReading: track.fileURL)
        print("Loaded: \(track.title)")
        print("Duration: \(track.duration); channels: \(file.processingFormat.channelCount)")
        print("File: \(track.fileURL.path)")
        print("Waveform bins: \(track.waveform.count)")
    }
}
