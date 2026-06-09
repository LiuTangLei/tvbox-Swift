import Foundation
import OSLog

private let bridgeClientLogger = Logger(subsystem: "com.tvbox.app", category: "bridge-client")

struct BridgeHealth: Decodable {
    let ok: Bool
    let version: String?
    let address: String?
    let port: Int?
    let abi: BridgeAbiInfo?
    let runtimes: [String: String]?
}

struct BridgeAbiInfo: Decodable {
    let primary: String?
    let supported: [String]?
    let x86_64: Bool?
    let armNativeExtractors: Bool?
    let disabledExtractors: [String]?
}

struct BridgePlayback: Hashable {
    let url: String
    let headers: [String: String]
    let fallbackURL: String?
    let proxied: Bool
    let format: String?
    let parse: Int?
    let flag: String?
    let jxFrom: String?
    let expiresAt: TimeInterval?
    let subtitles: [BridgePlaybackSubtitle]
    let danmakus: [BridgePlaybackDanmaku]
    let drm: PlayableDRM?
}

struct BridgePlaybackSubtitle: Decodable, Hashable {
    let url: String?
    let name: String?
    let lang: String?
    let format: String?
    let flag: Int?
}

struct BridgePlaybackDanmaku: Decodable, Hashable {
    let name: String?
    let url: String?
}

struct BridgePlaybackDRM: Decodable, Hashable {
    let key: String?
    let type: String?
    let header: [String: String]?
    let forceKey: Bool?

    private enum CodingKeys: String, CodingKey {
        case key
        case license
        case licenseURL
        case licenseUrl
        case drmLicense
        case type
        case scheme
        case drmScheme
        case header
        case headers
        case forceKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try Self.decodeFirstString(
            from: container,
            keys: [.key, .license, .licenseURL, .licenseUrl, .drmLicense]
        )
        type = try Self.decodeFirstString(
            from: container,
            keys: [.type, .scheme, .drmScheme]
        )
        header = try Self.decodeFirstStringMap(
            from: container,
            keys: [.header, .headers]
        )
        forceKey = try container.decodeIfPresent(Bool.self, forKey: .forceKey)
    }

    private static func decodeFirstString(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String? {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeFirstStringMap(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> [String: String]? {
        for key in keys {
            if let value = try container.decodeIfPresent([String: String].self, forKey: key) {
                return value
            }
        }
        return nil
    }

    var playableDRM: PlayableDRM? {
        let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let normalizedHeader = PlaybackHTTPHeaders.normalized(header)
        guard normalizedKey != nil || normalizedType != nil || !normalizedHeader.isEmpty || forceKey == true else {
            return nil
        }
        return PlayableDRM(
            scheme: normalizedType,
            licenseURL: normalizedKey,
            headers: normalizedHeader,
            forceKey: forceKey == true
        )
    }
}

enum PlaybackHTTPHeaders {
    static func normalized(_ headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !headerValue.isEmpty, !shouldSkip(name) else { continue }
            normalized[name] = headerValue
        }
        return normalized
    }

    static func cacheKey(_ headers: [String: String]) -> String {
        normalized(headers)
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n")
    }

    private static func shouldSkip(_ key: String) -> Bool {
        switch key.lowercased() {
        case "connection", "content-length", "host", "transfer-encoding":
            return true
        default:
            return false
        }
    }
}

enum BridgeServerEndpoint {
    static func normalized(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("//") {
            value = "https:" + value
        } else if !hasExplicitScheme(value) {
            value = "\(preferredScheme(for: value))://\(value)"
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func display(_ rawValue: String) -> String {
        let value = normalized(rawValue)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty else {
            return value
        }
        var text = "\(scheme)://\(host)"
        if let port = components.port, !isDefaultPort(port, for: scheme) {
            text += ":\(port)"
        }
        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            text += path
        }
        return text
    }

    private static func hasExplicitScheme(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
    }

    private static func preferredScheme(for value: String) -> String {
        isLocalEndpoint(value) ? "http" : "https"
    }

    private static func isLocalEndpoint(_ value: String) -> Bool {
        let host = hostCandidate(from: value).lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" { return true }
        if host.hasSuffix(".local") || !host.contains(".") { return true }
        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let first = parts[0]
        let second = parts[1]
        return first == 10
            || first == 127
            || first == 169 && second == 254
            || first == 192 && second == 168
            || first == 172 && (16...31).contains(second)
    }

    private static func hostCandidate(from value: String) -> String {
        let endpoint = value.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? value
        if endpoint.hasPrefix("["),
           let end = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<end])
        }
        let pieces = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 2, pieces[1].allSatisfy(\.isNumber) {
            return String(pieces[0])
        }
        return endpoint
    }

    private static func isDefaultPort(_ port: Int, for scheme: String) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    static func isBridgeProxyURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let bridgeProxyPath = path.hasPrefix("/bridge/local/")
            || path.hasPrefix("/bridge/media/")
            || path == "/proxy"
            || path.hasPrefix("/proxy/")
        guard bridgeProxyPath else { return false }

        let base = normalized(UserDefaults.standard.string(forKey: HawkConfig.BRIDGE_SERVER_URL) ?? "")
        guard let baseURL = URL(string: base), let baseHost = baseURL.host?.lowercased() else {
            return !path.hasPrefix("/proxy")
        }
        guard let host = url.host?.lowercased(), host == baseHost else { return false }
        return effectivePort(url) == effectivePort(baseURL)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

struct BridgeTransientOverlay: Decodable, Hashable {
    let type: String?
    let message: String
    let durationMs: Int?
}

struct BridgePlayResponse: Decodable {
    let ok: Bool?
    let mode: String?
    let url: String?
    let fallbackUrl: String?
    let headers: [String: String]?
    let proxied: Bool?
    let format: String?
    let parse: Int?
    let flag: String?
    let jxFrom: String?
    let expiresAt: TimeInterval?
    let subtitles: [BridgePlaybackSubtitle]?
    let danmakus: [BridgePlaybackDanmaku]?
    let drm: BridgePlaybackDRM?
    let code: String?
    let message: String?
    let prompt: BridgeTokenPrompt?
    let image: String?
    let width: Double?
    let height: Double?
    let elements: [BridgeUiElement]?
    let toast: BridgeTransientOverlay?

    private enum CodingKeys: String, CodingKey {
        case ok
        case mode
        case url
        case fallbackUrl
        case fallbackURL
        case headers
        case header
        case proxied
        case format
        case parse
        case flag
        case jxFrom
        case expiresAt
        case subtitles
        case subs
        case danmakus
        case danmaku
        case drm
        case code
        case message
        case prompt
        case image
        case width
        case height
        case elements
        case toast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        fallbackUrl = try Self.decodeFirstString(from: container, keys: [.fallbackUrl, .fallbackURL])
        headers = try Self.decodeFirstStringMap(from: container, keys: [.headers, .header])
        proxied = try container.decodeIfPresent(Bool.self, forKey: .proxied)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        parse = try container.decodeIfPresent(Int.self, forKey: .parse)
        flag = try container.decodeIfPresent(String.self, forKey: .flag)
        jxFrom = try container.decodeIfPresent(String.self, forKey: .jxFrom)
        expiresAt = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresAt)
        subtitles = try Self.decodeFirstArray(from: container, keys: [.subtitles, .subs])
        danmakus = try Self.decodeFirstArray(from: container, keys: [.danmakus, .danmaku])
        drm = try container.decodeIfPresent(BridgePlaybackDRM.self, forKey: .drm)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        prompt = try container.decodeIfPresent(BridgeTokenPrompt.self, forKey: .prompt)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        elements = try container.decodeIfPresent([BridgeUiElement].self, forKey: .elements)
        toast = try container.decodeIfPresent(BridgeTransientOverlay.self, forKey: .toast)
    }

    private static func decodeFirstString(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String? {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeFirstStringMap(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> [String: String]? {
        for key in keys {
            if let value = try container.decodeIfPresent([String: String].self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeFirstArray<T: Decodable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> [T]? {
        for key in keys {
            if let value = try container.decodeIfPresent([T].self, forKey: key) {
                return value
            }
        }
        return nil
    }

    var containsJarUiSnapshot: Bool {
        image?.isEmpty == false || elements?.isEmpty == false
    }
}

struct BridgeActionResponse: Decodable {
    let ok: Bool?
    let mode: String?
    let action: String?
    let status: String?
    let done: Bool?
    let code: String?
    let message: String?
    let prompt: BridgeTokenPrompt?
    let prompts: [BridgeTokenPrompt]?
    let image: String?
    let width: Double?
    let height: Double?
    let elements: [BridgeUiElement]?
    let toast: BridgeTransientOverlay?

    var containsJarUiSnapshot: Bool {
        image?.isEmpty == false || elements?.isEmpty == false
    }
}

struct BridgeJarUiResponse: Decodable {
    let ok: Bool?
    let mode: String?
    let message: String?
    let image: String?
    let width: Double?
    let height: Double?
    let elements: [BridgeUiElement]?
    let toast: BridgeTransientOverlay?
    let code: String?
}

struct BridgeJarUiStatusResponse: Decodable {
    let ok: Bool?
    let mode: String?
    let status: String?
    let done: Bool?
    let message: String?
    let image: String?
    let width: Double?
    let height: Double?
    let elements: [BridgeUiElement]?
    let toast: BridgeTransientOverlay?
    let code: String?

    var isCompleted: Bool {
        done == true || status == "completed" || status == "success"
    }
}

extension BridgeJarUiResponse {
    init(actionResponse: BridgeActionResponse) {
        self.ok = actionResponse.ok
        self.mode = actionResponse.mode
        self.message = actionResponse.message
        self.image = actionResponse.image
        self.width = actionResponse.width
        self.height = actionResponse.height
        self.elements = actionResponse.elements
        self.toast = actionResponse.toast
        self.code = actionResponse.code
    }

    init(playResponse: BridgePlayResponse) {
        self.ok = playResponse.ok
        self.mode = playResponse.mode
        self.message = playResponse.message
        self.image = playResponse.image
        self.width = playResponse.width
        self.height = playResponse.height
        self.elements = playResponse.elements
        self.toast = playResponse.toast
        self.code = playResponse.code
    }
}

struct BridgeUiElement: Decodable, Identifiable, Hashable {
    let id: String
    let role: String
    let text: String?
    let value: String?
    let hint: String?
    let className: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let clickable: Bool?
    let focusable: Bool?

    var isInteractive: Bool {
        role == "button" || role == "input"
    }

    var displayText: String {
        [text, value, hint, role].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? role
    }
}

struct BridgeJarUiAction: Encodable, Hashable {
    let action: String
    let elementId: String?
    let text: String?
    let x: Double?
    let y: Double?

    static func click(element: BridgeUiElement) -> BridgeJarUiAction {
        BridgeJarUiAction(action: "click", elementId: element.id, text: nil, x: nil, y: nil)
    }

    static func click(x: Double, y: Double) -> BridgeJarUiAction {
        BridgeJarUiAction(action: "click", elementId: nil, text: nil, x: x, y: y)
    }

    static func input(element: BridgeUiElement, text: String) -> BridgeJarUiAction {
        BridgeJarUiAction(action: "input", elementId: element.id, text: text, x: nil, y: nil)
    }

    static func submit(element: BridgeUiElement? = nil) -> BridgeJarUiAction {
        BridgeJarUiAction(action: "submit", elementId: element?.id, text: nil, x: nil, y: nil)
    }

    static func named(_ action: String) -> BridgeJarUiAction {
        BridgeJarUiAction(action: action, elementId: nil, text: nil, x: nil, y: nil)
    }
}

struct BridgeTokenPrompt: Decodable, Identifiable, Hashable {
    let provider: String
    let title: String
    let message: String
    let action: String?
    let login: BridgePromptLogin?
    let fields: [BridgePromptField]
    let retry: BridgePromptRetry?

    var id: String {
        "\(provider)-\(retry?.flag ?? "")-\(retry?.id ?? message)"
    }
}

struct BridgePromptField: Decodable, Identifiable, Hashable {
    let key: String
    let label: String
    let placeholder: String?
    let secure: Bool?
    let multiline: Bool?

    var id: String { key }
}

struct BridgePromptLogin: Decodable, Hashable {
    let type: String
    let title: String?
    let url: String
    let cookieKey: String?
    let domains: [String]?
}

struct BridgePromptRetry: Decodable, Hashable {
    let flag: String?
    let id: String?
    let action: String?
}

enum BridgeError: LocalizedError {
    case notConfigured
    case invalidBaseURL(String)
    case invalidResponse
    case server(String)
    case unsupportedPlayback(String)
    case tokenRequired(BridgeTokenPrompt)
    case jarUiRequired(BridgeJarUiResponse)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中启用并配置 Type=3 Bridge Server"
        case .invalidBaseURL(let url): return "Bridge Server 地址无效: \(url)"
        case .invalidResponse: return "Bridge Server 响应无效"
        case .server(let message): return "Bridge Server 错误: \(message)"
        case .unsupportedPlayback(let message): return message
        case .tokenRequired(let prompt): return prompt.message
        case .jarUiRequired(let response): return response.message ?? "请在 macOS 上操作 Android Jar 弹窗"
        }
    }
}

final class BridgeClient {
    static let shared = BridgeClient()
    
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let contextQueue = DispatchQueue(label: "com.tvbox.app.bridge-client.context")
    private var contextConfigUrl = ""
    private var contextSpider: String?
    private var registeredSourceSignatures: [String: RegistrationRecord] = [:]
    private let registrationCacheTTL: TimeInterval = 3600

    private struct RegistrationRecord {
        let signature: String
        let expiresAt: TimeInterval
    }
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 40
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }
    
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: HawkConfig.BRIDGE_ENABLED)
            && !baseURLString.isEmpty
    }
    
    var baseURLString: String {
        BridgeServerEndpoint.normalized(
            UserDefaults.standard.string(forKey: HawkConfig.BRIDGE_SERVER_URL) ?? ""
        )
    }

    func updateConfigContext(configUrl: String, spider: String?) {
        let trimmedUrl = configUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSpider = spider?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextQueue.sync {
            if contextConfigUrl != trimmedUrl || contextSpider != trimmedSpider {
                registeredSourceSignatures.removeAll()
            }
            contextConfigUrl = trimmedUrl
            contextSpider = trimmedSpider?.isEmpty == false ? trimmedSpider : nil
        }
    }
    
    func health() async throws -> BridgeHealth {
        let data = try await request(path: "/health", method: "GET", body: Optional<EmptyBody>.none)
        let health = try decoder.decode(BridgeHealth.self, from: data)
        guard health.ok else { throw BridgeError.invalidResponse }
        return health
    }
    
    func register(configUrl: String? = nil, spider: String? = nil, sources: [SourceBean], replace: Bool = false) async throws {
        guard isEnabled else { throw BridgeError.notConfigured }
        let context = currentConfigContext()
        let contextUrl = configUrl ?? (replace ? context.configUrl ?? "" : "")
        let contextSpider = spider ?? context.spider
        let payload = RegisterRequest(
            configUrl: bridgeReachableConfigUrl(contextUrl),
            spider: contextSpider,
            replace: replace,
            client: "tvbox-swift",
            platform: currentPlatform,
            preferredLocale: Locale.current.identifier,
            sites: sources.map(BridgeSiteRequest.init(source:))
        )
        let data = try await request(path: "/api/v1/config/register", method: "POST", body: payload)
        try validateBridgeOK(data)
        rememberRegisteredSources(sources, configUrl: contextUrl, spider: contextSpider, replace: replace)
    }

    private func bridgeReachableConfigUrl(_ urlString: String) -> String? {
        guard !urlString.isEmpty else { return nil }
        guard let host = URL(string: urlString)?.host?.lowercased() else { return urlString }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return nil }
        return urlString
    }
    
    func home(source: SourceBean) async throws -> String {
        try await raw(source: source, path: "/api/v1/site/\(escapePath(source.key))/home", body: EmptyBody())
    }
    
    func category(source: SourceBean, sortData: MovieSort.SortData, page: Int, filters: [String: String]?) async throws -> String {
        let payload = CategoryRequest(categoryId: sortData.id, page: page, filters: filters ?? [:])
        return try await raw(source: source, path: "/api/v1/site/\(escapePath(source.key))/category", body: payload)
    }
    
    func detail(source: SourceBean, vodId: String) async throws -> String {
        try await raw(source: source, path: "/api/v1/site/\(escapePath(source.key))/detail", body: IdRequest(id: vodId))
    }
    
    func search(source: SourceBean, keyword: String, page: Int = 1, quick: Bool = false) async throws -> String {
        let payload = SearchRequest(keyword: keyword, page: page, quick: quick)
        return try await raw(source: source, path: "/api/v1/site/\(escapePath(source.key))/search", body: payload)
    }
    
    func play(source: SourceBean, flag: String, id: String) async throws -> BridgePlayback {
        let payload = PlayRequest(flag: flag, id: id)
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/play", method: "POST", body: payload)
        let response = try decoder.decode(BridgePlayResponse.self, from: data)
        bridgeClientLogger.info("play response source=\(source.key, privacy: .public) ok=\(response.ok == true, privacy: .public) mode=\(response.mode ?? "", privacy: .public) proxied=\(response.proxied == true, privacy: .public) hasFallback=\((response.fallbackUrl?.isEmpty == false), privacy: .public) hasDRM=\((response.drm?.playableDRM != nil), privacy: .public) code=\(response.code ?? "", privacy: .public)")
        if response.containsJarUiSnapshot {
            throw BridgeError.jarUiRequired(BridgeJarUiResponse(playResponse: response))
        }
        if response.code == "token_required", let prompt = response.prompt {
            throw BridgeError.tokenRequired(prompt)
        }
        if response.ok == false {
            throw BridgeError.unsupportedPlayback(response.message ?? response.code ?? "Bridge 暂不支持该播放结果")
        }
        guard response.mode == "direct", let url = response.url, !url.isEmpty else {
            throw BridgeError.unsupportedPlayback("Bridge 未返回可直接播放地址")
        }
        let fallbackURL = response.fallbackUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgePlayback(
            url: url,
            headers: PlaybackHTTPHeaders.normalized(response.headers),
            fallbackURL: fallbackURL?.isEmpty == false ? fallbackURL : nil,
            proxied: response.proxied == true,
            format: response.format?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            parse: response.parse,
            flag: response.flag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            jxFrom: response.jxFrom?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            expiresAt: response.expiresAt,
            subtitles: response.subtitles ?? [],
            danmakus: response.danmakus ?? [],
            drm: response.drm?.playableDRM
        )
    }

    func submitToken(source: SourceBean, prompt: BridgeTokenPrompt, values: [String: String]) async throws {
        let token = values["token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = TokenSubmitRequest(provider: prompt.provider, token: token, values: values)
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/token", method: "POST", body: payload)
        try validateBridgeOK(data)
        BridgeCredentialStore.shared.save(provider: prompt.provider, values: values)
        bridgeClientLogger.info("token submitted source=\(source.key, privacy: .public) provider=\(prompt.provider, privacy: .public)")
    }

    func submitSavedTokenIfAvailable(source: SourceBean, prompt: BridgeTokenPrompt) async -> Bool {
        let values = BridgeCredentialStore.shared.values(provider: prompt.provider, fields: prompt.fields)
        guard values.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        do {
            try await submitToken(source: source, prompt: prompt, values: values)
            return true
        } catch {
            return false
        }
    }

    func openJarUi(source: SourceBean, prompt: BridgeTokenPrompt) async throws -> BridgeJarUiResponse {
        let payload = JarUiOpenRequest(action: prompt.action ?? prompt.retry?.action, flag: prompt.retry?.flag, id: prompt.retry?.id)
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/uiOpen", method: "POST", body: payload)
        let response = try decoder.decode(BridgeJarUiResponse.self, from: data)
        guard response.ok != false else { throw BridgeError.server(response.message ?? response.code ?? "Bridge Jar UI 打开失败") }
        bridgeClientLogger.info("jar ui open source=\(source.key, privacy: .public) provider=\(prompt.provider, privacy: .public) ok=\(response.ok == true, privacy: .public)")
        return response
    }

    func jarUiStatus(source: SourceBean, prompt: BridgeTokenPrompt) async throws -> BridgeJarUiStatusResponse {
        try await jarUiStatus(source: source)
    }

    func jarUiStatus(source: SourceBean) async throws -> BridgeJarUiStatusResponse {
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/uiStatus", method: "POST", body: JarUiStatusRequest(includeUi: true))
        let response = try decoder.decode(BridgeJarUiStatusResponse.self, from: data)
        guard response.ok != false else { throw BridgeError.server(response.message ?? response.code ?? "Bridge Jar UI 状态检测失败") }
        bridgeClientLogger.info("jar ui status source=\(source.key, privacy: .public) status=\(response.status ?? "", privacy: .public) done=\(response.done == true, privacy: .public)")
        return response
    }

    func closeJarUi(source: SourceBean, prompt: BridgeTokenPrompt) async throws {
        try await closeJarUi(source: source)
    }

    func closeJarUi(source: SourceBean) async throws {
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/uiClose", method: "POST", body: EmptyBody())
        try validateBridgeOK(data)
    }

    func jarUiAction(source: SourceBean, prompt: BridgeTokenPrompt, action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        try await jarUiAction(source: source, action: action)
    }

    func jarUiAction(source: SourceBean, action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        let payload = JarUiActionRequest(action: action.action, elementId: action.elementId, text: action.text, x: action.x, y: action.y)
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/uiAction", method: "POST", body: payload)
        let response = try decoder.decode(BridgeJarUiResponse.self, from: data)
        guard response.ok != false else { throw BridgeError.server(response.message ?? response.code ?? "Bridge Jar UI 操作失败") }
        return response
    }

    func action(source: SourceBean, video: Movie.Video) async throws -> BridgeActionResponse {
        let action = video.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ActionRequest(action: action, id: video.id, name: video.name, note: video.note)
        let data = try await requestRegistered(source: source, path: "/api/v1/site/\(escapePath(source.key))/action", method: "POST", body: payload)
        let response = try decoder.decode(BridgeActionResponse.self, from: data)
        bridgeClientLogger.info("action response source=\(source.key, privacy: .public) action=\(action, privacy: .public) ok=\(response.ok == true, privacy: .public) mode=\(response.mode ?? "", privacy: .public) code=\(response.code ?? "", privacy: .public)")
        if response.code == "token_required", let prompt = response.prompt {
            throw BridgeError.tokenRequired(prompt)
        }
        if response.ok == false {
            throw BridgeError.server(response.message ?? response.code ?? "Bridge action 执行失败")
        }
        return response
    }

    private func registerSourceForRequest(_ source: SourceBean, force: Bool = false) async throws {
        let context = currentConfigContext()
        let contextUrl = ""
        let signature = registrationSignature(source: source, configUrl: contextUrl, spider: context.spider)
        if !force, isRegistrationFresh(sourceKey: source.key, signature: signature) { return }
        try await register(sources: [source], replace: false)
    }
    
    private func raw<T: Encodable>(source: SourceBean, path: String, body: T) async throws -> String {
        let data = try await requestRegistered(source: source, path: path, method: "POST", body: body)
        try validateBridgeOK(data)
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeError.invalidResponse }
        return text
    }

    private func raw<T: Encodable>(path: String, body: T) async throws -> String {
        let data = try await request(path: path, method: "POST", body: body)
        try validateBridgeOK(data)
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeError.invalidResponse }
        return text
    }

    private func requestRegistered<T: Encodable>(source: SourceBean, path: String, method: String, body: T?) async throws -> Data {
        try await registerSourceForRequest(source)
        let data = try await request(path: path, method: method, body: body)
        guard isSiteNotFoundResponse(data, source: source) else { return data }

        bridgeClientLogger.warning("registered site missing after bridge restart source=\(source.key, privacy: .public); re-registering")
        forgetRegisteredSource(source.key)
        try await registerSourceForRequest(source, force: true)
        return try await request(path: path, method: method, body: body)
    }
    
    private func request<T: Encodable>(path: String, method: String, body: T?) async throws -> Data {
        guard isEnabled || path == "/health" else { throw BridgeError.notConfigured }
        let absolute = normalizedBaseURL() + (path.hasPrefix("/") ? path : "/\(path)")
        guard let url = URL(string: absolute) else { throw BridgeError.invalidBaseURL(baseURLString) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval(for: path)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyExternalBaseHeaders(to: &request)
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try asciiEscapedJSONData(body)
        }
        let retryable = canRetryRequest(method: method, path: path)
        let maxAttempts = retryable ? 3 : 1
        let endpoint = BridgeServerEndpoint.display(baseURLString)
        var lastError: Error?

        for attempt in 1...maxAttempts {
            let attemptStarted = Date()
            bridgeClientLogger.info("request \(method, privacy: .public) \(path, privacy: .public) attempt=\(attempt, privacy: .public)")
            do {
                let (data, response) = try await session.data(for: request)
                let elapsedMs = Int(Date().timeIntervalSince(attemptStarted) * 1000)
                guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse }
                if (200...299).contains(http.statusCode) {
                    bridgeClientLogger.info("response \(path, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) attempt=\(attempt, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
                    return data
                }
                if isTransientGatewayStatus(http.statusCode), attempt < maxAttempts {
                    bridgeClientLogger.warning("transient bridge gateway status=\(http.statusCode, privacy: .public) path=\(path, privacy: .public) attempt=\(attempt, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
                    try await sleepBeforeRetry(attempt: attempt)
                    continue
                }
                throw BridgeError.server("HTTP \(http.statusCode) \(path) @ \(endpoint)")
            } catch {
                let elapsedMs = Int(Date().timeIntervalSince(attemptStarted) * 1000)
                lastError = error
                guard attempt < maxAttempts, retryable, shouldRetryNetworkError(error) else { throw error }
                bridgeClientLogger.warning("transient bridge network error path=\(path, privacy: .public) attempt=\(attempt, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                try await sleepBeforeRetry(attempt: attempt)
            }
        }

        if let lastError { throw lastError }
        throw BridgeError.invalidResponse
    }

    private func canRetryRequest(method: String, path: String) -> Bool {
        if method.uppercased() == "GET" { return true }
        let lowercasedPath = path.lowercased()
        return lowercasedPath == "/api/v1/config/register"
            || lowercasedPath.hasSuffix("/home")
            || lowercasedPath.hasSuffix("/category")
            || lowercasedPath.hasSuffix("/detail")
            || lowercasedPath.hasSuffix("/search")
            || lowercasedPath.hasSuffix("/uistatus")
    }

    private func timeoutInterval(for path: String) -> TimeInterval {
        let lowercasedPath = path.lowercased()
        if lowercasedPath == "/health" || lowercasedPath == "/api/v1/config/register" {
            return 5
        }
        if lowercasedPath.hasSuffix("/play") || lowercasedPath.hasSuffix("/uiopen") {
            return 35
        }
        if lowercasedPath.hasSuffix("/uistatus")
            || lowercasedPath.hasSuffix("/uiaction")
            || lowercasedPath.hasSuffix("/uiclose")
            || lowercasedPath.hasSuffix("/token") {
            return 12
        }
        return 18
    }

    private func applyExternalBaseHeaders(to request: inout URLRequest) {
        guard let components = URLComponents(string: normalizedBaseURL()),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = forwardedHostHeader(from: components) else {
            return
        }
        request.setValue(scheme, forHTTPHeaderField: "X-Forwarded-Proto")
        request.setValue(host, forHTTPHeaderField: "X-Forwarded-Host")
    }

    private func forwardedHostHeader(from components: URLComponents) -> String? {
        guard var host = components.host, !host.isEmpty else { return nil }
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        if let port = components.port {
            host += ":\(port)"
        }
        return host
    }

    private func isTransientGatewayStatus(_ statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private func shouldRetryNetworkError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed,
             .badServerResponse:
            return true
        default:
            return false
        }
    }

    private func sleepBeforeRetry(attempt: Int) async throws {
        let delayNanoseconds = UInt64(attempt) * 300_000_000
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }

    private func asciiEscapedJSONData<T: Encodable>(_ body: T) throws -> Data {
        let data = try encoder.encode(body)
        guard let text = String(data: data, encoding: .utf8) else { return data }

        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value <= 0x7F {
                escaped.unicodeScalars.append(scalar)
            } else if value <= 0xFFFF {
                escaped += String(format: "\\u%04X", value)
            } else {
                let plane = value - 0x10000
                let high = 0xD800 + (plane >> 10)
                let low = 0xDC00 + (plane & 0x3FF)
                escaped += String(format: "\\u%04X\\u%04X", high, low)
            }
        }
        return Data(escaped.utf8)
    }
    
    private func validateBridgeOK(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let ok = object["ok"] as? Bool, !ok {
            let message = object["message"] as? String
                ?? object["code"] as? String
                ?? "未知错误"
            throw BridgeError.server(message)
        }
    }

    private func isSiteNotFoundResponse(_ data: Data, source: SourceBean) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool,
              ok == false else {
            return false
        }
        let code = object["code"] as? String
        let message = object["message"] as? String
        if code == "site_not_found" { return true }
        return message?.contains("Bridge site not found: \(source.key)") == true
    }

    private func validateProvider(_ provider: String?, expected: String, operation: String) throws {
        guard let provider, !provider.isEmpty else { return }
        guard provider.lowercased() == expected.lowercased() else {
            throw BridgeError.server("\(operation) provider 不匹配：请求 \(expected)，返回 \(provider)")
        }
    }
    
    private func normalizedBaseURL() -> String {
        var value = BridgeServerEndpoint.normalized(baseURLString)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func currentConfigContext() -> (configUrl: String?, spider: String?) {
        contextQueue.sync {
            (contextConfigUrl.nilIfEmpty, contextSpider)
        }
    }

    private func isRegistrationFresh(sourceKey: String, signature: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return contextQueue.sync {
            guard let record = registeredSourceSignatures[sourceKey] else { return false }
            return record.signature == signature && record.expiresAt > now
        }
    }

    private func forgetRegisteredSource(_ sourceKey: String) {
        contextQueue.sync {
            registeredSourceSignatures[sourceKey] = nil
        }
    }

    private func rememberRegisteredSources(_ sources: [SourceBean], configUrl: String, spider: String?, replace: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        let expiresAt = now + registrationCacheTTL
        let records = sources.map { source in
            (source.key, RegistrationRecord(
                signature: registrationSignature(source: source, configUrl: configUrl, spider: spider),
                expiresAt: expiresAt
            ))
        }
        contextQueue.sync {
            if replace { registeredSourceSignatures.removeAll() }
            for (key, record) in records {
                registeredSourceSignatures[key] = record
            }
        }
    }

    private func registrationSignature(source: SourceBean, configUrl: String, spider: String?) -> String {
        [
            normalizedBaseURL(),
            BridgeServerEndpoint.normalized(configUrl),
            spider ?? "",
            source.key,
            source.name,
            source.api,
            String(source.type),
            String(source.searchable),
            String(source.filterable),
            String(source.quickSearch),
            String(source.indexs),
            String(source.playerType),
            source.ext ?? "",
            source.jar ?? ""
        ].joined(separator: "\u{1F}")
    }
    
    private func escapePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
    
    private var currentPlatform: String {
        #if os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }
}

private struct EmptyBody: Encodable {}

private struct RegisterRequest: Encodable {
    let configUrl: String?
    let configUrlBase64: String?
    let spider: String?
    let spiderBase64: String?
    let replace: Bool
    let client: String
    let platform: String
    let preferredLocale: String
    let sites: [BridgeSiteRequest]

    init(configUrl: String?, spider: String?, replace: Bool, client: String, platform: String, preferredLocale: String, sites: [BridgeSiteRequest]) {
        self.configUrl = configUrl
        self.configUrlBase64 = configUrl?.bridgeBase64
        self.spider = spider
        self.spiderBase64 = spider?.bridgeBase64
        self.replace = replace
        self.client = client
        self.platform = platform
        self.preferredLocale = preferredLocale
        self.sites = sites
    }
}

private struct BridgeSiteRequest: Encodable {
    let key: String
    let name: String
    let api: String
    let searchable: Int
    let filterable: Int
    let quickSearch: Int
    let indexs: Int
    let playerType: Int
    let type: Int
    let ext: String?
    let jar: String?
    
    init(source: SourceBean) {
        key = source.key
        name = source.name
        api = source.api
        searchable = source.searchable
        filterable = source.filterable
        quickSearch = source.quickSearch
        indexs = source.indexs
        playerType = source.playerType
        type = source.type
        ext = source.ext
        jar = source.jar
    }
}

private struct CategoryRequest: Encodable {
    let categoryId: String
    let categoryIdBase64: String
    let page: Int
    let filters: [String: String]

    init(categoryId: String, page: Int, filters: [String: String]) {
        self.categoryId = categoryId
        self.categoryIdBase64 = categoryId.bridgeBase64
        self.page = page
        self.filters = filters
    }
}

private struct IdRequest: Encodable {
    let id: String
    let idBase64: String

    init(id: String) {
        self.id = id
        self.idBase64 = id.bridgeBase64
    }
}

private struct SearchRequest: Encodable {
    let keyword: String
    let keywordBase64: String
    let page: Int
    let quick: Bool

    init(keyword: String, page: Int, quick: Bool) {
        self.keyword = keyword
        self.keywordBase64 = keyword.bridgeBase64
        self.page = page
        self.quick = quick
    }
}

private struct PlayRequest: Encodable {
    let flag: String
    let id: String

    let flagBase64: String
    let idBase64: String

    init(flag: String, id: String) {
        self.flag = flag
        self.id = id
        self.flagBase64 = flag.bridgeBase64
        self.idBase64 = id.bridgeBase64
    }
}

private struct TokenSubmitRequest: Encodable {
    let provider: String
    let token: String?
    let tokenBase64: String?
    let values: [String: String]

    init(provider: String, token: String?, values: [String: String]) {
        self.provider = provider
        self.token = token
        self.tokenBase64 = token?.bridgeBase64
        self.values = values
    }
}

private struct JarUiOpenRequest: Encodable {
    let action: String?
    let flag: String?
    let id: String?

    let actionBase64: String?
    let flagBase64: String?
    let idBase64: String?

    init(action: String?, flag: String?, id: String?) {
        self.action = action
        self.flag = flag
        self.id = id
        self.actionBase64 = action?.bridgeBase64
        self.flagBase64 = flag?.bridgeBase64
        self.idBase64 = id?.bridgeBase64
    }
}

private struct JarUiStatusRequest: Encodable {
    let includeUi: Bool
}

private struct JarUiActionRequest: Encodable {
    let action: String
    let elementId: String?
    let text: String?
    let textBase64: String?
    let x: Double?
    let y: Double?

    init(action: String, elementId: String?, text: String?, x: Double?, y: Double?) {
        self.action = action
        self.elementId = elementId
        self.text = text
        self.textBase64 = text?.bridgeBase64
        self.x = x
        self.y = y
    }
}

private struct ActionRequest: Encodable {
    let action: String
    let actionBase64: String
    let id: String
    let idBase64: String
    let name: String
    let nameBase64: String
    let note: String
    let noteBase64: String

    init(action: String, id: String, name: String, note: String) {
        self.action = action
        self.actionBase64 = action.bridgeBase64
        self.id = id
        self.idBase64 = id.bridgeBase64
        self.name = name
        self.nameBase64 = name.bridgeBase64
        self.note = note
        self.noteBase64 = note.bridgeBase64
    }
}

final class BridgeCredentialStore {
    static let shared = BridgeCredentialStore()

    private let defaults = UserDefaults.standard
    private let key = "bridge.savedCredentials.v1"
    private let maxAge: TimeInterval = 60 * 60 * 24 * 30

    private init() {}

    func save(provider: String, values: [String: String]) {
        let cleaned = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        guard !cleaned.isEmpty else { return }
        var records = loadRecords()
        records[normalized(provider)] = BridgeCredentialRecord(savedAt: Date().timeIntervalSince1970, values: cleaned)
        saveRecords(records)
    }

    func values(provider: String, fields: [BridgePromptField]) -> [String: String] {
        guard let record = loadRecords()[normalized(provider)] else { return Dictionary(uniqueKeysWithValues: fields.map { ($0.key, "") }) }
        guard Date().timeIntervalSince1970 - record.savedAt < maxAge else { return Dictionary(uniqueKeysWithValues: fields.map { ($0.key, "") }) }
        var result = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, "") })
        for field in fields {
            if let value = record.values[field.key], !value.isEmpty {
                result[field.key] = value
            } else if field.key == "token", let value = record.values["cookie"] ?? record.values["value"], !value.isEmpty {
                result[field.key] = value
            }
        }
        return result
    }

    private func normalized(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func loadRecords() -> [String: BridgeCredentialRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([String: BridgeCredentialRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func saveRecords(_ records: [String: BridgeCredentialRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

private struct BridgeCredentialRecord: Codable {
    let savedAt: TimeInterval
    let values: [String: String]
}

private extension String {
    var bridgeBase64: String {
        Data(utf8).base64EncodedString()
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
