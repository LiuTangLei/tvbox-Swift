import Foundation

/// 直播相关模型 - 对应 Android 版 LiveChannel*.java / Epginfo.java

/// 直播频道分组
struct LiveChannelGroup: Codable, Identifiable, Hashable {
    /// 以分组名作为稳定标识，便于 SwiftUI 列表 diff。
    var id: String { groupName }
    /// 分组名称（如“央视”“卫视”）。
    var groupName: String = ""
    /// 分组在列表中的顺序索引。
    var groupIndex: Int = 0
    /// 分组下频道列表。
    var channels: [LiveChannelItem] = []
    /// 是否为加密分组（当前实现仅保留字段，未启用密码校验）。
    var isPassword: Bool = false
    
    init(groupName: String = "", groupIndex: Int = 0) {
        self.groupName = groupName
        self.groupIndex = groupIndex
    }
}

/// 直播频道
struct LiveChannelItem: Codable, Identifiable, Hashable {
    /// 频道标识由名称+索引组成，规避同名频道冲突。
    var id: String { "\(channelName)_\(channelIndex)" }
    /// 频道名。
    var channelName: String = ""
    /// 频道在分组内的顺序索引。
    var channelIndex: Int = 0
    /// 多线路播放地址。
    var channelUrls: [String] = []
    /// 频道级请求头，来自 m3u/txt 的 ua/origin/referer/header 指令。
    var headers: [String: String] = [:]
    /// 单线路请求头，key 为规范化后的播放地址。
    var urlHeaders: [String: [String: String]] = [:]
    /// 当前选中的线路索引。
    var sourceIndex: Int = 0
    /// 可用线路总数。
    var sourceNum: Int { channelUrls.count }
    /// 台标地址（预留）。
    var logo: String = ""
    /// XMLTV / m3u 的 tvg-id。
    var tvgId: String = ""
    /// XMLTV / m3u 的 tvg-name。
    var tvgName: String = ""
    /// 频道号。
    var number: String = ""
    /// 频道级 EPG URL。
    var epgUrl: String = ""
    /// 播放格式提示，如 HLS/DASH MIME。
    var format: String = ""
    /// 回看类型。
    var catchup: String = ""
    /// 回看 URL 模板。
    var catchupSource: String = ""
    /// 回看替换规则。
    var catchupReplace: String = ""
    
    init(channelName: String = "", channelIndex: Int = 0) {
        self.channelName = channelName
        self.channelIndex = channelIndex
    }
    
    /// 当前线路对应的播放地址。
    /// 当索引越界时兜底返回第一条线路，避免直接播放失败。
    var currentUrl: String? {
        guard sourceIndex >= 0, sourceIndex < channelUrls.count else { return channelUrls.first }
        return channelUrls[sourceIndex]
    }

    /// 当前线路的请求头，频道级 headers 与 URL 级 headers 合并，URL 级优先。
    var currentHeaders: [String: String] {
        headers(for: currentUrl)
    }

    /// 当前线路身份，用于 URL 相同但 headers/format 变化时触发播放器重建。
    var currentPlaybackIdentifier: String {
        let headerKey = currentHeaders
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n")
        return [currentUrl ?? "", headerKey, format].joined(separator: "\n")
    }

    func catchupPlayback(for epg: Epginfo) -> LiveCatchupPlayback? {
        guard let liveURL = currentUrl,
              let catchupURL = catchupURL(for: epg, liveURL: liveURL) else {
            return nil
        }

        var headers = currentHeaders
        if liveURL.lowercased().hasPrefix("rtsp"),
           let range = epg.rtspRange {
            headers["rtsp_range"] = range
        }
        return LiveCatchupPlayback(url: catchupURL, headers: headers, epg: epg)
    }

    func canPlayCatchup(_ epg: Epginfo) -> Bool {
        guard let liveURL = currentUrl else { return false }
        return catchupURL(for: epg, liveURL: liveURL) != nil
    }

    func headers(for url: String?) -> [String: String] {
        var merged = headers
        guard let url else { return merged }
        let key = Self.normalizeURLKey(url)
        if let urlSpecific = urlHeaders[key] {
            merged.merge(urlSpecific, uniquingKeysWith: { _, new in new })
        }
        return merged
    }
    
    /// 轮换到下一条线路。
    mutating func nextSource() {
        if channelUrls.count > 0 {
            sourceIndex = (sourceIndex + 1) % channelUrls.count
        }
    }

    static func normalizeURLKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func catchupURL(for epg: Epginfo, liveURL: String) -> String? {
        guard let template = catchupTemplate(for: liveURL),
              let startDate = epg.startDate,
              let endDate = epg.endDate else {
            return nil
        }

        let resolvedSource = Self.resolveCatchupTokens(
            in: template.source,
            startDate: startDate,
            endDate: endDate
        )
        guard !resolvedSource.isEmpty else { return nil }
        if template.type.caseInsensitiveCompare("default") == .orderedSame { return resolvedSource }
        return Self.appendCatchupSource(
            resolvedSource,
            to: liveURL,
            replaceRule: template.replace
        )
    }

    private func catchupTemplate(for liveURL: String) -> LiveCatchupTemplate? {
        if let source = catchupSource.nilIfBlank {
            return LiveCatchupTemplate(
                type: catchup.nilIfBlank ?? "append",
                source: source,
                replace: catchupReplace
            )
        }
        if liveURL.contains("/PLTV/") {
            return .pltv
        }
        return nil
    }

    private static func appendCatchupSource(
        _ source: String,
        to liveURL: String,
        replaceRule: String
    ) -> String {
        var url = liveURL
        let parts = replaceRule.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            url = url.replacingOccurrences(
                of: String(parts[0]),
                with: String(parts[1]),
                options: .regularExpression
            )
        }

        var suffix = source
        if URLComponents(string: url)?.query?.isEmpty == false {
            suffix = suffix.replacingOccurrences(of: "?", with: "&")
        }
        return url + suffix
    }

    private static func resolveCatchupTokens(
        in template: String,
        startDate: Date,
        endDate: Date
    ) -> String {
        let pattern = #"(\$?\{[^}]*\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        var result = ""
        var cursor = template.startIndex

        for match in regex.matches(in: template, range: range) {
            guard let matchRange = Range(match.range(at: 1), in: template) else { continue }
            result += template[cursor..<matchRange.lowerBound]
            let token = String(template[matchRange])
            result += formattedCatchupToken(token, startDate: startDate, endDate: endDate)
            cursor = matchRange.upperBound
        }

        result += template[cursor..<template.endIndex]
        return result
    }

    private static func formattedCatchupToken(
        _ token: String,
        startDate: Date,
        endDate: Date
    ) -> String {
        guard let open = token.firstIndex(of: "{"),
              let close = token.lastIndex(of: "}"),
              open < close else {
            return ""
        }

        let tag = String(token[token.index(after: open)..<close])
        if tag.hasPrefix("utcend:") { return String(Int(endDate.timeIntervalSince1970)) }
        if tag.hasPrefix("utc:") { return String(Int(startDate.timeIntervalSince1970)) }
        if tag.hasPrefix("(b"), let closeParen = tag.firstIndex(of: ")") {
            let pattern = String(tag[tag.index(after: closeParen)...])
            return formatCatchupTime(startDate, pattern: pattern)
        }
        if tag.hasPrefix("(e"), let closeParen = tag.firstIndex(of: ")") {
            let pattern = String(tag[tag.index(after: closeParen)...])
            return formatCatchupTime(endDate, pattern: pattern)
        }
        return ""
    }

    private static func formatCatchupTime(_ date: Date, pattern: String) -> String {
        if pattern == "timestamp" {
            return String(Int(date.timeIntervalSince1970))
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct LiveCatchupPlayback: Codable, Identifiable, Hashable {
    var id: String { "\(url)_\(epg.id)" }
    var url: String
    var headers: [String: String]
    var epg: Epginfo
}

private struct LiveCatchupTemplate {
    var type: String
    var source: String
    var replace: String

    static let pltv = LiveCatchupTemplate(
        type: "append",
        source: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",
        replace: "/PLTV/,/TVOD/"
    )
}

/// EPG 节目信息
struct Epginfo: Codable, Identifiable, Hashable {
    var id: String { "\(index)_\(title)_\(startTime)_\(endTime)" }
    var title: String = ""
    var startTime: String = ""
    var endTime: String = ""
    var index: Int = 0
    /// Unix timestamp in seconds. Used when XMLTV provides a real date and timezone.
    var startTimestamp: TimeInterval = 0
    /// Unix timestamp in seconds. Used when XMLTV provides a real date and timezone.
    var endTimestamp: TimeInterval = 0
    
    /// 根据 `HH:mm` 时间段判断节目是否正在播出。
    var isLive: Bool {
        if startTimestamp > 0, endTimestamp > 0 {
            let now = Date().timeIntervalSince1970
            return now >= startTimestamp && now < endTimestamp
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let start = formatter.date(from: startTime),
              let end = formatter.date(from: endTime) else { return false }
        
        let now = formatter.date(from: formatter.string(from: Date()))!
        if end < start {
            return now >= start || now < end
        }
        return now >= start && now < end
    }

    var timeRange: String {
        if startTime.isEmpty, endTime.isEmpty { return "" }
        if endTime.isEmpty { return startTime }
        if startTime.isEmpty { return endTime }
        return "\(startTime) - \(endTime)"
    }

    var startDate: Date? {
        guard startTimestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: startTimestamp)
    }

    var endDate: Date? {
        guard endTimestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: endTimestamp)
    }

    var rtspRange: String? {
        guard let startDate, let endDate else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "clock=\(formatter.string(from: startDate))-\(formatter.string(from: endDate))"
    }

    init(
        title: String = "",
        startTime: String = "",
        endTime: String = "",
        index: Int = 0,
        startTimestamp: TimeInterval = 0,
        endTimestamp: TimeInterval = 0
    ) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.index = index
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }

    enum CodingKeys: String, CodingKey {
        case title
        case startTime
        case endTime
        case index
        case startTimestamp
        case endTimestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        startTime = try container.decodeIfPresent(String.self, forKey: .startTime) ?? ""
        endTime = try container.decodeIfPresent(String.self, forKey: .endTime) ?? ""
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        startTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .startTimestamp) ?? 0
        endTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .endTimestamp) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(index, forKey: .index)
        try container.encode(startTimestamp, forKey: .startTimestamp)
        try container.encode(endTimestamp, forKey: .endTimestamp)
    }
}

/// EPG 日期分组
struct LiveEpgDate: Codable, Identifiable, Hashable {
    var id: String { datePresent }
    /// 供 UI 展示的日期文案。
    var datePresent: String = ""
    /// 供接口查询的原始日期值。
    var date: String = ""
    /// 在日期列表中的位置索引。
    var index: Int = 0
    /// 是否被当前 UI 选中。
    var isSelected: Bool = false
}
