import Foundation
import Testing
@testable import SlowroomCore

struct YouTubeMatchingTests {
    @Test func readsSearchResultsWithoutAdsLiveStreamsOrDuplicates() throws {
        let first = video("abcdefghijk", title: "Song }; \"version\"", duration: "3:15")
        let items: [[String: Any]] = [first, first,
            video("lmnopqrstuv", title: "Long recording", duration: "1:02:03"),
            video("invalid", title: "Invalid ID", duration: "2:00"),
            video("12345678901", title: "Live now", duration: ""),
            video("12345678902", title: "Bad duration", duration: "3:99"),
            ["promotedSparklesWebRenderer": first]
        ]
        let matches = try SourceMetadata.youtubeSearch(html: html(items))
        #expect(matches.map(\.id) == ["abcdefghijk", "lmnopqrstuv"])
        #expect(matches.first?.title == "Song }; \"version\"")
        #expect(matches.first?.author == "Anika Vale")
        #expect(matches.first?.duration == 195)
        #expect(matches.last?.duration == 3_723)
    }

    @Test func distinguishesEmptyResultsFromUnreadableSearch() throws {
        #expect(try SourceMetadata.youtubeSearch(html: html([])).isEmpty)
        #expect(throws: (any Error).self) { try SourceMetadata.youtubeSearch(html: "<html>Try again</html>") }
        #expect(throws: (any Error).self) { try SourceMetadata.youtubeSearch(html: "var ytInitialData = {\"contents\":") }
    }

    @Test func ranksOfficialAudioAndMatchingDurationAheadOfCovers() {
        let track = spotify(title: "The River", duration: 180)
        let cover = match("cover000001", title: "Anika Vale - The River (Cover)", duration: 180)
        let official = match("audio000001", title: "Anika Vale - The River (Official Audio)", duration: 180)
        let topic = match("topic000001", title: "The River", author: "Anika Vale - Topic", duration: 181)
        let differentArtist = match("other000001", title: "The River", author: "Another Band", duration: 180)
        let compilation = match("album000001", title: "Anika Vale - The River (Full Album)", duration: 1_200)
        let ranked = YouTubeMatching.ranked([cover, differentArtist, compilation, official, topic], for: track)
        #expect(ranked.map(\.id) == [topic.id, official.id, cover.id])
    }

    @Test func retainsRequestedVersionsAndHandlesAccentedNames() {
        let track = spotify(title: "Déjà Vu (Slowed)", artist: "Beyoncé", duration: 220)
        let original = match("normal00001", title: "Beyonce - Deja Vu (Official Audio)", duration: 180)
        let slowed = match("slowed00001", title: "Beyonce - Deja Vu (Slowed)", duration: 220)
        #expect(YouTubeMatching.ranked([original, slowed], for: track).first?.id == slowed.id)
    }

    @Test func supportsMetadataWithoutArtistOrDuration() {
        let track = spotify(title: "The River", artist: "", duration: nil)
        let result = match("audio000001", title: "Anika Vale - The River", duration: 180)
        #expect(YouTubeMatching.ranked([result], for: track) == [result])
        #expect(track.youtubeQuery == "The River audio")
    }

    private func spotify(title: String, artist: String = "Anika Vale", duration: Double?) -> SpotifyTrack {
        SpotifyTrack(title: title, artist: artist, duration: duration,
                     url: URL(string: "https://open.spotify.com/track/20I6sIOMTCkB6w7ryavxtO")!)
    }

    private func match(_ id: String, title: String, author: String = "Audio channel", duration: Double) -> YouTubeMatch {
        YouTubeMatch(id: id, title: title, author: author, duration: duration, verifiedChannel: false)
    }

    private func video(_ id: String, title: String, duration: String) -> [String: Any] {
        ["videoRenderer": ["videoId": id, "title": ["runs": [["text": title]]],
                           "longBylineText": ["runs": [["text": "Anika Vale"]]],
                           "lengthText": ["simpleText": duration]]]
    }

    private func html(_ items: [[String: Any]]) throws -> String {
        let root: [String: Any] = ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": [
            "sectionListRenderer": ["contents": [["itemSectionRenderer": ["contents": items]]]]
        ]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        return "<script>var ytInitialData = " + String(decoding: data, as: UTF8.self) + ";</script>"
    }
}
