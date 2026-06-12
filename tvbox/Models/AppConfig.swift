import Foundation

// MARK: - 灵活类型解码器

/// 兼容 JSON 中数值字段可能是字符串 "0" 或整数 0 的情况
/// Android Gson 自动处理此差异，Swift 需要手动兼容
struct FlexibleInt: Codable, Hashable {
    let value: Int
    
    init(_ value: Int) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self.value = intVal
        } else if let stringVal = try? container.decode(String.self),
                  let intVal = Int(stringVal) {
            self.value = intVal
        } else {
            self.value = 0
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// 兼容 ext 字段可能是字符串或对象
struct FlexibleExt: Codable, Hashable {
    let stringValue: String?
    let dictValue: [String: AnyCodableValue]?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self.stringValue = str
            self.dictValue = nil
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self.stringValue = nil
            self.dictValue = dict
        } else {
            self.stringValue = nil
            self.dictValue = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = stringValue {
            try container.encode(str)
        } else if let dict = dictValue {
            try container.encode(dict)
        }
    }
}

/// 通用的 JSON 值类型，用于处理混合类型的字典
enum AnyCodableValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dict([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
        } else {
            self = .null
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .dict(let d): try container.encode(d)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
    
    /// 将可能的任意类型转换为字符串（如果原本是字典或数组，则转为 JSON 字符串）
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .dict, .array:
            if let data = try? JSONEncoder().encode(self),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return nil
        }
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    var stringDictionaryValue: [String: String]? {
        guard case .dict(let values) = self else { return nil }
        let dictionary = values.reduce(into: [String: String]()) { result, item in
            guard let value = item.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !item.key.isEmpty,
                  !value.isEmpty else {
                return
            }
            result[item.key] = value
        }
        return dictionary.isEmpty ? nil : dictionary
    }
}

/// 兼容配置里 header 字段可能是对象、JSON 字符串或普通 "k=v&k2=v2" 字符串。
struct FlexibleStringMap: Codable, Hashable {
    let value: [String: String]

    init(_ value: [String: String] = [:]) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let map = try? container.decode([String: String].self) {
            self.value = PlaybackHTTPHeaders.normalized(map)
            return
        }
        if let value = try? container.decode(String.self) {
            self.value = Self.parse(value)
            return
        }
        self.value = [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    static func parse(_ rawValue: String) -> [String: String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return PlaybackHTTPHeaders.normalized(
                object.reduce(into: [String: String]()) { result, item in
                    if let value = item.value as? String {
                        result[item.key] = value
                    } else if let value = item.value as? CustomStringConvertible {
                        result[item.key] = value.description
                    }
                }
            )
        }

        let separators = CharacterSet(charactersIn: "&\n;")
        let pairs = trimmed.components(separatedBy: separators)
        var result: [String: String] = [:]
        for pair in pairs {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
        return PlaybackHTTPHeaders.normalized(result)
    }
}

// MARK: - 解析接口配置

/// 解析接口配置 - 对应 Android 版 ParseBean.java
struct ParseBean: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String = ""
    var url: String = ""
    var type: Int = 0        // 0:嗅探 1:解析
    var ext: String? = nil
    var flags: [String] = []
    var headers: [String: String] = [:]
    
    init(
        name: String = "",
        url: String = "",
        type: Int = 0,
        ext: String? = nil,
        flags: [String] = [],
        headers: [String: String] = [:]
    ) {
        self.name = name
        self.url = url
        self.type = type
        self.ext = ext
        self.flags = flags
        self.headers = PlaybackHTTPHeaders.normalized(headers)
    }

    func matches(flag: String) -> Bool {
        let normalizedFlag = flag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFlag.isEmpty else { return flags.isEmpty }
        return flags.isEmpty || flags.contains { $0.caseInsensitiveCompare(normalizedFlag) == .orderedSame }
    }
}

// MARK: - API 配置顶层结构

/// API 配置顶层结构 - 对应 JSON 配置文件格式
struct AppConfigData: Codable {
    var spider: String?
    var wallpaper: String?
    var sites: [SiteConfig]?
    var parses: [ParseConfig]?
    var lives: [LiveConfig]?
    var doh: [DoHConfig]?
    var rules: [RuleConfig]?
    var hosts: [String]?
    var flags: [String]?
    var ads: [String]?
    
    struct SiteConfig: Codable {
        var key: String?
        var name: String?
        var api: String?
        var searchable: FlexibleInt?
        var filterable: FlexibleInt?
        var quickSearch: FlexibleInt?
        var indexs: FlexibleInt?
        var changeable: FlexibleInt?
        var playerType: FlexibleInt?
        var type: FlexibleInt?
        var ext: AnyCodableValue?
        var jar: String?
        var style: AnyCodableValue?
        var playUrl: String?
        var categories: [String]?
        var click: String?
        var header: FlexibleStringMap?
        
        enum CodingKeys: String, CodingKey {
            case key, name, api, searchable, filterable, quickSearch, indexs, changeable
            case playerType, type, ext, jar, style, playUrl, categories, click, header
            // type_flag 也可能出现
        }
    }
    
    struct ParseConfig: Codable {
        var name: String?
        var url: String?
        var type: FlexibleInt?
        var ext: FlexibleExt?
    }
    
    struct LiveConfig: Codable {
        var name: String?
        var url: String?
        var type: FlexibleInt?
        var ua: String?
        var epg: String?
        var logo: String?
        var pass: AnyCodableValue?   // Android 配置中存在
        var playerType: FlexibleInt?
        var channels: [LiveChannelConfig]?
        
        struct LiveChannelConfig: Codable {
            var name: String?
            var urls: [String]?
            var group: String?
            var logo: String?
        }
    }
    
    struct DoHConfig: Codable {
        var name: String?
        var url: String?
    }
    
    struct RuleConfig: Codable {
        var name: String?
        var host: String?
        var hosts: [String]?
        var rule: [String]?
        var regex: [String]?
        var filter: [String]?
        var script: [String]?
    }
}

extension AppConfigData {
    /// 是否包含可直接加载的核心内容
    /// 说明：AppConfigData 字段几乎全是可选，任意 JSON 都可能“解码成功”，
    /// 因此需要额外判定，避免把多仓库索引误当成正常配置。
    var hasUsableContent: Bool {
        let hasSites = !(sites?.isEmpty ?? true)
        let hasLives = !(lives?.isEmpty ?? true)
        let hasParses = !(parses?.isEmpty ?? true)
        return hasSites || hasLives || hasParses
    }
}

/// 多仓库合并索引配置（如 tvboxmulti.json）
struct MultiRepoConfigData: Codable {
    var urls: [Entry]?
    
    struct Entry: Codable {
        var name: String?
        var url: String?
    }
    
    var candidateUrls: [String] {
        (urls ?? [])
            .compactMap { $0.url?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
