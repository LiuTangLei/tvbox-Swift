import Foundation

/// A normalized playback description, mirroring Android TVBox's PlaySpec shape.
struct PlayableItem: Identifiable, Hashable {
    enum Origin: String, Hashable {
        case direct
        case bridge
        case bridgeFallback
    }

    let id: String
    let url: String
    let headers: [String: String]
    let format: String?
    let parse: Int?
    let sourceKey: String?
    let flag: String?
    let episodeId: String?
    let fallbackURL: String?
    let proxied: Bool
    let jxFrom: String?
    let expiresAt: TimeInterval?
    let subtitles: [PlayableSubtitle]
    let danmakus: [PlayableDanmaku]
    let drm: PlayableDRM?
    let origin: Origin

    init(
        url: String,
        headers: [String: String] = [:],
        format: String? = nil,
        parse: Int? = nil,
        sourceKey: String? = nil,
        flag: String? = nil,
        episodeId: String? = nil,
        fallbackURL: String? = nil,
        proxied: Bool = false,
        jxFrom: String? = nil,
        expiresAt: TimeInterval? = nil,
        subtitles: [PlayableSubtitle] = [],
        danmakus: [PlayableDanmaku] = [],
        drm: PlayableDRM? = nil,
        origin: Origin = .direct
    ) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = PlaybackHTTPHeaders.normalized(headers)
        self.format = format?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.parse = parse
        self.sourceKey = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.flag = flag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.episodeId = episodeId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.fallbackURL = fallbackURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.proxied = proxied
        self.jxFrom = jxFrom?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.expiresAt = expiresAt
        self.subtitles = subtitles
        self.danmakus = danmakus
        self.drm = drm
        self.origin = origin
        self.id = Self.makeIdentifier(
            url: self.url,
            headers: self.headers,
            sourceKey: self.sourceKey,
            flag: self.flag,
            episodeId: self.episodeId,
            origin: origin
        )
    }

    func replacingStream(
        url: String,
        headers: [String: String],
        origin: Origin? = nil
    ) -> PlayableItem {
        PlayableItem(
            url: url,
            headers: headers,
            format: format,
            parse: parse,
            sourceKey: sourceKey,
            flag: flag,
            episodeId: episodeId,
            fallbackURL: fallbackURL,
            proxied: proxied,
            jxFrom: jxFrom,
            expiresAt: expiresAt,
            subtitles: subtitles,
            danmakus: danmakus,
            drm: drm,
            origin: origin ?? self.origin
        )
    }

    private static func makeIdentifier(
        url: String,
        headers: [String: String],
        sourceKey: String?,
        flag: String?,
        episodeId: String?,
        origin: Origin
    ) -> String {
        [
            sourceKey ?? "",
            flag ?? "",
            episodeId ?? "",
            origin.rawValue,
            url,
            PlaybackHTTPHeaders.cacheKey(headers)
        ].joined(separator: "|")
    }
}

struct PlayableSubtitle: Hashable {
    let url: String
    let name: String?
    let lang: String?
    let format: String?
    let flag: Int?

    init?(url: String?, name: String? = nil, lang: String? = nil, format: String? = nil, flag: Int? = nil) {
        let trimmedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedURL.isEmpty else { return nil }
        self.url = trimmedURL
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.lang = lang?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.format = format?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.flag = flag
    }
}

struct PlayableDanmaku: Hashable {
    let name: String?
    let url: String

    init?(name: String? = nil, url: String?) {
        let trimmedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedURL.isEmpty else { return nil }
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.url = trimmedURL
    }
}

struct PlayableDRM: Codable, Hashable {
    let scheme: String?
    let licenseURL: String?
    let headers: [String: String]
    let forceKey: Bool

    init(
        scheme: String? = nil,
        licenseURL: String? = nil,
        headers: [String: String] = [:],
        forceKey: Bool = false
    ) {
        self.scheme = scheme?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.licenseURL = licenseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.headers = PlaybackHTTPHeaders.normalized(headers)
        self.forceKey = forceKey
    }

    var playbackCacheKey: String {
        let headerKey = headers
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n")
        return [scheme ?? "", licenseURL ?? "", forceKey ? "force" : "", headerKey].joined(separator: "\n")
    }

    var displayName: String {
        scheme?.nilIfBlank ?? "DRM"
    }
}
