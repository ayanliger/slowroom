import Foundation
import SlowroomCore

enum NativeSpotify {
    static func connect(accessToken: String) async throws {
        let id = accessToken.withCString { sr_spotify_connect($0) }
        defer { sr_spotify_release(id) }
        try await wait(id) { _ in }
    }

    static func load(track: SpotifyTrack, accessToken: String, directory: URL, stage: @escaping @Sendable (String) -> Void) async throws -> AudioTrack {
        guard case .spotify(let trackID) = try SourceLink(track.url.absoluteString) else { throw SourceError.invalidLink }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let id = accessToken.withCString { token in
            trackID.withCString { track in
                output.path.withCString { sr_spotify_prepare(token, track, $0) }
            }
        }
        defer { sr_spotify_release(id) }
        do {
            stage("Loading audio from Spotify")
            try await wait(id) { samples in
                if let duration = track.duration, duration > 0, samples > 0 {
                    let percent = min(99, Int(Double(samples) / (44_100 * 2 * duration) * 100))
                    stage("Loading Spotify audio: \(percent)%")
                }
            }
            stage("Reading waveform")
            let reader = Task.detached(priority: .userInitiated) {
                try AudioTrack.inspect(url: output, title: track.title, author: track.artist, sourceURL: track.url)
            }
            return try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private struct Status: Decodable { let status: String; let error: String?; let samples: UInt64 }

    private static func wait(_ id: UInt64, progress: @escaping @Sendable (UInt64) -> Void) async throws {
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                guard let pointer = sr_spotify_status(id) else { throw SpotifyError.message("The audio client did not respond.") }
                let data = Data(String(cString: pointer).utf8)
                sr_spotify_string_free(pointer)
                let result = try JSONDecoder().decode(Status.self, from: data)
                switch result.status {
                case "ready": return
                case "cancelled": throw CancellationError()
                case "failed": throw SpotifyError.message(result.error ?? "Spotify audio is unavailable.")
                default: progress(result.samples)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } onCancel: { sr_spotify_cancel(id) }
    }
}
