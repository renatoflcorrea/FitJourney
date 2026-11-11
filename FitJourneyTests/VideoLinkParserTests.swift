import Foundation
import Testing
@testable import FitJourney

struct VideoLinkParserTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=42",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://youtu.be/dQw4w9WgXcQ?t=30",
        "https://www.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
        "youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "  https://www.youtube.com/live/dQw4w9WgXcQ  ",
    ])
    func recognizesYouTube(link: String) throws {
        let video = try #require(VideoLinkParser.parse(link))
        #expect(video.provider == .youtube)
        #expect(video.videoID == "dQw4w9WgXcQ")
        #expect(video.embedURL?.absoluteString.contains("/embed/dQw4w9WgXcQ") == true)
        #expect(video.thumbnailURL != nil)
    }

    @Test(arguments: [
        ("https://vimeo.com/76979871", "76979871"),
        ("https://www.vimeo.com/76979871", "76979871"),
        ("https://vimeo.com/channels/staffpicks/76979871", "76979871"),
        ("https://player.vimeo.com/video/76979871?h=abc", "76979871"),
        ("vimeo.com/76979871", "76979871"),
        ("https://vimeo.com/76979871/a1b2c3d4e5", "76979871"),
        ("https://vimeo.com/showcase/11111/video/76979871", "76979871"),
        ("https://vimeo.com/album/22222/video/76979871", "76979871"),
        ("https://vimeo.com/groups/motion/videos/76979871", "76979871"),
        ("https://vimeo.com/channels/123/76979871", "76979871"),
    ])
    func recognizesVimeo(link: String, id: String) throws {
        let video = try #require(VideoLinkParser.parse(link))
        #expect(video.provider == .vimeo)
        #expect(video.videoID == id)
        #expect(video.embedURL?.absoluteString == "https://player.vimeo.com/video/\(id)?playsinline=1")
        #expect(video.watchURL.absoluteString == "https://vimeo.com/\(id)")
    }

    /// Coleções (showcase/álbum/grupo/perfil) sem segmento de vídeo não têm ID de vídeo.
    @Test(arguments: [
        "https://vimeo.com/showcase/11111",
        "https://vimeo.com/album/22222",
        "https://vimeo.com/groups/motion",
        "https://vimeo.com/groups/motion/videos",
        "https://vimeo.com/user12345",
        "https://vimeo.com/channels/staffpicks",
    ])
    func vimeoCollectionsAreNotVideos(link: String) throws {
        let video = try #require(VideoLinkParser.parse(link))
        #expect(video.provider == .other)
        #expect(video.videoID == nil)
    }

    @Test func otherURLsBecomeOther() throws {
        let video = try #require(VideoLinkParser.parse("https://example.com/video.mp4"))
        #expect(video.provider == .other)
        #expect(video.videoID == nil)
        #expect(video.embedURL == nil)
    }

    @Test(arguments: ["", "not a link", "https://www.youtube.com/watch?v=short", "ftp://youtube.com/watch?v=dQw4w9WgXcQ"])
    func rejectsInvalidOrMalformedYouTube(link: String) {
        let video = VideoLinkParser.parse(link)
        #expect(video == nil || video?.provider == .other)
    }

    @Test func mediaRefRoundTripsThroughJSON() throws {
        let refs: [MediaRef] = [
            .image(fileName: "a.jpg"),
            .localVideo(fileName: "b.mov", thumbnailFileName: "b.jpg"),
            try #require(MediaRef.externalVideo(link: "https://youtu.be/dQw4w9WgXcQ")),
        ]
        let data = try JSONEncoder().encode(refs)
        #expect(try JSONDecoder().decode([MediaRef].self, from: data) == refs)
    }
}
