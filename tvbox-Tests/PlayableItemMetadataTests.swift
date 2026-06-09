import Foundation
import Testing
@testable import TVBox

@Suite("PlayableItem metadata identity")
struct PlayableItemMetadataIdentityTests {
    @Test("DRM changes playback identity")
    func drmChangesPlaybackIdentity() {
        let plain = PlayableItem(url: "https://example.com/movie.mpd")
        let protected = PlayableItem(
            url: "https://example.com/movie.mpd",
            drm: PlayableDRM(
                scheme: "widevine",
                licenseURL: "https://license.example.com/widevine",
                headers: ["Authorization": "Bearer token"],
                forceKey: true
            )
        )

        #expect(plain.id != protected.id)
    }

    @Test("subtitle and format changes playback identity")
    func subtitleAndFormatChangePlaybackIdentity() {
        let base = PlayableItem(url: "https://example.com/movie.m3u8")
        let withSubtitle = PlayableItem(
            url: "https://example.com/movie.m3u8",
            subtitles: [
                PlayableSubtitle(
                    url: "https://example.com/subtitle.vtt",
                    name: "English",
                    lang: "en",
                    format: "text/vtt",
                    flag: 1
                )!
            ]
        )
        let withFormat = PlayableItem(
            url: "https://example.com/movie.m3u8",
            format: "application/x-mpegURL"
        )

        #expect(base.id != withSubtitle.id)
        #expect(base.id != withFormat.id)
    }
}

@Suite("Bridge DRM decoding")
struct BridgeDRMDecodingTests {
    @Test("Decodes Android Drm field names")
    func decodesAndroidDrmFieldNames() throws {
        let data = Data("""
        {
          "key": "https://license.example.com/widevine",
          "type": "widevine",
          "forceKey": true,
          "header": {
            "Authorization": " Bearer abc ",
            "Host": "ignored.example.com"
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(BridgePlaybackDRM.self, from: data)
        let drm = try #require(decoded.playableDRM)

        #expect(drm.scheme == "widevine")
        #expect(drm.licenseURL == "https://license.example.com/widevine")
        #expect(drm.forceKey)
        #expect(drm.headers["Authorization"] == "Bearer abc")
        #expect(drm.headers["Host"] == nil)
    }

    @Test("Decodes Bridge alias field names")
    func decodesBridgeAliasFieldNames() throws {
        let data = Data("""
        {
          "licenseURL": "https://license.example.com/clearkey",
          "scheme": "clearkey",
          "headers": {
            "X-License": "ok"
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(BridgePlaybackDRM.self, from: data)
        let drm = try #require(decoded.playableDRM)

        #expect(drm.scheme == "clearkey")
        #expect(drm.licenseURL == "https://license.example.com/clearkey")
        #expect(drm.headers["X-License"] == "ok")
    }

    @Test("Bridge play response accepts Android Result field names")
    func bridgePlayResponseAcceptsAndroidResultFieldNames() throws {
        let data = Data("""
        {
          "ok": true,
          "url": "https://media.example.com/video.m3u8",
          "position": 90000,
          "artwork": "https://media.example.com/poster.jpg",
          "desc": "<p>播放结果简介</p>",
          "jx": 1,
          "header": {
            "User-Agent": "Android TVBox"
          },
          "subs": [
            {
              "url": "https://media.example.com/sub.srt",
              "name": "Chinese",
              "lang": "zh",
              "format": "application/x-subrip",
              "flag": 1
            }
          ],
          "danmaku": [
            {
              "name": "Danmaku",
              "url": "https://media.example.com/danmaku.xml"
            }
          ],
          "drm": {
            "key": "https://license.example.com/widevine",
            "type": "widevine"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(BridgePlayResponse.self, from: data)

        #expect(response.isPlayableMode)
        #expect(response.startPosition == 90)
        #expect(response.artwork == "https://media.example.com/poster.jpg")
        #expect(response.descriptionText == "<p>播放结果简介</p>")
        #expect(response.parse == 1)
        #expect(response.headers?["User-Agent"] == "Android TVBox")
        #expect(response.subtitles?.first?.url == "https://media.example.com/sub.srt")
        #expect(response.danmakus?.first?.url == "https://media.example.com/danmaku.xml")
        #expect(response.drm?.playableDRM?.scheme == "widevine")
    }

    @Test("Bridge play response rejects non-playable modes")
    func bridgePlayResponseRejectsNonPlayableModes() throws {
        let data = Data("""
        {
          "ok": true,
          "mode": "proxyRequired",
          "url": "https://media.example.com/video.m3u8"
        }
        """.utf8)

        let response = try JSONDecoder().decode(BridgePlayResponse.self, from: data)

        #expect(!response.isPlayableMode)
    }

    @Test("Bridge play response accepts Android numeric code and msg")
    func bridgePlayResponseAcceptsAndroidNumericCodeAndMsg() throws {
        let data = Data("""
        {
          "ok": false,
          "mode": "message",
          "code": 1001,
          "msg": "解析失败"
        }
        """.utf8)

        let response = try JSONDecoder().decode(BridgePlayResponse.self, from: data)

        #expect(response.code == "1001")
        #expect(response.message == "解析失败")
    }

    @Test("Bridge play response combines Android playUrl prefix")
    func bridgePlayResponseCombinesAndroidPlayUrlPrefix() throws {
        let data = Data("""
        {
          "ok": true,
          "playUrl": "https://parser.example.com/?url=",
          "url": "https://origin.example.com/video"
        }
        """.utf8)

        let response = try JSONDecoder().decode(BridgePlayResponse.self, from: data)

        #expect(response.url == "https://parser.example.com/?url=https://origin.example.com/video")
    }
}
