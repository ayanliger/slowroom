import AVFoundation
import Foundation
import SlowroomCore

@main
struct SourceProbe {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let text = arguments.first else {
            print("Usage: swift run SourceProbe <YouTube or Spotify URL> [output directory]")
            return
        }
        let link = try SourceLink(text)
        let folder = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) :
            FileManager.default.temporaryDirectory.appendingPathComponent("slowroom-source-probe")
        switch link {
        case .spotify, .spotifyShort:
            let track = try await SourceService.spotifyTrack(from: link)
            print("Spotify: \(track.title) / \(track.artist)")
            print("Metadata verified. Sign in and load Spotify audio in the iPhone app.")
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
