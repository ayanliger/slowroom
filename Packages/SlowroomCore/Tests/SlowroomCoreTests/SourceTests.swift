import Foundation
import Testing
@testable import SlowroomCore

struct SourceTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=aqz-KE-bpKQ&t=30",
        "https://youtu.be/aqz-KE-bpKQ?si=example",
        "https://music.youtube.com/watch?v=aqz-KE-bpKQ",
        "https://m.youtube.com/shorts/aqz-KE-bpKQ"
    ])
    func acceptsYouTubeVariants(_ text: String) throws {
        #expect(try SourceLink(text) == .youtube("aqz-KE-bpKQ"))
    }

    @Test(arguments: [
        "https://open.spotify.com/track/20I6sIOMTCkB6w7ryavxtO?si=example",
        "https://open.spotify.com/intl-pt/track/20I6sIOMTCkB6w7ryavxtO",
        "spotify:track:20I6sIOMTCkB6w7ryavxtO"
    ])
    func acceptsSpotifyVariants(_ text: String) throws {
        #expect(try SourceLink(text) == .spotify("20I6sIOMTCkB6w7ryavxtO"))
    }

    @Test(arguments: [
        "https://youtube.com.evil.example/watch?v=aqz-KE-bpKQ",
        "https://youtube.com@evil.example/watch?v=aqz-KE-bpKQ",
        "file:///private/etc/passwd", "javascript:alert(1)",
        "https://www.youtube.com/watch?v=invalid",
        "https://open.spotify.com/playlist/20I6sIOMTCkB6w7ryavxtO"
    ])
    func rejectsOtherInputs(_ text: String) {
        #expect(throws: (any Error).self) { try SourceLink(text) }
    }

    @Test func readsArtistAndDurationFromSpotifyEmbed() throws {
        let html = """
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"state":{"data":{"entity":{
          "name":"Test track", "artists":[{"name":"Test artist"}], "duration":193400
        }}}}}}
        </script>
        """
        let track = try SourceMetadata.spotify(html: html, url: URL(string: "https://open.spotify.com")!)
        #expect(track.title == "Test track")
        #expect(track.artist == "Test artist")
        #expect(track.duration == 193.4)
    }

    @Test func malformedSpotifyPageReturnsAnError() {
        #expect(throws: (any Error).self) {
            try SourceMetadata.spotify(html: "<html>No track</html>", url: URL(string: "https://open.spotify.com")!)
        }
    }
}
