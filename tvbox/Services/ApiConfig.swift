import Foundation
import CommonCrypto

/// 核心配置管理器 - 对应 Android 版 ApiConfig.java
/// 负责加载和解析远程 JSON 配置，管理视频源列表
@MainActor
class ApiConfig: ObservableObject {
    static let shared = ApiConfig()
    private static let maxConfigResolveDepth = 6
    private static let maxRedirectCandidates = 20
    private static let rawConfigCacheTTL: TimeInterval = 20
    private static let maxRawConfigCacheEntries = 24
    private static let configRequestHeaders = [
        "User-Agent": "okhttp/4.12.0",
        "Accept": "*/*"
    ]

    struct MultiRepoOption: Identifiable, Equatable {
        let name: String
        let url: String

        var id: String { url.lowercased() }
    }

    struct LiveSourceOption: Identifiable, Equatable {
        let id: String
        let name: String
        let index: Int
        let url: String?
    }

    @Published var sourceBeanList: [SourceBean] = []
    @Published var homeSourceBean: SourceBean?
    @Published var parseBeanList: [ParseBean] = []
    @Published var liveChannelGroupList: [LiveChannelGroup] = []
    @Published var liveSourceOptions: [LiveSourceOption] = []
    @Published var homeLiveSourceOption: LiveSourceOption?
    @Published var dohList: [(name: String, url: String)] = []
    @Published var isLoaded: Bool = false
    @Published var configUrl: String = ""
    @Published var liveConfigUrl: String = ""
    @Published var wallpaper: String = ""

    private let network = NetworkManager.shared
    private var activeLoadToken = UUID()
    private var liveParseTask: Task<Void, Never>?
    private var currentLiveConfig: AppConfigData?
    private var currentLiveConfigUrl: String?
    private struct RawConfigCacheEntry {
        let content: String
        let fetchedAt: Date
    }
    private var rawConfigCache: [String: RawConfigCacheEntry] = [:]

    private init() {}

    var playableSourceBeanList: [SourceBean] {
        sourceBeanList.filter { $0.isAvailableForPlayback }
    }

    /// 加载远程配置
    func loadConfig(from apiUrl: String) async throws {
        try await loadConfigs(vodApiUrl: apiUrl, liveApiUrl: apiUrl)
    }

    /// 分别加载点播配置和直播配置
    func loadConfigs(vodApiUrl: String, liveApiUrl: String) async throws {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            throw ConfigError.parseError("点播接口地址不能为空")
        }
        let loadToken = UUID()
        activeLoadToken = loadToken
        liveParseTask?.cancel()
        liveParseTask = nil

        let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
        self.configUrl = trimmedVod
        self.liveConfigUrl = resolvedLive

        if trimmedVod == resolvedLive {
            let configResult = try await fetchConfig(from: trimmedVod)
            guard activeLoadToken == loadToken else { return }
            await parseConfig(
                configResult.config,
                apiUrl: configResult.loadedFrom,
                includeSources: true,
                includeLive: false,
                loadToken: loadToken
            )
            scheduleLiveParsing(
                config: configResult.config,
                apiUrl: configResult.loadedFrom,
                loadToken: loadToken
            )
        } else {
            async let vodConfigTask = fetchConfig(from: trimmedVod)
            async let liveConfigTask = fetchConfig(from: resolvedLive)
            let (vodConfig, liveConfig) = try await (vodConfigTask, liveConfigTask)
            guard activeLoadToken == loadToken else { return }
            await parseConfig(
                vodConfig.config,
                apiUrl: vodConfig.loadedFrom,
                includeSources: true,
                includeLive: false,
                loadToken: loadToken
            )
            scheduleLiveParsing(
                config: liveConfig.config,
                apiUrl: liveConfig.loadedFrom,
                loadToken: loadToken
            )
        }
        guard activeLoadToken == loadToken else { return }

        self.isLoaded = true
    }

    /// 直播分组改为后台解析，避免阻塞首页首屏进入。
    private func scheduleLiveParsing(config: AppConfigData, apiUrl: String, loadToken: UUID) {
        liveParseTask?.cancel()
        liveParseTask = Task { [config, apiUrl] in
            await parseConfig(
                config,
                apiUrl: apiUrl,
                includeSources: false,
                includeLive: true,
                loadToken: loadToken
            )
        }
    }

    private func fetchConfig(from apiUrl: String) async throws -> (config: AppConfigData, loadedFrom: String) {
        try await fetchConfig(
            from: apiUrl,
            visitedUrls: Set<String>(),
            depth: 0
        )
    }

    private func fetchConfig(
        from apiUrl: String,
        visitedUrls: Set<String>,
        depth: Int
    ) async throws -> (config: AppConfigData, loadedFrom: String) {
        guard depth <= Self.maxConfigResolveDepth else {
            throw ConfigError.parseError("配置跳转层级过深（超过 \(Self.maxConfigResolveDepth) 层）")
        }

        let normalizedUrl = Self.normalizeConfigUrl(apiUrl)
        guard !normalizedUrl.isEmpty else {
            throw ConfigError.parseError("配置地址为空")
        }

        let visitKey = normalizedUrl.lowercased()
        guard !visitedUrls.contains(visitKey) else {
            throw ConfigError.parseError("检测到循环引用的配置地址: \(normalizedUrl)")
        }

        var nextVisited = visitedUrls
        nextVisited.insert(visitKey)

        let jsonStr = try await fetchConfigText(from: normalizedUrl)

        // 清理非标准 JSON（Android 端 Gson 默认支持注释，Swift 需要手动处理）
        let cleanedJson = Self.stripJsonComments(jsonStr)

        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }

        let decoder = JSONDecoder()
        let decodedConfig = try? decoder.decode(AppConfigData.self, from: data)
        if let config = decodedConfig, config.hasUsableContent {
            return (config, normalizedUrl)
        }

        if let multiRepo = try? decoder.decode(MultiRepoConfigData.self, from: data) {
            let candidateUrls = Self.uniqueUrlsInOrder(
                multiRepo.candidateUrls.map(Self.normalizeConfigUrl)
            )

            var lastError: Error?
            for candidateUrl in candidateUrls {
                do {
                    return try await fetchConfig(
                        from: candidateUrl,
                        visitedUrls: nextVisited,
                        depth: depth + 1
                    )
                } catch {
                    lastError = error
                }
            }

            if let lastError {
                throw ConfigError.parseError("多仓库配置中没有可用地址，最后错误: \(lastError.localizedDescription)")
            }
            throw ConfigError.parseError("多仓库配置中没有可用地址")
        }

        let redirectCandidates = Self.extractConfigRedirectCandidates(from: cleanedJson)
            .filter { $0.lowercased() != visitKey && !nextVisited.contains($0.lowercased()) }

        if !redirectCandidates.isEmpty {
            var lastError: Error?
            for candidate in redirectCandidates {
                do {
                    return try await fetchConfig(
                        from: candidate,
                        visitedUrls: nextVisited,
                        depth: depth + 1
                    )
                } catch {
                    lastError = error
                }
            }

            if let lastError {
                throw ConfigError.parseError("页面跳转配置解析失败，最后错误: \(lastError.localizedDescription)")
            }
        }

        if decodedConfig != nil {
            throw ConfigError.parseError("配置缺少可用站点（sites / lives / parses）")
        }

        throw ConfigError.parseError("配置格式不受支持")
    }

    /// 读取配置文本并做短时缓存，避免“多仓探测 + 正式加载”重复请求同一地址。
    private func fetchConfigText(from normalizedUrl: String) async throws -> String {
        let key = normalizedUrl.lowercased()
        let now = Date()

        if let entry = rawConfigCache[key] {
            if now.timeIntervalSince(entry.fetchedAt) <= Self.rawConfigCacheTTL {
                return entry.content
            }
            rawConfigCache.removeValue(forKey: key)
        }

        let (data, response) = try await network.getDataWithResponse(
            from: normalizedUrl,
            headers: Self.configRequestHeaders
        )
        let loadedUrl = response.url?.absoluteString ?? normalizedUrl
        let content = try Self.decodeConfigPayload(data, loadedFrom: loadedUrl)
        rawConfigCache[key] = RawConfigCacheEntry(content: content, fetchedAt: now)
        trimRawConfigCacheIfNeeded()
        return content
    }

    private static func decodeConfigPayload(_ data: Data, loadedFrom urlString: String) throws -> String {
        guard !data.isEmpty else { throw ConfigError.parseError("配置内容为空") }
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        if isJsonObject(text) { return fixConfigRelativePaths(text, loadedFrom: urlString) }
        if text.contains("**") { text = try decodeBase64WrappedConfig(text) }
        let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        if compact.hasPrefix("2423") { text = try decodeCBCConfig(compact) }
        return fixConfigRelativePaths(text, loadedFrom: urlString)
    }

    private static func isJsonObject(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    private static func decodeBase64WrappedConfig(_ text: String) throws -> String {
        guard let range = text.range(
            of: #"[A-Za-z0-9]{8}\*\*"#,
            options: .regularExpression
        ) else {
            return text
        }
        let encoded = String(text[range.upperBound...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else {
            throw ConfigError.parseError("配置 Base64 解码失败")
        }
        return decoded
    }

    private static func decodeCBCConfig(_ text: String) throws -> String {
        let marker = "2324"
        guard let decodedEnvelope = String(data: try hexData(text), encoding: .utf8)?.lowercased(),
              let keyStart = decodedEnvelope.range(of: "$#")?.upperBound,
              let keyEnd = decodedEnvelope.range(of: "#$", range: keyStart..<decodedEnvelope.endIndex)?.lowerBound,
              let markerRange = text.range(of: marker),
              text.count > 26 else {
            throw ConfigError.parseError("配置 AES 信封格式无效")
        }
        let key = padAESKey(String(decodedEnvelope[keyStart..<keyEnd]))
        let iv = padAESKey(String(decodedEnvelope.suffix(13)))
        let cipherStart = markerRange.upperBound
        let cipherEnd = text.index(text.endIndex, offsetBy: -26)
        guard cipherStart < cipherEnd else { throw ConfigError.parseError("配置 AES 密文为空") }
        let cipherText = String(text[cipherStart..<cipherEnd])
        let decrypted = try aesCBCDecrypt(
            cipher: try hexData(cipherText),
            key: Data(key.utf8),
            iv: Data(iv.utf8)
        )
        guard let decoded = String(data: decrypted, encoding: .utf8) else {
            throw ConfigError.parseError("配置 AES 解密结果不是 UTF-8")
        }
        return decoded
    }

    private static func hexData(_ text: String) throws -> Data {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { throw ConfigError.parseError("十六进制配置长度无效") }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw ConfigError.parseError("十六进制配置包含非法字符")
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func aesCBCDecrypt(cipher: Data, key: Data, iv: Data) throws -> Data {
        let outputCapacity = cipher.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            cipher.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipher.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ConfigError.parseError("配置 AES 解密失败: \(status)") }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func padAESKey(_ value: String) -> String {
        value + String(repeating: "0", count: max(0, 16 - value.count))
    }

    private static func fixConfigRelativePaths(_ text: String, loadedFrom urlString: String) -> String {
        var result = text
        let pattern = #"\"(\.|\.\.)/(.?|.+?)\.js\?(.?|.+?)\""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: result) else { continue }
                let original = String(result[matchRange])
                var replacement = original
                    .replacingOccurrences(of: "\"./", with: "\"\(resolveConfigUrl(loadedFrom: urlString, relative: "./"))")
                    .replacingOccurrences(of: "\"../", with: "\"\(resolveConfigUrl(loadedFrom: urlString, relative: "../"))")
                replacement = replacement
                    .replacingOccurrences(of: "./", with: "__JS1__")
                    .replacingOccurrences(of: "../", with: "__JS2__")
                result.replaceSubrange(matchRange, with: replacement)
            }
        }
        result = result.replacingOccurrences(of: "../", with: resolveConfigUrl(loadedFrom: urlString, relative: "../"))
        result = result.replacingOccurrences(of: "./", with: resolveConfigUrl(loadedFrom: urlString, relative: "./"))
        result = result.replacingOccurrences(of: "__JS1__", with: "./")
        result = result.replacingOccurrences(of: "__JS2__", with: "../")
        return result
    }

    private static func resolveConfigUrl(loadedFrom urlString: String, relative: String) -> String {
        guard let base = URL(string: urlString),
              let resolved = URL(string: relative, relativeTo: base)?.absoluteURL else {
            return relative
        }
        return resolved.standardized.absoluteString
    }

    private func trimRawConfigCacheIfNeeded() {
        guard rawConfigCache.count > Self.maxRawConfigCacheEntries else { return }
        let overflow = rawConfigCache.count - Self.maxRawConfigCacheEntries
        let staleKeys = rawConfigCache
            .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(overflow)
            .map(\.key)
        staleKeys.forEach { rawConfigCache.removeValue(forKey: $0) }
    }

    private static func uniqueUrlsInOrder(_ urls: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }

        return result
    }

    /// 从网页/文本中提取可能的配置地址：
    /// - 明文 URL 文本
    /// - data-clipboard-text（常见导航页“点击复制”）
    /// - JSON 片段中的 url 字段
    private static func extractConfigRedirectCandidates(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawCandidates: [String] = []

        if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && !trimmed.contains("\n") {
            rawCandidates.append(trimmed)
        }

        rawCandidates.append(contentsOf: matchCaptureGroup(
            pattern: #"data-clipboard-text\s*=\s*["']([^"']+)["']"#,
            in: content
        ))
        rawCandidates.append(contentsOf: matchCaptureGroup(
            pattern: #""url"\s*:\s*"([^"]+)""#,
            in: content
        ))
        rawCandidates.append(contentsOf: matchCaptureGroup(
            pattern: #"(https?://[^\s"'<>\\]+)"#,
            in: content
        ))

        let normalized = rawCandidates
            .map(sanitizeExtractedUrl)
            .map(normalizeConfigUrl)
            .filter { !$0.isEmpty }
            .filter(isLikelyConfigPointerUrl)
            .filter { !isLikelyBinaryAssetUrl($0) }

        return Array(uniqueUrlsInOrder(normalized).prefix(maxRedirectCandidates))
    }

    private static func matchCaptureGroup(pattern: String, in content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: range)

        return matches.compactMap { match in
            guard match.numberOfRanges >= 2,
                  let subRange = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[subRange])
        }
    }

    private static func sanitizeExtractedUrl(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "\\/", with: "/")

        while let last = result.last, [".", ",", ";", ")", "]", "}", "\"", "'"].contains(last) {
            result.removeLast()
        }
        while let first = result.first, ["\"", "'", "(", "[", "{"].contains(first) {
            result.removeFirst()
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyBinaryAssetUrl(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        let path = components.path.lowercased()
        return path.hasSuffix(".png")
            || path.hasSuffix(".jpg")
            || path.hasSuffix(".jpeg")
            || path.hasSuffix(".webp")
            || path.hasSuffix(".gif")
            || path.hasSuffix(".svg")
            || path.hasSuffix(".ico")
            || path.hasSuffix(".css")
            || path.hasSuffix(".woff")
            || path.hasSuffix(".woff2")
            || path.hasSuffix(".ttf")
    }

    private static func isLikelyConfigPointerUrl(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }

        let host = (components.host ?? "").lowercased()
        let path = components.path.lowercased()
        let query = (components.percentEncodedQuery ?? "").lowercased()

        if host.contains("raw.githubusercontent.com") || host.contains("githubusercontent.com") {
            return true
        }

        if path.contains(".json")
            || path.hasSuffix("/tv")
            || path.hasSuffix("/tv/")
            || path.hasSuffix("/m")
            || path.hasSuffix("/m/")
            || path.contains("tvbox")
            || path.contains("box")
            || query.contains("json")
            || query.contains("config")
            || query.contains("url=") {
            return true
        }

        return false
    }

    /// 统一规范配置 URL：
    /// 1) 修正 https:/xxx 之类的单斜杠写法；
    /// 2) 将 github.com/.../blob/... 转为 raw.githubusercontent.com/...；
    /// 3) 兼容 gh-proxy + github/blob 的嵌套代理地址。
    static func normalizeConfigUrl(_ rawUrl: String) -> String {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let fixedScheme = fixMalformedSchemeIfNeeded(trimmed)

        if let normalizedProxy = normalizeGhProxyWrappedUrl(fixedScheme) {
            return normalizedProxy
        }

        if let githubRaw = convertGitHubBlobUrlToRaw(fixedScheme) {
            return githubRaw
        }

        return fixedScheme
    }

    private static func fixMalformedSchemeIfNeeded(_ urlString: String) -> String {
        let fixedHttps = urlString.replacingOccurrences(
            of: #"^https:/(?!/)"#,
            with: "https://",
            options: .regularExpression
        )
        return fixedHttps.replacingOccurrences(
            of: #"^http:/(?!/)"#,
            with: "http://",
            options: .regularExpression
        )
    }

    private static func normalizeGhProxyWrappedUrl(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host.contains("gh-proxy") else {
            return nil
        }

        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        let decodedPath = path.removingPercentEncoding ?? path
        let fixedEmbedded = fixMalformedSchemeIfNeeded(decodedPath)
        guard fixedEmbedded.hasPrefix("http://") || fixedEmbedded.hasPrefix("https://") else {
            return nil
        }

        let normalizedEmbedded = convertGitHubBlobUrlToRaw(fixedEmbedded) ?? fixedEmbedded
        let scheme = components.scheme ?? "https"
        let portSuffix = components.port.map { ":\($0)" } ?? ""

        var rebuilt = "\(scheme)://\(host)\(portSuffix)/\(normalizedEmbedded)"
        if let query = components.percentEncodedQuery, !query.isEmpty {
            rebuilt += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            rebuilt += "#\(fragment)"
        }
        return rebuilt
    }

    private static func convertGitHubBlobUrlToRaw(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "blob" else {
            return nil
        }

        let owner = String(parts[0])
        let repo = String(parts[1])
        let branch = String(parts[3])
        let filePath = parts.dropFirst(4).joined(separator: "/")
        guard !filePath.isEmpty else {
            return nil
        }

        var rawUrl = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(filePath)"
        if let query = components.percentEncodedQuery, !query.isEmpty {
            rawUrl += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            rawUrl += "#\(fragment)"
        }
        return rawUrl
    }

    /// 去除 JSON 中的 // 行注释，兼容 TVBox 配置文件格式
    /// Android 端 Gson 原生支持注释，Swift 的 JSONDecoder 不支持
    static func stripJsonComments(_ json: String) -> String {
        let lines = json.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过纯注释行（以 // 开头）
            if trimmed.hasPrefix("//") {
                continue
            }
            // 处理行尾注释：只在引号外的 // 才是注释
            let cleaned = removeInlineComment(from: line)
            result.append(cleaned)
        }

        var joined = result.joined(separator: "\n")

        // 修复尾部逗号问题：,] 或 ,} （注释行被删除后可能产生）
        // 使用正则替换 , 后面跟着空白和 ] 或 } 的情况
        joined = joined.replacingOccurrences(
            of: ",\\s*([\\]\\}])",
            with: "$1",
            options: .regularExpression
        )
        joined = joined.replacingOccurrences(
            of: #"([}\]])\s*\n\s*(?=\{)"#,
            with: "$1,\n",
            options: .regularExpression
        )
        joined = joined.replacingOccurrences(
            of: #"([}\]])\s*\n\s*(?=\"[^\"]+\"\s*:)"#,
            with: "$1,\n",
            options: .regularExpression
        )

        return joined
    }

    /// 移除行内注释（只处理不在字符串内的 //）
    private static func removeInlineComment(from line: String) -> String {
        var inString = false
        var escape = false
        let chars = Array(line)

        for i in 0..<chars.count {
            let c = chars[i]
            if escape {
                escape = false
                continue
            }
            if c == "\\" && inString {
                escape = true
                continue
            }
            if c == "\"" {
                inString.toggle()
                continue
            }
            if !inString && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                // 找到行内注释，截断
                return String(chars[0..<i]).trimmingCharacters(in: .whitespaces).hasSuffix(",")
                    ? String(String(chars[0..<i]).trimmingCharacters(in: .whitespaces).dropLast())
                    : String(chars[0..<i])
            }
        }
        return line
    }

    /// 仅探测“多仓库入口”并返回可选项。
    /// 返回 nil 表示不是多仓库入口；返回数组表示是多仓库入口（数组可能为空）。
    func fetchMultiRepoOptions(from apiUrl: String) async throws -> [MultiRepoOption]? {
        let normalizedUrl = Self.normalizeConfigUrl(apiUrl)
        let jsonStr = try await fetchConfigText(from: normalizedUrl)
        let cleanedJson = Self.stripJsonComments(jsonStr)

        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }

        let decoder = JSONDecoder()
        if let config = try? decoder.decode(AppConfigData.self, from: data), config.hasUsableContent {
            return nil
        }

        guard let multiRepo = try? decoder.decode(MultiRepoConfigData.self, from: data) else {
            return nil
        }

        let normalizedCandidates = Self.uniqueUrlsInOrder(
            multiRepo.candidateUrls.map(Self.normalizeConfigUrl)
        )

        var options: [MultiRepoOption] = []
        for candidate in normalizedCandidates {
            let matchedEntry = multiRepo.urls?.first(where: {
                Self.normalizeConfigUrl($0.url ?? "") == candidate
            })
            let displayName = matchedEntry?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = URL(string: candidate)?.host ?? candidate
            let resolvedName: String
            if let displayName, !displayName.isEmpty {
                resolvedName = displayName
            } else {
                resolvedName = fallbackName
            }
            options.append(
                MultiRepoOption(
                    name: resolvedName,
                    url: candidate
                )
            )
        }

        return options
    }

    /// 解析配置数据
    private func parseConfig(
        _ config: AppConfigData,
        apiUrl: String,
        includeSources: Bool,
        includeLive: Bool,
        loadToken: UUID
    ) async {
        guard activeLoadToken == loadToken else { return }

        if includeSources {
            // 解析站点列表
            var sources: [SourceBean] = []
            if let sites = config.sites {
                for site in sites {
                    let sourceType = site.type?.value ?? 1
                    let bean = SourceBean(
                        key: site.key ?? UUID().uuidString,
                        name: site.name ?? "未命名",
                        api: site.api ?? "",
                        searchable: site.searchable?.value ?? 1,
                        filterable: site.filterable?.value ?? 1,
                        quickSearch: site.quickSearch?.value ?? 1,
                        indexs: site.indexs?.value ?? 0,
                        changeable: site.changeable?.value ?? 1,
                        playerType: site.playerType?.value ?? 0,
                        type: sourceType,
                        ext: site.ext?.stringValue,
                        jar: sourceType == 3 ? (site.jar ?? config.spider) : nil
                    )
                    sources.append(bean)
                }
            }
            self.sourceBeanList = sources
            BridgeClient.shared.updateConfigContext(configUrl: apiUrl, spider: config.spider)
            if BridgeClient.shared.isEnabled {
                Task {
                    try? await BridgeClient.shared.register(
                        configUrl: "",
                        spider: config.spider,
                        sources: sources.filter { $0.requiresBridge },
                        replace: true
                    )
                }
            }

            self.homeSourceBean = preferredHomeSource(in: sources)

            // 解析解析器列表
            if let parses = config.parses {
                self.parseBeanList = parses.map { p in
                    ParseBean(name: p.name ?? "", url: p.url ?? "", type: p.type?.value ?? 0)
                }
            } else {
                self.parseBeanList = []
            }

            // 解析 DoH 列表
            if let dohs = config.doh {
                self.dohList = dohs.compactMap { d in
                    guard let name = d.name, let url = d.url else { return nil }
                    return (name: name, url: url)
                }
            } else {
                self.dohList = []
            }

            // 壁纸
            self.wallpaper = config.wallpaper ?? ""
        }

        if includeLive {
            currentLiveConfig = config
            currentLiveConfigUrl = apiUrl
            if let lives = config.lives {
                let parsedGroups = await parseLives(lives, apiUrl: apiUrl, loadToken: loadToken)
                guard activeLoadToken == loadToken else { return }
                liveChannelGroupList = parsedGroups
            } else {
                liveSourceOptions = []
                homeLiveSourceOption = nil
                liveChannelGroupList = []
            }
        }
    }

    /// 解析直播列表
    private func parseLives(
        _ lives: [AppConfigData.LiveConfig],
        apiUrl: String,
        loadToken: UUID
    ) async -> [LiveChannelGroup] {
        let options = Self.liveSourceOptions(from: lives, baseConfigUrl: apiUrl)
        liveSourceOptions = options
        guard let selectedOption = preferredLiveSourceOption(in: options),
              lives.indices.contains(selectedOption.index) else {
            homeLiveSourceOption = nil
            return []
        }
        homeLiveSourceOption = selectedOption

        var mergedGroups: [String: LiveChannelGroup] = [:]

        guard activeLoadToken == loadToken else { return [] }
        let live = lives[selectedOption.index]
        let defaultHeaders = Self.liveDefaultHeaders(live)
        let defaultEpgUrl = live.epg?.nilIfBlank ?? ""
        let parsePasswordGroups = !Self.livePassFlag(live.pass)

        if let channels = live.channels {
            let inlineGroups = parseInlineLiveChannels(
                channels,
                defaultHeaders: defaultHeaders,
                defaultEpgUrl: defaultEpgUrl,
                parsePasswordGroups: parsePasswordGroups
            )
            mergeLiveGroups(inlineGroups, into: &mergedGroups)
        }

        if let liveUrl = live.url?.nilIfBlank {
            let resolvedUrl = resolveLiveUrl(liveUrl, baseConfigUrl: apiUrl)
            do {
                let content = try await NetworkManager.shared.getString(
                    from: resolvedUrl,
                    headers: defaultHeaders.isEmpty ? nil : defaultHeaders
                )
                guard activeLoadToken == loadToken else { return [] }
                let groups = parseLiveContent(
                    content,
                    defaultHeaders: defaultHeaders,
                    defaultEpgUrl: defaultEpgUrl,
                    parsePasswordGroups: parsePasswordGroups
                )
                mergeLiveGroups(groups, into: &mergedGroups)
                liveChannelGroupList = sortedGroups(from: mergedGroups)
            } catch {
                print("加载直播源失败: \(resolvedUrl), error: \(error)")
            }
        }

        return sortedGroups(from: mergedGroups)
    }

    func setHomeLiveSource(_ option: LiveSourceOption) {
        guard liveSourceOptions.contains(option) else { return }
        UserDefaults.standard.set(option.name, forKey: HawkConfig.LIVE_HOME_SOURCE)
        homeLiveSourceOption = option
        guard let config = currentLiveConfig,
              let apiUrl = currentLiveConfigUrl else {
            return
        }

        let loadToken = activeLoadToken
        liveParseTask?.cancel()
        liveParseTask = Task { [config, apiUrl] in
            let groups = await parseLives(config.lives ?? [], apiUrl: apiUrl, loadToken: loadToken)
            guard activeLoadToken == loadToken else { return }
            liveChannelGroupList = groups
        }
    }

    private func preferredLiveSourceOption(in options: [LiveSourceOption]) -> LiveSourceOption? {
        guard !options.isEmpty else { return nil }
        if let saved = UserDefaults.standard.string(forKey: HawkConfig.LIVE_HOME_SOURCE),
           let found = options.first(where: { $0.name == saved }) {
            return found
        }
        if let current = homeLiveSourceOption,
           let found = options.first(where: { $0.name == current.name }) {
            return found
        }
        return options.first
    }

    private static func liveSourceOptions(
        from lives: [AppConfigData.LiveConfig],
        baseConfigUrl: String
    ) -> [LiveSourceOption] {
        lives.enumerated().map { index, live in
            let name = liveSourceName(for: live, index: index, baseConfigUrl: baseConfigUrl)
            return LiveSourceOption(
                id: "\(index)|\(name)",
                name: name,
                index: index,
                url: live.url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            )
        }
    }

    private static func liveSourceName(
        for live: AppConfigData.LiveConfig,
        index: Int,
        baseConfigUrl: String
    ) -> String {
        if let name = live.name?.nilIfBlank { return name }
        if let url = live.url?.nilIfBlank,
           let parsedURL = URL(string: url, relativeTo: URL(string: baseConfigUrl))?.absoluteURL {
            let lastPath = parsedURL.deletingPathExtension().lastPathComponent
            if !lastPath.isEmpty, lastPath != "/" { return lastPath }
            if let host = parsedURL.host, !host.isEmpty { return host }
        }
        return "直播源 \(index + 1)"
    }

    private struct LiveChannelMetadata {
        var logo: String = ""
        var tvgId: String = ""
        var tvgName: String = ""
        var number: String = ""
        var epgUrl: String = ""
        var format: String = ""
        var catchup: String = ""
        var catchupSource: String = ""
        var catchupReplace: String = ""
        var headers: [String: String] = [:]
        var urlHeaders: [String: [String: String]] = [:]
        var drm: PlayableDRM?

        init() {}

        init(
            logo: String,
            tvgId: String,
            tvgName: String,
            number: String,
            epgUrl: String,
            format: String,
            catchup: String,
            catchupSource: String,
            catchupReplace: String,
            headers: [String: String],
            urlHeaders: [String: [String: String]],
            drm: PlayableDRM? = nil
        ) {
            self.logo = logo
            self.tvgId = tvgId
            self.tvgName = tvgName
            self.number = number
            self.epgUrl = epgUrl
            self.format = format
            self.catchup = catchup
            self.catchupSource = catchupSource
            self.catchupReplace = catchupReplace
            self.headers = headers
            self.urlHeaders = urlHeaders
            self.drm = drm
        }

        init(_ channel: LiveChannelItem) {
            logo = channel.logo
            tvgId = channel.tvgId
            tvgName = channel.tvgName
            number = channel.number
            epgUrl = channel.epgUrl
            format = channel.format
            catchup = channel.catchup
            catchupSource = channel.catchupSource
            catchupReplace = channel.catchupReplace
            headers = channel.headers
            urlHeaders = channel.urlHeaders
            drm = channel.drm
        }
    }

    private struct LiveStreamOptions {
        var headers: [String: String] = [:]
        var drm: PlayableDRM?
    }

    private struct LiveGroupAccess {
        var name: String
        var password: String
        var isPassword: Bool
    }

    private struct LiveDRMBuilder {
        private var scheme: String?
        private var license: String?
        private var headers: [String: String] = [:]
        private var forceKey = false

        var playableDRM: PlayableDRM? {
            let normalizedScheme = scheme?.nilIfBlank
            let normalizedLicense = Self.normalizedLicense(license, scheme: normalizedScheme)
            guard normalizedScheme != nil || normalizedLicense != nil else { return nil }
            return PlayableDRM(
                scheme: normalizedScheme,
                licenseURL: normalizedLicense,
                headers: headers,
                forceKey: forceKey
            )
        }

        mutating func setScheme(_ value: String?) {
            guard let value = value?.nilIfBlank else { return }
            scheme = value
        }

        mutating func setLicense(_ value: String?) {
            guard let value = value?.nilIfBlank else { return }
            let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            license = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            if parts.count > 1 {
                headers.merge(Self.headerPairs(String(parts[1])), uniquingKeysWith: { _, new in new })
            }
        }

        mutating func setForceKey(_ value: String?) {
            guard let value = value?.nilIfBlank else { return }
            forceKey = NSString(string: value).boolValue
        }

        mutating func merge(_ drm: PlayableDRM?) {
            guard let drm else { return }
            setScheme(drm.scheme)
            setLicense(drm.licenseURL)
            headers.merge(drm.headers, uniquingKeysWith: { _, new in new })
            forceKey = forceKey || drm.forceKey
        }

        private static func normalizedLicense(_ value: String?, scheme: String?) -> String? {
            guard let value = value?.nilIfBlank else { return nil }
            guard scheme?.lowercased().contains("clearkey") == true else { return value }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.lowercased().hasPrefix("http") {
                return trimmed
            }

            let keys = trimmed.split(separator: ",").compactMap { pair -> [String: String]? in
                let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let kid = base64URLHex(String(parts[0])),
                      let key = base64URLHex(String(parts[1])) else {
                    return nil
                }
                return ["kty": "oct", "kid": kid, "k": key]
            }
            guard !keys.isEmpty,
                  let data = try? JSONSerialization.data(
                    withJSONObject: ["keys": keys, "type": "temporary"],
                    options: []
                  ),
                  let json = String(data: data, encoding: .utf8) else {
                return trimmed
            }
            return json
        }

        private static func base64URLHex(_ value: String) -> String? {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count.isMultiple(of: 2) else { return nil }

            var bytes: [UInt8] = []
            var index = clean.startIndex
            while index < clean.endIndex {
                let next = clean.index(index, offsetBy: 2)
                guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }

            return Data(bytes)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        private static func headerPairs(_ payload: String) -> [String: String] {
            var headers: [String: String] = [:]
            let normalized = payload.replacingOccurrences(of: "|", with: "&")
            for part in normalized.split(separator: "&") {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let key = strippedValue(String(pair[0]))
                let value = strippedValue(String(pair[1]))
                guard !key.isEmpty, !value.isEmpty else { continue }
                headers[key] = value
            }
            return PlaybackHTTPHeaders.normalized(headers)
        }

        private static func strippedValue(_ value: String) -> String {
            var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while result.hasPrefix("\"") || result.hasPrefix("'") {
                result.removeFirst()
            }
            while result.hasSuffix("\"") || result.hasSuffix("'") {
                result.removeLast()
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 解析 m3u / txt 格式的直播内容
    private func parseLiveContent(
        _ content: String,
        defaultHeaders: [String: String] = [:],
        defaultEpgUrl: String = "",
        parsePasswordGroups: Bool = true
    ) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        var currentGroupName = "默认"

        let lines = content.components(separatedBy: .newlines)
        let firstNonEmptyLine = lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isM3U = firstNonEmptyLine?.uppercased().hasPrefix("#EXTM3U") == true

        // 检测是否为 M3U 格式
        if isM3U {
            var currentName = ""
            var currentGroup = "默认"
            var currentMetadata = LiveChannelMetadata()
            var pendingHeaders: [String: String] = [:]
            var pendingFormat = ""
            var pendingDRM = LiveDRMBuilder()
            var globalEpgUrl = defaultEpgUrl

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                if trimmed.hasPrefix("#EXTM3U") {
                    let attributes = Self.parseM3UAttributes(trimmed)
                    globalEpgUrl = attributes["tvg-url"] ?? attributes["url-tvg"] ?? globalEpgUrl
                } else if Self.applyLiveDirective(trimmed, headers: &pendingHeaders, format: &pendingFormat, drm: &pendingDRM) {
                    continue
                } else if trimmed.hasPrefix("#EXTINF:") {
                    let attributes = Self.parseM3UAttributes(trimmed)
                    if let nameRange = trimmed.range(of: ",", options: .backwards) {
                        currentName = String(trimmed[nameRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    if currentName.isEmpty {
                        currentName = attributes["tvg-name"] ?? attributes["name"] ?? ""
                    }
                    currentGroup = attributes["group-title"] ?? "默认"
                    currentMetadata = LiveChannelMetadata(
                        logo: attributes["tvg-logo"] ?? "",
                        tvgId: attributes["tvg-id"] ?? "",
                        tvgName: attributes["tvg-name"] ?? "",
                        number: attributes["tvg-chno"] ?? "",
                        epgUrl: attributes["tvg-url"] ?? attributes["url-tvg"] ?? globalEpgUrl,
                        format: "",
                        catchup: attributes["catchup"] ?? "",
                        catchupSource: attributes["catchup-source"] ?? "",
                        catchupReplace: attributes["catchup-replace"] ?? "",
                        headers: [:],
                        urlHeaders: [:]
                    )
                    if let userAgent = attributes["http-user-agent"]?.nilIfBlank {
                        currentMetadata.headers["User-Agent"] = userAgent
                    }
                } else if Self.isLiveStreamLine(trimmed) {
                    if !currentName.isEmpty {
                        let parsed = Self.parseLiveStreamLine(trimmed)
                        guard let streamURL = parsed.url, Self.isLiveStreamUrl(streamURL) else { continue }
                        var metadata = currentMetadata
                        metadata.format = pendingFormat.nilIfBlank ?? metadata.format
                        let extinfHeaders = metadata.headers
                        metadata.headers = defaultHeaders
                        metadata.headers.merge(extinfHeaders, uniquingKeysWith: { _, new in new })
                        metadata.headers.merge(pendingHeaders, uniquingKeysWith: { _, new in new })
                        var drmBuilder = pendingDRM
                        drmBuilder.merge(parsed.drm)
                        metadata.drm = drmBuilder.playableDRM ?? metadata.drm
                        if !parsed.headers.isEmpty {
                            metadata.urlHeaders[LiveChannelItem.normalizeURLKey(streamURL)] = parsed.headers
                        }
                        appendChannel(
                            named: currentName,
                            urls: [streamURL],
                            metadata: metadata,
                            to: currentGroup,
                            parsePasswordGroups: parsePasswordGroups,
                            groups: &groups
                        )
                        currentName = ""
                        currentMetadata = LiveChannelMetadata()
                        pendingHeaders = [:]
                        pendingFormat = ""
                        pendingDRM = LiveDRMBuilder()
                    }
                }
            }
        } else {
            var pendingHeaders: [String: String] = [:]
            var pendingFormat = ""
            var pendingDRM = LiveDRMBuilder()
            // TXT 格式: 分组名,#genre#  或  频道名,url
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                if Self.applyLiveDirective(trimmed, headers: &pendingHeaders, format: &pendingFormat, drm: &pendingDRM) {
                    continue
                }

                if trimmed.hasSuffix(",#genre#") || trimmed.hasSuffix("，#genre#") {
                    currentGroupName = trimmed
                        .replacingOccurrences(of: ",#genre#", with: "")
                        .replacingOccurrences(of: "，#genre#", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    pendingHeaders = [:]
                    pendingFormat = ""
                    pendingDRM = LiveDRMBuilder()
                    continue
                }

                let parts = trimmed.components(separatedBy: ",")
                if parts.count >= 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    let url = parts[1...].joined(separator: ",").trimmingCharacters(in: .whitespaces)

                    var parsedStreams: [(url: String, headers: [String: String], drm: PlayableDRM?)] = []
                    for rawStream in url.components(separatedBy: "#") {
                        let parsed = Self.parseLiveStreamLine(rawStream)
                        if let streamURL = parsed.url, Self.isLiveStreamUrl(streamURL) {
                            parsedStreams.append((url: streamURL, headers: parsed.headers, drm: parsed.drm))
                        }
                    }
                    let urls = parsedStreams.map { $0.url }
                    if !name.isEmpty && !urls.isEmpty {
                        var metadata = LiveChannelMetadata()
                        metadata.headers = defaultHeaders
                        metadata.headers.merge(pendingHeaders, uniquingKeysWith: { _, new in new })
                        metadata.format = pendingFormat
                        var drmBuilder = pendingDRM
                        for stream in parsedStreams where !stream.headers.isEmpty {
                            metadata.urlHeaders[LiveChannelItem.normalizeURLKey(stream.url)] = stream.headers
                        }
                        for stream in parsedStreams {
                            drmBuilder.merge(stream.drm)
                        }
                        metadata.drm = drmBuilder.playableDRM
                        appendChannel(
                            named: name,
                            urls: urls,
                            metadata: metadata,
                            to: currentGroupName,
                            parsePasswordGroups: parsePasswordGroups,
                            groups: &groups
                        )
                    }
                }
            }
        }

        return sortedGroups(from: groups)
    }

    private func parseInlineLiveChannels(
        _ channels: [AppConfigData.LiveConfig.LiveChannelConfig],
        defaultHeaders: [String: String] = [:],
        defaultEpgUrl: String = "",
        parsePasswordGroups: Bool = true
    ) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        for channel in channels {
            var metadata = LiveChannelMetadata()
            metadata.logo = channel.logo ?? ""
            metadata.epgUrl = defaultEpgUrl
            metadata.headers = defaultHeaders
            appendChannel(
                named: channel.name ?? "",
                urls: channel.urls ?? [],
                metadata: metadata,
                to: channel.group ?? "其他",
                parsePasswordGroups: parsePasswordGroups,
                groups: &groups
            )
        }
        return sortedGroups(from: groups)
    }

    private func mergeLiveGroups(_ incomingGroups: [LiveChannelGroup], into groups: inout [String: LiveChannelGroup]) {
        for group in incomingGroups {
            for channel in group.channels {
                appendChannel(
                    named: channel.channelName,
                    urls: channel.channelUrls,
                    metadata: LiveChannelMetadata(channel),
                    to: group.groupName,
                    groupAccess: LiveGroupAccess(
                        name: group.groupName,
                        password: group.password,
                        isPassword: group.isPassword
                    ),
                    groups: &groups
                )
            }
        }
    }

    private func appendChannel(
        named channelName: String,
        urls: [String],
        metadata: LiveChannelMetadata,
        to groupName: String,
        groupAccess: LiveGroupAccess? = nil,
        parsePasswordGroups: Bool = true,
        groups: inout [String: LiveChannelGroup]
    ) {
        let normalizedName = Self.normalizeChannelName(channelName)
        guard !normalizedName.isEmpty else { return }

        let validUrls = Self.uniqueLiveUrls(urls)
        guard !validUrls.isEmpty else { return }

        let access = groupAccess ?? Self.liveGroupAccess(from: groupName, parsePasswordGroups: parsePasswordGroups)
        let normalizedGroupName = access.name
        if groups[normalizedGroupName] == nil {
            var group = LiveChannelGroup(
                groupName: normalizedGroupName,
                groupIndex: groups.count
            )
            group.isPassword = access.isPassword
            group.password = access.password
            groups[normalizedGroupName] = group
        }

        guard var group = groups[normalizedGroupName] else { return }
        if access.isPassword {
            group.isPassword = true
            if group.password.isEmpty {
                group.password = access.password
            }
        }

        if let existingIndex = group.channels.firstIndex(where: {
            Self.normalizeChannelName($0.channelName) == normalizedName
        }) {
            var existing = group.channels[existingIndex]
            var existingUrls = Set(existing.channelUrls.map(Self.normalizeLiveUrl))
            for url in validUrls {
                let normalizedUrl = Self.normalizeLiveUrl(url)
                if !existingUrls.contains(normalizedUrl) {
                    existing.channelUrls.append(url)
                    existingUrls.insert(normalizedUrl)
                }
            }
            Self.applyLiveMetadata(metadata, to: &existing)
            group.channels[existingIndex] = existing
        } else {
            var item = LiveChannelItem(channelName: normalizedName, channelIndex: group.channels.count)
            item.channelUrls = validUrls
            Self.applyLiveMetadata(metadata, to: &item)
            group.channels.append(item)
        }

        groups[normalizedGroupName] = group
    }

    private static func applyLiveMetadata(_ metadata: LiveChannelMetadata, to channel: inout LiveChannelItem) {
        if channel.logo.isEmpty, let value = metadata.logo.nilIfBlank { channel.logo = value }
        if channel.tvgId.isEmpty, let value = metadata.tvgId.nilIfBlank { channel.tvgId = value }
        if channel.tvgName.isEmpty, let value = metadata.tvgName.nilIfBlank { channel.tvgName = value }
        if channel.number.isEmpty, let value = metadata.number.nilIfBlank { channel.number = value }
        if channel.epgUrl.isEmpty, let value = metadata.epgUrl.nilIfBlank { channel.epgUrl = value }
        if channel.format.isEmpty, let value = metadata.format.nilIfBlank { channel.format = value }
        if channel.catchup.isEmpty, let value = metadata.catchup.nilIfBlank { channel.catchup = value }
        if channel.catchupSource.isEmpty, let value = metadata.catchupSource.nilIfBlank { channel.catchupSource = value }
        if channel.catchupReplace.isEmpty, let value = metadata.catchupReplace.nilIfBlank { channel.catchupReplace = value }
        if channel.drm == nil { channel.drm = metadata.drm }

        channel.headers.merge(normalizedLiveHeaders(metadata.headers), uniquingKeysWith: { _, new in new })
        for (url, headers) in metadata.urlHeaders {
            let key = LiveChannelItem.normalizeURLKey(url)
            guard !key.isEmpty else { continue }
            var merged = channel.urlHeaders[key] ?? [:]
            merged.merge(normalizedLiveHeaders(headers), uniquingKeysWith: { _, new in new })
            channel.urlHeaders[key] = merged
        }
    }

    private static func isLiveStreamLine(_ line: String) -> Bool {
        parseLiveStreamLine(line).url.map(isLiveStreamUrl) == true
    }

    private static func parseLiveStreamLine(_ line: String) -> (url: String?, headers: [String: String], drm: PlayableDRM?) {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let url = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = parts.count > 1 ? parseLiveOptionsPayload(String(parts[1])) : LiveStreamOptions()
        return (url?.isEmpty == false ? url : nil, options.headers, options.drm)
    }

    @discardableResult
    private static func applyLiveDirective(
        _ line: String,
        headers: inout [String: String],
        format: inout String,
        drm: inout LiveDRMBuilder
    ) -> Bool {
        let lowercased = line.lowercased()
        if lowercased.hasPrefix("#exthttp:") {
            let payload = String(line.dropFirst("#EXTHTTP:".count))
            let options = parseLiveOptionsPayload(payload)
            headers.merge(options.headers, uniquingKeysWith: { _, new in new })
            drm.merge(options.drm)
            return true
        }
        if lowercased.hasPrefix("#extvlcopt:http-user-agent") {
            setHeader("User-Agent", valueAfter(line, marker: "="), in: &headers)
            return true
        }
        if lowercased.hasPrefix("#extvlcopt:http-origin") {
            setHeader("Origin", valueAfter(line, marker: "="), in: &headers)
            return true
        }
        if lowercased.hasPrefix("#extvlcopt:http-referrer")
            || lowercased.hasPrefix("#extvlcopt:http-referer") {
            setHeader("Referer", valueAfter(line, marker: "="), in: &headers)
            return true
        }
        if lowercased.hasPrefix("#kodiprop:inputstream.adaptive.manifest_type") {
            format = normalizedLiveFormat(valueAfter(line, marker: "=") ?? "")
            return true
        }
        if lowercased.hasPrefix("#kodiprop:inputstream.adaptive.license_key") {
            drm.setLicense(valueAfter(line, marker: "license_key=") ?? valueAfter(line, marker: "="))
            return true
        }
        if lowercased.hasPrefix("#kodiprop:inputstream.adaptive.license_type") {
            drm.setScheme(valueAfter(line, marker: "license_type=") ?? valueAfter(line, marker: "="))
            return true
        }
        if lowercased.hasPrefix("#kodiprop:inputstream.adaptive.drm_legacy") {
            if let payload = valueAfter(line, marker: "drm_legacy=") ?? valueAfter(line, marker: "=") {
                let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                drm.setScheme(parts.first.map(String.init))
                if parts.count > 1 {
                    drm.setLicense(String(parts[1]))
                }
            }
            return true
        }
        if lowercased.hasPrefix("#kodiprop:inputstream.adaptive.stream_headers")
            || lowercased.hasPrefix("#kodiprop:inputstream.adaptive.common_headers") {
            let options = parseLiveOptionsPayload(valueAfter(line, marker: "=") ?? "")
            headers.merge(options.headers, uniquingKeysWith: { _, new in new })
            drm.merge(options.drm)
            return true
        }
        if lowercased.hasPrefix("ua") {
            setHeader("User-Agent", valueAfter(line, marker: "user-agent=") ?? valueAfter(line, marker: "ua="), in: &headers)
            return true
        }
        if lowercased.hasPrefix("origin") {
            setHeader("Origin", valueAfter(line, marker: "origin="), in: &headers)
            return true
        }
        if lowercased.hasPrefix("referer") || lowercased.hasPrefix("referrer") {
            setHeader("Referer", valueAfter(line, marker: "referer=") ?? valueAfter(line, marker: "referrer="), in: &headers)
            return true
        }
        if lowercased.hasPrefix("header") {
            let options = parseLiveOptionsPayload(valueAfter(line, marker: "header=") ?? "")
            headers.merge(options.headers, uniquingKeysWith: { _, new in new })
            drm.merge(options.drm)
            return true
        }
        if lowercased.hasPrefix("format") {
            format = normalizedLiveFormat(valueAfter(line, marker: "format=") ?? "")
            return true
        }
        if lowercased.hasPrefix("forcekey") {
            drm.setForceKey(valueAfter(line, marker: "forceKey=") ?? valueAfter(line, marker: "="))
            return true
        }
        return false
    }

    private static func parseM3UAttributes(_ line: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"([A-Za-z0-9_-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            attributes[String(line[keyRange]).lowercased()] = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return attributes
    }

    private static func parseHeaderPayload(_ payload: String) -> [String: String] {
        parseLiveOptionsPayload(payload).headers
    }

    private static func parseLiveOptionsPayload(_ payload: String) -> LiveStreamOptions {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return LiveStreamOptions() }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return liveOptions(from: object.reduce(into: [String: String]()) { result, item in
                result[item.key] = "\(item.value)"
            })
        }
        return parseLiveOptionsPairs(trimmed)
    }

    private static func parseHeaderPairs(_ payload: String) -> [String: String] {
        parseLiveOptionsPairs(payload).headers
    }

    private static func parseLiveOptionsPairs(_ payload: String) -> LiveStreamOptions {
        var pairs: [String: String] = [:]
        func appendPair(_ part: String) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return }
            let key = strippedDirectiveValue(String(pair[0]))
            let value = strippedDirectiveValue(String(pair[1]))
            guard !key.isEmpty, !value.isEmpty else { return }
            pairs[key] = value
        }

        for segment in payload.split(separator: "&", omittingEmptySubsequences: false) {
            let text = String(segment)
            let key = text
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map { strippedDirectiveValue(String($0)).lowercased() }
            if key == "drmlicense" {
                appendPair(text)
            } else {
                for part in text.split(separator: "|", omittingEmptySubsequences: false) {
                    appendPair(String(part))
                }
            }
        }
        return liveOptions(from: pairs)
    }

    private static func liveOptions(from pairs: [String: String]) -> LiveStreamOptions {
        var headers: [String: String] = [:]
        var drm = LiveDRMBuilder()
        for (rawKey, rawValue) in pairs {
            let key = strippedDirectiveValue(rawKey)
            let value = strippedDirectiveValue(rawValue)
            switch key.lowercased() {
            case "drmscheme":
                drm.setScheme(value)
            case "drmlicense":
                drm.setLicense(value)
            case "forcekey":
                drm.setForceKey(value)
            default:
                headers[key] = value
            }
        }
        return LiveStreamOptions(headers: normalizedLiveHeaders(headers), drm: drm.playableDRM)
    }

    private static func normalizedLiveHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            result[key] = value
        }
    }

    private static func setHeader(_ key: String, _ value: String?, in headers: inout [String: String]) {
        guard let value = value?.nilIfBlank else { return }
        headers[key] = value
    }

    private static func valueAfter(_ line: String, marker: String) -> String? {
        guard let range = line.range(of: marker, options: [.caseInsensitive]) else { return nil }
        return strippedDirectiveValue(String(line[range.upperBound...]))
    }

    private static func strippedDirectiveValue(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("\"") || result.hasPrefix("'") {
            result.removeFirst()
        }
        while result.hasSuffix("\"") || result.hasSuffix("'") {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLiveFormat(_ value: String) -> String {
        let trimmed = strippedDirectiveValue(value)
        switch trimmed.lowercased() {
        case "hls", "m3u8":
            return "application/x-mpegURL"
        case "mpd", "dash":
            return "application/dash+xml"
        default:
            return trimmed
        }
    }

    private static func liveDefaultHeaders(_ live: AppConfigData.LiveConfig) -> [String: String] {
        var headers: [String: String] = [:]
        if let userAgent = live.ua?.nilIfBlank {
            headers["User-Agent"] = userAgent
        }
        return headers
    }

    private func sortedGroups(from groups: [String: LiveChannelGroup]) -> [LiveChannelGroup] {
        groups.values
            .sorted { $0.groupIndex < $1.groupIndex }
            .map { group in
                var reindexedGroup = group
                reindexedGroup.channels = group.channels.enumerated().map { index, channel in
                    var reindexedChannel = channel
                    reindexedChannel.channelIndex = index
                    return reindexedChannel
                }
                return reindexedGroup
            }
    }

    private func resolveLiveUrl(_ urlString: String, baseConfigUrl: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let url = URL(string: trimmed), url.scheme != nil {
            return Self.normalizeConfigUrl(trimmed)
        }
        guard let baseUrl = URL(string: baseConfigUrl),
              let resolved = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL else {
            return trimmed
        }
        return Self.normalizeConfigUrl(resolved.absoluteString)
    }

    private static func uniqueLiveUrls(_ urls: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        for url in urls {
            let normalized = normalizeLiveUrl(url)
            guard !normalized.isEmpty, isLiveStreamUrl(normalized), !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }

        return result
    }

    private static func normalizeGroupName(_ groupName: String) -> String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "默认" : trimmed
    }

    private static func liveGroupAccess(
        from groupName: String,
        parsePasswordGroups: Bool
    ) -> LiveGroupAccess {
        let normalized = normalizeGroupName(groupName)
        guard parsePasswordGroups,
              let separator = normalized.firstIndex(of: "_") else {
            return LiveGroupAccess(name: normalized, password: "", isPassword: false)
        }

        let name = normalizeGroupName(String(normalized[..<separator]))
        let password = String(normalized[normalized.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            return LiveGroupAccess(name: name, password: "", isPassword: false)
        }
        return LiveGroupAccess(name: name, password: password, isPassword: true)
    }

    private static func livePassFlag(_ value: AnyCodableValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .bool(let bool):
            return bool
        case .int(let int):
            return int != 0
        case .double(let double):
            return double != 0
        case .string(let string):
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y"].contains(normalized)
        case .dict, .array, .null:
            return false
        }
    }

    private static func normalizeChannelName(_ channelName: String) -> String {
        channelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeLiveUrl(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLiveStreamUrl(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("rtmp://")
            || lowercased.hasPrefix("rtsp://")
    }

    /// 获取指定 key 的源
    func getSource(key: String) -> SourceBean? {
        sourceBeanList.first(where: { $0.key == key })
    }

    /// 获取可搜索的源列表
    func getSearchableSources() -> [SourceBean] {
        sourceBeanList.filter { $0.isSearchable }
    }

    @discardableResult
    func reconcileHomeSourceForBridgeAvailability() -> Bool {
        let previousKey = homeSourceBean?.key
        homeSourceBean = preferredHomeSource(in: sourceBeanList)
        return previousKey != homeSourceBean?.key
    }

    /// 设置主页源
    func setHomeSource(_ source: SourceBean) {
        guard source.isAvailableForPlayback else { return }
        self.homeSourceBean = source
        UserDefaults.standard.set(source.key, forKey: HawkConfig.HOME_API)
    }

    private func preferredHomeSource(in sources: [SourceBean]) -> SourceBean? {
        if let saved = UserDefaults.standard.string(forKey: HawkConfig.HOME_API),
           let found = sources.first(where: { $0.key == saved }),
           found.isAvailableForPlayback {
            return found
        }
        if let current = homeSourceBean,
           let found = sources.first(where: { $0.key == current.key }),
           found.isAvailableForPlayback {
            return found
        }
        return sources.first(where: { $0.isAvailableForPlayback }) ?? sources.first
    }
}

enum ConfigError: LocalizedError {
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "配置解析错误: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        }
    }
}
