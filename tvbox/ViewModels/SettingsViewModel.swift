import Foundation
import SwiftUI
import SwiftData

/// 设置 ViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    enum AddressHistoryKind {
        case config
        case bridge

        var defaultsKey: String {
            switch self {
            case .config:
                return HawkConfig.CONFIG_API_HISTORY
            case .bridge:
                return HawkConfig.BRIDGE_SERVER_HISTORY
            }
        }
    }

    /// 当输入地址是“多仓库入口”时，先弹出候选仓库供用户确认。
    struct PendingMultiRepoSelection: Identifiable {
        /// 当前待选择的是点播仓库还是直播仓库。
        enum Target {
            case vod
            case live

            var title: String {
                switch self {
                case .vod: return "点播"
                case .live: return "直播"
                }
            }
        }

        let id = UUID()
        /// 目标类型。
        let target: Target
        /// 用户原始输入地址（用于后续“是否联动 live 地址”判断）。
        let sourceUrl: String
        /// 可选仓库列表。
        let options: [ApiConfig.MultiRepoOption]
    }

    /// 点播配置地址。
    @Published var vodApiUrl: String = ""
    /// 直播配置地址。
    @Published var liveApiUrl: String = ""
    /// 配置加载中状态。
    @Published var isLoadingConfig = false
    /// 配置错误提示。
    @Published var configError: String?
    /// 配置是否加载成功（供 UI 执行后续跳转/收起流程）。
    @Published var configSuccess = false
    /// 多仓库待选状态，为 nil 表示无需弹窗。
    @Published var pendingMultiRepoSelection: PendingMultiRepoSelection?
    /// 最近输入过的配置地址历史。
    @Published private(set) var configApiHistory: [String] = []
    /// 最近输入过的 Bridge 地址历史。
    @Published private(set) var bridgeServerHistory: [String] = []
    /// 点播播放器内核选择。
    @Published var vodPlayerEngine: PlayerEngine = .system
    /// 直播播放器内核选择。
    @Published var livePlayerEngine: PlayerEngine = .system
    /// 解码模式选择。
    @Published var decodeMode: VideoDecodeMode = .auto
    /// VLC 缓冲策略。
    @Published var vlcBufferMode: VLCBufferMode = .defaultMode
    /// 快进/快退步长（秒）。
    @Published var playTimeStep: Int = 10
    /// Type=3 Bridge 是否启用。
    @Published var bridgeEnabled = false
    /// Type=3 Bridge Server 地址。
    @Published var bridgeServerUrl: String = ""
    /// Bridge 连通性状态。
    @Published var bridgeStatusText: String = "未测试"
    /// Bridge 检测中状态。
    @Published var isTestingBridge = false
    /// 缓存占用展示文本。
    @Published var cacheSizeString: String = "0 KB"
    /// 缓存清理结果提示。
    @Published var cacheClearMessage: String?

    /// 快进步长候选项。
    let playTimeStepOptions: [Int] = [5, 10, 15, 30, 60]
    /// 当前构建可用播放器列表。
    let playerEngineOptions: [PlayerEngine] = PlayerEngine.availableEngines
    /// 解码模式候选。
    let decodeModeOptions: [VideoDecodeMode] = VideoDecodeMode.allCases
    /// VLC 缓冲模式候选。
    let vlcBufferModeOptions: [VLCBufferMode] = VLCBufferMode.allCases

    /// 初始化时完成三件事：
    /// 1) 回填已保存的配置地址
    /// 2) 兼容老版本单一播放器字段到新字段
    /// 3) 回填播放/缓存相关设置
    init() {
        let defaults = UserDefaults.standard
        let savedVod = defaults.string(forKey: HawkConfig.API_URL) ?? ""
        vodApiUrl = savedVod
        if let savedLive = defaults.string(forKey: HawkConfig.LIVE_API_URL) {
            liveApiUrl = savedLive
        } else {
            liveApiUrl = savedVod
        }
        loadAddressHistories()
        let hasLegacyPlayer = defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil
        let legacyPlayerRaw = defaults.integer(forKey: HawkConfig.PLAY_TYPE)
        let defaultVodRaw = PlayerEngine.defaultVodEngine.rawValue
        let defaultLiveRaw = PlayerEngine.defaultLiveEngine.rawValue
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultVodRaw, forKey: HawkConfig.PLAY_TYPE_VOD)
        }
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultLiveRaw, forKey: HawkConfig.PLAY_TYPE_LIVE)
        }
        vodPlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_VOD)
        )
        livePlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_LIVE)
        )
        decodeMode = VideoDecodeMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
        vlcBufferMode = VLCBufferMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        )

        let savedStep = defaults.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        playTimeStep = savedStep > 0 ? savedStep : 10
        bridgeEnabled = defaults.bool(forKey: HawkConfig.BRIDGE_ENABLED)
        bridgeServerUrl = BridgeServerEndpoint.normalized(defaults.string(forKey: HawkConfig.BRIDGE_SERVER_URL) ?? "")
        if !bridgeServerUrl.isEmpty {
            defaults.set(bridgeServerUrl, forKey: HawkConfig.BRIDGE_SERVER_URL)
        }
        bridgeStatusText = initialBridgeStatusText(defaults: defaults)
        refreshCacheSize()
    }

    /// 加载配置
    func loadConfig() async {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            configError = "请输入点播接口地址"
            return
        }

        isLoadingConfig = true
        configError = nil
        configSuccess = false
        pendingMultiRepoSelection = nil

        do {
            let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive

            // 若探测到多仓库入口，先中断加载并弹出候选，让用户显式选定目标仓库。
            if let pending = try await detectPendingMultiRepoSelection(
                vodUrl: trimmedVod,
                liveUrl: resolvedLive
            ) {
                pendingMultiRepoSelection = pending
                isLoadingConfig = false
                return
            }

            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            // 保存用户输入（live 允许空值，表示跟随点播地址）。
            UserDefaults.standard.set(trimmedVod, forKey: HawkConfig.API_URL)
            UserDefaults.standard.set(trimmedLive, forKey: HawkConfig.LIVE_API_URL)
            vodApiUrl = trimmedVod
            liveApiUrl = trimmedLive
            addToAddressHistory(trimmedVod, kind: .config)
            if !trimmedLive.isEmpty {
                addToAddressHistory(trimmedLive, kind: .config)
            }
            configSuccess = true
        } catch {
            configError = error.localizedDescription
        }

        isLoadingConfig = false
    }

    /// 处理多仓库弹窗选择结果，并继续走统一加载流程。
    func selectPendingMultiRepoOption(_ option: ApiConfig.MultiRepoOption) async {
        guard let pending = pendingMultiRepoSelection else { return }
        let normalizedSource = ApiConfig.normalizeConfigUrl(pending.sourceUrl)

        switch pending.target {
        case .vod:
            let normalizedLive = ApiConfig.normalizeConfigUrl(liveApiUrl)
            // 若 live 输入与原始 vod 相同，说明用户希望两者共用，选择后同步更新。
            let shouldSyncLive = !liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalizedLive == normalizedSource
            vodApiUrl = option.url
            if shouldSyncLive {
                liveApiUrl = option.url
            }
        case .live:
            liveApiUrl = option.url
        }

        pendingMultiRepoSelection = nil
        await loadConfig()
    }

    /// 取消多仓库选择，恢复到普通待输入状态。
    func cancelPendingMultiRepoSelection() {
        pendingMultiRepoSelection = nil
        isLoadingConfig = false
    }

    /// 尝试识别输入地址是否为多仓库入口。
    /// - Returns: 需要弹窗选择时返回待选对象，否则返回 `nil`。
    private func detectPendingMultiRepoSelection(
        vodUrl: String,
        liveUrl: String
    ) async throws -> PendingMultiRepoSelection? {
        if let vodOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: vodUrl) {
            guard !vodOptions.isEmpty else {
                throw ConfigError.parseError("点播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .vod,
                sourceUrl: vodUrl,
                options: vodOptions
            )
        }

        let normalizedVod = ApiConfig.normalizeConfigUrl(vodUrl)
        let normalizedLive = ApiConfig.normalizeConfigUrl(liveUrl)
        guard normalizedLive != normalizedVod else {
            return nil
        }

        if let liveOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: liveUrl) {
            guard !liveOptions.isEmpty else {
                throw ConfigError.parseError("直播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .live,
                sourceUrl: liveUrl,
                options: liveOptions
            )
        }

        return nil
    }

    // MARK: - 地址历史

    func addressHistory(for kind: AddressHistoryKind) -> [String] {
        switch kind {
        case .config:
            return configApiHistory
        case .bridge:
            return bridgeServerHistory
        }
    }

    /// 读取各类地址历史；老版本统一历史默认迁移到配置地址历史。
    private func loadAddressHistories() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: HawkConfig.CONFIG_API_HISTORY) != nil {
            configApiHistory = defaults.stringArray(forKey: HawkConfig.CONFIG_API_HISTORY) ?? []
        } else {
            let legacyHistory = defaults.stringArray(forKey: "api_history") ?? []
            configApiHistory = legacyHistory
            defaults.set(legacyHistory, forKey: HawkConfig.CONFIG_API_HISTORY)
        }

        bridgeServerHistory = (defaults.stringArray(forKey: HawkConfig.BRIDGE_SERVER_HISTORY) ?? [])
            .map(BridgeServerEndpoint.normalized)
            .filter { !$0.isEmpty }
        defaults.set(bridgeServerHistory, forKey: HawkConfig.BRIDGE_SERVER_HISTORY)
    }

    /// 新增历史并去重，最多保留 10 条。
    private func addToAddressHistory(_ url: String, kind: AddressHistoryKind) {
        let trimmed = kind == .bridge
            ? BridgeServerEndpoint.normalized(url)
            : url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch kind {
        case .config:
            configApiHistory.removeAll { $0 == trimmed }
            configApiHistory.insert(trimmed, at: 0)
            if configApiHistory.count > 10 {
                configApiHistory = Array(configApiHistory.prefix(10))
            }
            UserDefaults.standard.set(configApiHistory, forKey: kind.defaultsKey)
        case .bridge:
            bridgeServerHistory.removeAll { $0 == trimmed }
            bridgeServerHistory.insert(trimmed, at: 0)
            if bridgeServerHistory.count > 10 {
                bridgeServerHistory = Array(bridgeServerHistory.prefix(10))
            }
            UserDefaults.standard.set(bridgeServerHistory, forKey: kind.defaultsKey)
        }
    }

    /// 删除单条地址历史。
    func removeAddressHistory(_ url: String, kind: AddressHistoryKind) {
        switch kind {
        case .config:
            configApiHistory.removeAll { $0 == url }
            UserDefaults.standard.set(configApiHistory, forKey: kind.defaultsKey)
        case .bridge:
            bridgeServerHistory.removeAll { $0 == url }
            UserDefaults.standard.set(bridgeServerHistory, forKey: kind.defaultsKey)
        }
    }

    /// 清除所有缓存
    func clearCache(context: ModelContext) {
        URLCache.shared.removeAllCachedResponses()
        ImageLoader.shared.clearCache()
        ImageCache.shared.clear()
        CacheStore.shared.clearCacheItems(context: context)
        clearTemporaryDirectory()
        refreshCacheSize()
        cacheClearMessage = "缓存已清除"
    }

    /// 设置快进步长
    func setPlayTimeStep(_ step: Int) {
        guard step > 0 else { return }
        playTimeStep = step
        UserDefaults.standard.set(step, forKey: HawkConfig.PLAY_TIME_STEP)
    }

    func setBridgeEnabled(_ enabled: Bool) {
        bridgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: HawkConfig.BRIDGE_ENABLED)
        bridgeStatusText = enabled ? "待检测" : "已停用"
        notifyBridgeAvailabilityChanged()
    }

    func prepareBridgeForSetup() {
        let normalized = normalizeBridgeServerUrlForStorage()
        let shouldEnableBridge = !normalized.isEmpty
        bridgeEnabled = shouldEnableBridge
        bridgeStatusText = shouldEnableBridge ? "待检测" : "未配置"
        UserDefaults.standard.set(shouldEnableBridge, forKey: HawkConfig.BRIDGE_ENABLED)
        addToAddressHistory(normalized, kind: .bridge)
        notifyBridgeAvailabilityChanged()
    }

    func saveBridgeSettingsAndTest() async {
        let normalized = normalizeBridgeServerUrlForStorage()
        UserDefaults.standard.set(bridgeEnabled, forKey: HawkConfig.BRIDGE_ENABLED)
        addToAddressHistory(normalized, kind: .bridge)
        notifyBridgeAvailabilityChanged()
        guard bridgeEnabled, !normalized.isEmpty else {
            bridgeStatusText = bridgeEnabled ? "未配置" : "已停用"
            return
        }
        await testBridge()
    }

    func testBridge() async {
        guard bridgeEnabled else {
            bridgeStatusText = "已停用"
            return
        }
        let normalized = normalizeBridgeServerUrlForStorage()
        guard !normalized.isEmpty else {
            bridgeStatusText = "未配置"
            return
        }
        isTestingBridge = true
        defer { isTestingBridge = false }
        do {
            let health = try await BridgeClient.shared.health()
            UserDefaults.standard.set(normalized, forKey: HawkConfig.BRIDGE_LAST_VERIFIED_URL)
            bridgeStatusText = bridgeStatusDescription(for: health)
        } catch {
            UserDefaults.standard.removeObject(forKey: HawkConfig.BRIDGE_LAST_VERIFIED_URL)
            bridgeStatusText = error.localizedDescription
        }
    }

    private func bridgeStatusDescription(for health: BridgeHealth) -> String {
        var parts = ["可用"]
        let endpoint = BridgeServerEndpoint.display(bridgeServerUrl)
        if !endpoint.isEmpty {
            parts.append(endpoint)
        } else if let address = health.address, !address.isEmpty {
            parts.append(BridgeServerEndpoint.display(address))
        } else if let port = health.port {
            parts.append(":\(port)")
        }
        if let primary = health.abi?.primary, !primary.isEmpty {
            parts.append(primary)
        }
        if health.abi?.armNativeExtractors == false {
            parts.append("P2P受限")
        }
        return parts.joined(separator: " ")
    }

    var bridgeServerSummary: String {
        let endpoint = BridgeServerEndpoint.display(bridgeServerUrl)
        guard !endpoint.isEmpty else { return bridgeStatusText }
        if bridgeStatusText.contains(endpoint) { return bridgeStatusText }
        return "\(endpoint) · \(bridgeStatusText)"
    }

    @discardableResult
    private func normalizeBridgeServerUrlForStorage() -> String {
        let defaults = UserDefaults.standard
        let previous = BridgeServerEndpoint.normalized(defaults.string(forKey: HawkConfig.BRIDGE_SERVER_URL) ?? "")
        let normalized = BridgeServerEndpoint.normalized(bridgeServerUrl)
        bridgeServerUrl = normalized
        defaults.set(normalized, forKey: HawkConfig.BRIDGE_SERVER_URL)
        if previous != normalized {
            defaults.removeObject(forKey: HawkConfig.BRIDGE_LAST_VERIFIED_URL)
        }
        return normalized
    }

    private func initialBridgeStatusText(defaults: UserDefaults) -> String {
        guard bridgeEnabled else { return "已停用" }
        guard !bridgeServerUrl.isEmpty else { return "未配置" }
        let lastVerified = BridgeServerEndpoint.normalized(defaults.string(forKey: HawkConfig.BRIDGE_LAST_VERIFIED_URL) ?? "")
        if lastVerified == bridgeServerUrl {
            return "可用 " + BridgeServerEndpoint.display(bridgeServerUrl)
        }
        return "待检测"
    }

    private func notifyBridgeAvailabilityChanged() {
        let homeSourceChanged = ApiConfig.shared.reconcileHomeSourceForBridgeAvailability()
        NotificationCenter.default.post(
            name: .tvboxBridgeAvailabilityDidChange,
            object: nil,
            userInfo: ["homeSourceChanged": homeSourceChanged]
        )
    }

    /// 设置点播播放器内核
    func setVodPlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        vodPlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
    }

    /// 设置直播播放器内核
    func setLivePlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        livePlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_LIVE)
    }

    /// 设置视频解码模式
    func setDecodeMode(_ mode: VideoDecodeMode) {
        guard decodeModeOptions.contains(mode) else { return }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_DECODE_MODE)
    }

    /// 设置 VLC 缓冲策略
    func setVLCBufferMode(_ mode: VLCBufferMode) {
        guard vlcBufferModeOptions.contains(mode) else { return }
        vlcBufferMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
    }

    /// 统计并刷新缓存占用展示（网络缓存 + 图片缓存磁盘占用）。
    private func refreshCacheSize() {
        let sharedDisk = URLCache.shared.currentDiskUsage
        let imageDisk = ImageLoader.shared.cacheUsage.disk
        cacheSizeString = Self.formatSize(bytes: sharedDisk + imageDisk)
    }

    private func clearTemporaryDirectory() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    /// 格式化字节大小。
    private static func formatSize(bytes: Int) -> String {
        let size = max(0, bytes)
        if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        }
        return String(format: "%.1f MB", Double(size) / 1024.0 / 1024.0)
    }
}
