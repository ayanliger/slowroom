import Foundation
@preconcurrency import YouTubeKit

public enum SourceService {
    public static func youtubeMatches(for track: SpotifyTrack, query: String? = nil) async throws -> [YouTubeMatch] {
        let query = (query ?? track.youtubeQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 512 else { throw SourceError.noMatches }
        var url = URLComponents(string: "https://www.youtube.com/results")!
        url.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "hl", value: "en")]
        let html = try await text(at: url.url!)
        try Task.checkCancellation()
        let videos = try SourceMetadata.youtubeSearch(html: html)
        let matches = YouTubeMatching.ranked(videos, for: track)
        guard !matches.isEmpty else { throw SourceError.noMatches }
        return Array(matches.prefix(5))
    }

    public static func spotifyTrack(from link: SourceLink) async throws -> SpotifyTrack {
        let resolved: SourceLink
        if case .spotifyShort(let url) = link {
            let (_, response) = try await URLSession.shared.data(for: request(url))
            guard let finalURL = response.url else { throw SourceError.metadataUnavailable }
            resolved = try SourceLink(finalURL.absoluteString)
        } else {
            resolved = link
        }
        guard case .spotify(let id) = resolved else { throw SourceError.spotifyTrackOnly }
        let url = URL(string: "https://open.spotify.com/embed/track/\(id)")!
        do {
            let html = try await text(at: url)
            return try SourceMetadata.spotify(html: html, url: resolved.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://open.spotify.com/oembed")!
            components.queryItems = [URLQueryItem(name: "url", value: resolved.url.absoluteString)]
            let data = try await data(at: components.url!)
            let metadata = try JSONDecoder().decode(Embed.self, from: data)
            guard !metadata.title.isEmpty else { throw SourceError.metadataUnavailable }
            return SpotifyTrack(title: metadata.title, artist: "", duration: nil, url: resolved.url)
        }
    }

    public static func loadYouTube(
        videoID: String,
        directory: URL,
        stage: @Sendable (String) -> Void = { _ in }
    ) async throws -> AudioTrack {
        _ = try SourceLink("https://youtu.be/\(videoID)")
        stage("Finding audio")
        async let metadata = youtubeEmbed(videoID)
        let video = YouTube(videoID: videoID, methods: [.local])
        let streams = try await video.streams
        try Task.checkCancellation()
        let audio = streams.filterAudioOnly().filter { $0.fileExtension == .m4a && $0.isNativelyPlayable }
        // Format 140 is stereo AAC. Some higher-bitrate alternatives contain surround audio.
        guard let stream = audio.first(where: {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "itag" })?.value == "140"
        }) ?? audio.filter({ ($0.bitrate ?? 0) < 200_000 }).highestAudioBitrateStream() else {
            throw SourceError.unavailable
        }
        guard stream.url.scheme == "https",
              let host = stream.url.host,
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else {
            throw SourceError.unavailable
        }
        stage("Waiting for the source")
        try await stream.waitUntilAvailable()
        try Task.checkCancellation()
        var head = request(stream.url)
        head.httpMethod = "HEAD"
        let (_, headResponse) = try await URLSession.shared.data(for: head)
        try validate(headResponse)
        let length = headResponse.expectedContentLength
        guard length > 0 else { throw SourceError.downloadFailed }
        guard length <= 500_000_000 else { throw SourceError.downloadTooLarge }
        let temporary = try await download(stream.url, length: length, stage: stage)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 500_000_000 else { throw SourceError.downloadTooLarge }
        guard size > 0 else { throw SourceError.downloadFailed }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try FileManager.default.moveItem(at: temporary, to: destination)
        do {
            let info = await metadata
            stage("Reading waveform")
            return try AudioTrack.inspect(
                url: destination,
                title: info?.title ?? "YouTube audio",
                author: info?.author_name ?? "",
                sourceURL: SourceLink.youtube(videoID).url
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private struct Embed: Decodable, Sendable {
        let title: String
        let author_name: String?
    }

    private static func download(_ url: URL, length: Int64, stage: @Sendable (String) -> Void) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            var offset: Int64 = 0
            while offset < length {
                try Task.checkCancellation()
                stage("Loading audio: \(offset * 100 / length)%")
                let end = min(offset + 524_288, length) - 1
                var part = request(url)
                part.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                let (temporary, response) = try await URLSession.shared.download(for: part)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try validate(response)
                let data = try Data(contentsOf: temporary)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 200, offset == 0, Int64(data.count) == length {
                    try output.write(contentsOf: data)
                    offset = length
                } else {
                    guard http?.statusCode == 206,
                          http?.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(length)",
                          Int64(data.count) == end - offset + 1 else { throw SourceError.downloadFailed }
                    try output.write(contentsOf: data)
                    offset = end + 1
                }
            }
            try output.close()
            return destination
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func youtubeEmbed(_ id: String) async -> Embed? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: SourceLink.youtube(id).url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        do { return try JSONDecoder().decode(Embed.self, from: await data(at: components.url!)) }
        catch { return nil }
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private static func text(at url: URL) async throws -> String {
        guard let text = String(data: try await data(at: url), encoding: .utf8) else {
            throw SourceError.metadataUnavailable
        }
        return text
    }

    private static func data(at url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        try validate(response)
        return data
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SourceError.downloadFailed }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.requestFailed(http.statusCode) }
    }
}
