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
}

/// EPG 节目信息
struct Epginfo: Codable, Identifiable, Hashable {
    var id: String { "\(title)_\(startTime)" }
    var title: String = ""
    var startTime: String = ""
    var endTime: String = ""
    var index: Int = 0
    
    /// 根据 `HH:mm` 时间段判断节目是否正在播出。
    var isLive: Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let start = formatter.date(from: startTime),
              let end = formatter.date(from: endTime) else { return false }
        
        let now = formatter.date(from: formatter.string(from: Date()))!
        return now >= start && now < end
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
