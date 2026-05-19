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

struct BridgeTransientOverlay: Decodable, Hashable {
    let type: String?
    let message: String
    let durationMs: Int?
}

struct BridgePlayResponse: Decodable {
    let ok: Bool?
    let mode: String?
    let url: String?
    let code: String?
    let message: String?
    let prompt: BridgeTokenPrompt?
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
    
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中启用并配置 Type=3 Bridge Server"
        case .invalidBaseURL(let url): return "Bridge Server 地址无效: \(url)"
        case .invalidResponse: return "Bridge Server 响应无效"
        case .server(let message): return "Bridge Server 错误: \(message)"
        case .unsupportedPlayback(let message): return message
        case .tokenRequired(let prompt): return prompt.message
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
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 40
        self.session = URLSession(configuration: config)
    }
    
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: HawkConfig.BRIDGE_ENABLED)
            && !baseURLString.isEmpty
    }
    
    var baseURLString: String {
        UserDefaults.standard.string(forKey: HawkConfig.BRIDGE_SERVER_URL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func updateConfigContext(configUrl: String, spider: String?) {
        let trimmedUrl = configUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSpider = spider?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextQueue.sync {
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
        let contextUrl = configUrl ?? context.configUrl ?? ""
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
    }

    private func bridgeReachableConfigUrl(_ urlString: String) -> String? {
        guard !urlString.isEmpty else { return nil }
        guard let host = URL(string: urlString)?.host?.lowercased() else { return urlString }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return nil }
        return urlString
    }
    
    func home(source: SourceBean) async throws -> String {
        try await registerSourceForRequest(source)
        return try await raw(path: "/api/v1/site/\(escapePath(source.key))/home", body: EmptyBody())
    }
    
    func category(source: SourceBean, sortData: MovieSort.SortData, page: Int, filters: [String: String]?) async throws -> String {
        try await registerSourceForRequest(source)
        let payload = CategoryRequest(categoryId: sortData.id, page: page, filters: filters ?? [:])
        return try await raw(path: "/api/v1/site/\(escapePath(source.key))/category", body: payload)
    }
    
    func detail(source: SourceBean, vodId: String) async throws -> String {
        try await registerSourceForRequest(source)
        return try await raw(path: "/api/v1/site/\(escapePath(source.key))/detail", body: IdRequest(id: vodId))
    }
    
    func search(source: SourceBean, keyword: String, page: Int = 1) async throws -> String {
        try await registerSourceForRequest(source)
        let payload = SearchRequest(keyword: keyword, page: page, quick: source.isQuickSearchEnabled)
        return try await raw(path: "/api/v1/site/\(escapePath(source.key))/search", body: payload)
    }
    
    func play(source: SourceBean, flag: String, id: String) async throws -> String {
        try await registerSourceForRequest(source)
        let payload = PlayRequest(flag: flag, id: id)
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/play", method: "POST", body: payload)
        let response = try decoder.decode(BridgePlayResponse.self, from: data)
        bridgeClientLogger.info("play response source=\(source.key, privacy: .public) ok=\(response.ok == true, privacy: .public) mode=\(response.mode ?? "", privacy: .public) code=\(response.code ?? "", privacy: .public)")
        if response.ok == false {
            if response.code == "token_required", let prompt = response.prompt {
                throw BridgeError.tokenRequired(prompt)
            }
            throw BridgeError.unsupportedPlayback(response.message ?? response.code ?? "Bridge 暂不支持该播放结果")
        }
        guard response.mode == "direct", let url = response.url, !url.isEmpty else {
            throw BridgeError.unsupportedPlayback("Bridge 未返回可直接播放地址")
        }
        return url
    }

    func submitToken(source: SourceBean, prompt: BridgeTokenPrompt, values: [String: String]) async throws {
        try await registerSourceForRequest(source)
        let token = values["token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = TokenSubmitRequest(provider: prompt.provider, token: token, values: values)
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/token", method: "POST", body: payload)
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
        try await registerSourceForRequest(source)
        let payload = JarUiOpenRequest(action: prompt.action ?? prompt.retry?.action, flag: prompt.retry?.flag, id: prompt.retry?.id)
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/uiOpen", method: "POST", body: payload)
        let response = try decoder.decode(BridgeJarUiResponse.self, from: data)
        guard response.ok != false else { throw BridgeError.server(response.message ?? response.code ?? "Bridge Jar UI 打开失败") }
        bridgeClientLogger.info("jar ui open source=\(source.key, privacy: .public) provider=\(prompt.provider, privacy: .public) ok=\(response.ok == true, privacy: .public)")
        return response
    }

    func jarUiStatus(source: SourceBean, prompt: BridgeTokenPrompt) async throws -> BridgeJarUiStatusResponse {
        try await jarUiStatus(source: source)
    }

    func jarUiStatus(source: SourceBean) async throws -> BridgeJarUiStatusResponse {
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/uiStatus", method: "POST", body: JarUiStatusRequest(includeUi: true))
        let response = try decoder.decode(BridgeJarUiStatusResponse.self, from: data)
        guard response.ok != false else { throw BridgeError.server(response.message ?? response.code ?? "Bridge Jar UI 状态检测失败") }
        bridgeClientLogger.info("jar ui status source=\(source.key, privacy: .public) status=\(response.status ?? "", privacy: .public) done=\(response.done == true, privacy: .public)")
        return response
    }

    func closeJarUi(source: SourceBean, prompt: BridgeTokenPrompt) async throws {
        try await closeJarUi(source: source)
    }

    func closeJarUi(source: SourceBean) async throws {
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/uiClose", method: "POST", body: EmptyBody())
        try validateBridgeOK(data)
    }

    func jarUiAction(source: SourceBean, prompt: BridgeTokenPrompt, action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        try await jarUiAction(source: source, action: action)
    }

    func jarUiAction(source: SourceBean, action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        let payload = JarUiActionRequest(action: action.action, elementId: action.elementId, text: action.text, x: action.x, y: action.y)
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/uiAction", method: "POST", body: payload)
        let response = try decoder.decode(BridgeJarUiResponse.self, from: data)
        guard response.ok != false else { throw BridgeError.server(response.message ?? response.code ?? "Bridge Jar UI 操作失败") }
        return response
    }

    func action(source: SourceBean, video: Movie.Video) async throws -> BridgeActionResponse {
        try await registerSourceForRequest(source)
        let action = video.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ActionRequest(action: action, id: video.id, name: video.name, note: video.note)
        let data = try await request(path: "/api/v1/site/\(escapePath(source.key))/action", method: "POST", body: payload)
        let response = try decoder.decode(BridgeActionResponse.self, from: data)
        bridgeClientLogger.info("action response source=\(source.key, privacy: .public) action=\(action, privacy: .public) ok=\(response.ok == true, privacy: .public) mode=\(response.mode ?? "", privacy: .public) code=\(response.code ?? "", privacy: .public)")
        if response.ok == false {
            if response.code == "token_required", let prompt = response.prompt {
                throw BridgeError.tokenRequired(prompt)
            }
            throw BridgeError.server(response.message ?? response.code ?? "Bridge action 执行失败")
        }
        return response
    }

    private func registerSourceForRequest(_ source: SourceBean) async throws {
        try await register(sources: [source], replace: true)
    }
    
    private func raw<T: Encodable>(path: String, body: T) async throws -> String {
        let data = try await request(path: path, method: "POST", body: body)
        try validateBridgeOK(data)
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeError.invalidResponse }
        return text
    }
    
    private func request<T: Encodable>(path: String, method: String, body: T?) async throws -> Data {
        guard isEnabled || path == "/health" else { throw BridgeError.notConfigured }
        let absolute = normalizedBaseURL() + (path.hasPrefix("/") ? path : "/\(path)")
        guard let url = URL(string: absolute) else { throw BridgeError.invalidBaseURL(baseURLString) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try asciiEscapedJSONData(body)
        }
        bridgeClientLogger.info("request \(method, privacy: .public) \(path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw BridgeError.server("HTTP \(http.statusCode)") }
        bridgeClientLogger.info("response \(path, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        return data
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

    private func validateProvider(_ provider: String?, expected: String, operation: String) throws {
        guard let provider, !provider.isEmpty else { return }
        guard provider.lowercased() == expected.lowercased() else {
            throw BridgeError.server("\(operation) provider 不匹配：请求 \(expected)，返回 \(provider)")
        }
    }
    
    private func normalizedBaseURL() -> String {
        var value = baseURLString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func currentConfigContext() -> (configUrl: String?, spider: String?) {
        contextQueue.sync {
            (contextConfigUrl.nilIfEmpty, contextSpider)
        }
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
