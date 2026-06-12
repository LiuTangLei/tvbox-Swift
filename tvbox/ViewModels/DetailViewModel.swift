import Foundation
import OSLog
import SwiftUI

private let detailPlaybackLogger = Logger(subsystem: "com.tvbox.app", category: "detail-playback")

struct PlaybackQualityOption: Identifiable, Hashable {
    /// “自动”选项固定标识。
    static let autoIdentifier = "auto"
    /// 选项唯一标识（这里直接使用播放地址或固定 auto id）。
    let id: String
    /// UI 展示名（如 1080p / 720p / 自动）。
    let name: String
    /// 对应播放地址。
    let url: String
    
    var isAuto: Bool {
        id == Self.autoIdentifier
    }
    
    static func auto(url: String) -> PlaybackQualityOption {
        PlaybackQualityOption(id: autoIdentifier, name: "自动", url: url)
    }
}

/// 详情页 ViewModel
@MainActor
class DetailViewModel: ObservableObject {
    /// 详情信息主体。
    @Published var vodInfo: VodInfo?
    /// 当前详情实际对应的视频条目；自动跨源后会更新为新来源条目。
    @Published var activeVideo: Movie.Video?
    /// 加载状态。
    @Published var isLoading = false
    /// 错误提示。
    @Published var errorMessage: String?
    /// 当前选中线路。
    @Published var selectedFlag: String = ""
    /// 当前选中剧集索引。
    @Published var selectedEpisodeIndex: Int = 0
    /// 是否处于播放态。
    @Published var isPlaying = false
    /// Bridge 播放地址解析状态。
    @Published var isResolvingBridgePlayback = false
    /// Bridge 播放解析或登录提示。
    @Published var bridgePlaybackMessage: String?
    /// 自动换源状态。
    @Published var isAutoSwitchingPlayback = false
    /// 自动换源提示。
    @Published var playbackFallbackMessage: String?
    /// 当前实际播放地址（可能是原始地址，也可能是清晰度切换后的子流地址）。
    @Published var playUrl: String?
    /// 播放器重载标识；同一 URL 需要重建播放器时递增。
    @Published private(set) var playbackReloadToken = UUID()
    /// 当前播放地址需要携带的 HTTP 请求头。
    @Published var playHeaders: [String: String] = [:]
    /// 当前完整播放条目；兼容 Android PlaySpec 的元数据承载。
    @Published private(set) var currentPlayback: PlayableItem?
    /// 续播起始位置（秒）。
    @Published var resumeSeconds: Double = 0
    /// 当前可选清晰度列表。
    @Published var qualityOptions: [PlaybackQualityOption] = []
    /// 当前选中的清晰度 id。
    @Published var selectedQualityId: String = PlaybackQualityOption.autoIdentifier
    /// Bridge 网盘 Token 输入请求。
    @Published var bridgeTokenPrompt: BridgeTokenPrompt?
    /// 是否展示 Bridge Token / 登录弹窗。
    @Published var isBridgeTokenPromptPresented = false
    /// Bridge Token 提交状态。
    @Published var isSubmittingBridgeToken = false
    /// Bridge Token 提交错误。
    @Published var bridgeTokenErrorMessage: String?
    /// 直接从播放解析返回的 Android Jar UI 快照。
    @Published var bridgeJarUiResponse: BridgeJarUiResponse?
    /// 是否展示播放路径的 Android Jar UI 桥接窗口。
    @Published var isBridgeJarUiPresented = false
    /// 播放路径 Android Jar UI 标题。
    @Published var bridgeJarUiTitle = "Android Jar 弹窗"
    /// 播放器高频回调进度，不直接绑定 UI，避免高频刷新引发性能问题。
    private var realtimeProgressSeconds: Double = 0
    
    /// 数据服务与网络服务。
    private let sourceService = SourceService.shared
    private let network = NetworkManager.shared
    /// 当前清晰度列表对应的基础剧集地址。
    private var qualityBaseEpisodeURL: String = ""
    /// 清晰度解析缓存，key 为原始剧集 URL。
    private var qualityOptionCache: [String: [PlaybackQualityOption]] = [:]
    /// 清晰度解析任务，用于取消旧请求。
    private var qualityResolveTask: Task<Void, Never>?
    /// 解析令牌，防止异步结果回写到过期状态。
    private var qualityResolveToken = UUID()
    private var currentSource: SourceBean?
    private var playbackResolveToken = UUID()
    private var pendingBridgePlayback: PendingBridgePlayback?
    private var bridgeMediaFallbackURL: String?
    private var isUsingBridgeMediaFallback = false
    private var bridgeCredentialAutoSubmitted: Set<String> = []
    private var failedPlaybackAttempts: Set<String> = []
    private var failedSiteVideoKeys: Set<String> = []
    private var autoRecoveryTask: Task<Void, Never>?
    private var playbackWatchdogTask: Task<Void, Never>?
    private var directPlaybackProbeTask: Task<Void, Never>?
    private var playbackWatchdogToken = UUID()
    private var playbackWatchdogBaseline: Double = 0
    private let playbackStartupTimeoutNanoseconds: UInt64 = 14_000_000_000
    private let bridgeDirectStartupTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let networkReconnectPlaybackMessage = "网络已切换，正在恢复播放..."
    private static let directPlaybackProbeTimeout: TimeInterval = 2.4
    
    /// 加载视频详情
    func loadDetail(video: Movie.Video) async {
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey)
                ?? ApiConfig.shared.homeSourceBean else { return }
        currentSource = source
        activeVideo = video
        resetAutomaticPlaybackRecovery(clearAttempts: true)
        
        isLoading = true
        errorMessage = nil
        
        do {
            let detail = try await sourceService.getDetail(sourceBean: source, vodId: video.id)
            if let info = playableDetail(detail) ?? fallbackDetail(from: video, source: source) {
                applyLoadedDetail(info, source: source, video: video)
                if !hasPlayableEpisodes(detail) {
                    errorMessage = "该来源详情接口没有返回播放列表，已使用搜索结果中的播放地址"
                }
            } else {
                clearLoadedDetail()
                errorMessage = "该来源没有返回可播放详情，请返回搜索页选择其它来源"
            }
        } catch {
            clearLoadedDetail()
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }

    private func playableDetail(_ info: VodInfo?) -> VodInfo? {
        guard let info, hasPlayableEpisodes(info) else { return nil }
        return info
    }

    private func hasPlayableEpisodes(_ info: VodInfo?) -> Bool {
        guard let info else { return false }
        return info.playUrlMap.values.contains { !$0.isEmpty }
    }

    private func fallbackDetail(from video: Movie.Video, source: SourceBean) -> VodInfo? {
        let rawPlayUrl = video.playUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPlayUrl.isEmpty else { return nil }

        var fallbackVideo = video
        fallbackVideo.sourceKey = source.key
        let playUrl = normalizedFallbackPlayUrl(rawPlayUrl)
        let playFrom = fallbackPlayFrom(video.dt, playUrl: playUrl)
        let info = VodInfo.from(video: fallbackVideo, playFrom: playFrom, playUrl: playUrl)
        return hasPlayableEpisodes(info) ? info : nil
    }

    private func normalizedFallbackPlayUrl(_ rawPlayUrl: String) -> String {
        rawPlayUrl.components(separatedBy: "$$$").map { group in
            let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedGroup.isEmpty else { return "" }
            let episodes = trimmedGroup.components(separatedBy: "#")
            return episodes.enumerated().map { index, episode in
                let trimmedEpisode = episode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedEpisode.isEmpty else { return "" }
                if trimmedEpisode.contains("$") { return trimmedEpisode }
                return "第\(index + 1)集$\(trimmedEpisode)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "#")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "$$$")
    }

    private func fallbackPlayFrom(_ rawPlayFrom: String, playUrl: String) -> String {
        let trimmedPlayFrom = rawPlayFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPlayFrom.isEmpty { return trimmedPlayFrom }
        let count = max(playUrl.components(separatedBy: "$$$").filter { !$0.isEmpty }.count, 1)
        if count == 1 { return "默认" }
        return (1...count).map { "线路\($0)" }.joined(separator: "$$$")
    }

    private func applyLoadedDetail(_ info: VodInfo, source: SourceBean, video: Movie.Video) {
        self.vodInfo = info
        self.currentSource = source
        self.activeVideo = video
        self.selectedFlag = info.playFlag
        self.selectedEpisodeIndex = info.playIndex
        self.resumeSeconds = 0
        self.realtimeProgressSeconds = 0
        self.isResolvingBridgePlayback = false
        self.bridgePlaybackMessage = nil
        self.bridgeTokenPrompt = nil
        self.isBridgeTokenPromptPresented = false
        self.isPlaying = false
        applyPlayback(nil)
        self.bridgeCredentialAutoSubmitted.removeAll()
        if source.requiresBridge {
            resetQualityState()
        } else if let episode = info.currentEpisode {
            updateQualityOptions(for: episode.url, resetSelection: true)
        } else {
            resetQualityState()
        }
    }

    private func clearLoadedDetail() {
        cancelPlaybackWatchdog()
        cancelDirectPlaybackProbe()
        vodInfo = nil
        selectedFlag = ""
        selectedEpisodeIndex = 0
        isResolvingBridgePlayback = false
        bridgePlaybackMessage = nil
        bridgeTokenPrompt = nil
        isBridgeTokenPromptPresented = false
        applyPlayback(nil)
        isPlaying = false
        resetQualityState()
    }
    
    /// 选择线路
    func selectFlag(_ flag: String) {
        guard selectedFlag != flag else { return }
        resetAutomaticPlaybackRecovery(clearAttempts: true)
        let currentIndex = selectedEpisodeIndex
        
        selectedFlag = flag
        vodInfo?.playFlag = flag
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        let episodes = vodInfo?.playUrlMap[flag] ?? []
        guard !episodes.isEmpty else {
            selectedEpisodeIndex = 0
            vodInfo?.playIndex = 0
            resetQualityState()
            return
        }
        
        let targetIndex = min(max(currentIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        let episodeURL = episodes[targetIndex].url
        if currentSource?.requiresBridge == true {
            resetQualityState()
        } else {
            updateQualityOptions(for: episodeURL, resetSelection: true)
        }
        
        // 播放中切线路时，立即切换到新线路对应剧集
        if isPlaying || isResolvingBridgePlayback {
            startPlayback(episodeURL: episodeURL, flag: selectedFlag)
        }
    }
    
    /// 选择剧集并播放
    func selectEpisode(index: Int) {
        guard selectedEpisodeIndex != index || !isPlaying || isResolvingBridgePlayback else { return }
        resetAutomaticPlaybackRecovery(clearAttempts: true)
        selectedEpisodeIndex = index
        vodInfo?.playIndex = index
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        detailPlaybackLogger.info("select episode index=\(index, privacy: .public) flag=\(self.selectedFlag, privacy: .public) source=\(self.currentSource?.key ?? "", privacy: .public) bridge=\(self.currentSource?.requiresBridge == true, privacy: .public)")
        
        if let episode = vodInfo?.currentEpisode {
            if currentSource?.requiresBridge == true {
                resetQualityState()
            } else {
                // 仅当剧集 URL 变化时重置清晰度选择。
                let shouldResetQuality = qualityBaseEpisodeURL != episode.url
                updateQualityOptions(for: episode.url, resetSelection: shouldResetQuality)
            }
            startPlayback(episodeURL: episode.url, flag: selectedFlag)
        }
    }
    
    /// 应用历史续播状态并自动继续播放
    func applyPlaybackState(_ state: VodPlaybackState) {
        guard let info = vodInfo, !info.playFlags.isEmpty else { return }
        
        let fallbackFlag = info.playFlag.isEmpty ? info.playFlags[0] : info.playFlag
        let targetFlag = info.playFlags.contains(state.flag) ? state.flag : fallbackFlag
        
        selectedFlag = targetFlag
        vodInfo?.playFlag = targetFlag
        
        let episodes = vodInfo?.playUrlMap[targetFlag] ?? []
        guard !episodes.isEmpty else { return }
        
        let targetIndex = min(max(state.episodeIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        
        let progress = max(0, state.progressSeconds)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        if let playbackRate = state.playbackRate, Self.isValidPlaybackRate(playbackRate) {
            UserDefaults.standard.set(playbackRate, forKey: HawkConfig.PLAY_SPEED)
        }
        if let rawScale = state.videoScaleRawValue {
            let scaleMode = VideoScaleMode.fromStoredValue(rawScale)
            UserDefaults.standard.set(scaleMode.rawValue, forKey: HawkConfig.PLAY_SCALE)
        }
        let episodeURL = episodes[targetIndex].url
        if currentSource?.requiresBridge == true {
            resetQualityState()
        } else {
            updateQualityOptions(for: episodeURL, resetSelection: true)
        }
        startPlayback(episodeURL: episodeURL, flag: selectedFlag)
    }

    private static func isValidPlaybackRate(_ value: Double) -> Bool {
        value.isFinite && value >= 0.25 && value <= 5
    }
    
    /// 选择清晰度
    func selectQuality(_ option: PlaybackQualityOption) {
        guard qualityOptions.contains(option) else { return }
        selectedQualityId = option.id
        guard isPlaying else { return }
        
        // “自动”使用基础剧集地址；其他选项使用对应变体地址。
        let targetURL = option.url.isEmpty ? qualityBaseEpisodeURL : option.url
        guard !targetURL.isEmpty, playUrl != targetURL else { return }
        
        let progress = max(currentPlaybackSeconds(), 0)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        let existingPlayback = currentPlayback
        let playback = existingPlayback?.replacingStream(
            url: targetURL,
            headers: existingPlayback?.headers ?? [:],
            origin: existingPlayback?.origin
        )
            ?? directPlayableItem(url: targetURL, episodeURL: qualityBaseEpisodeURL, flag: selectedFlag)
        advancePlaybackReloadToken()
        applyPlayback(playback)
    }
    
    /// 播放器时间回调
    func updatePlaybackProgress(seconds: Double) {
        guard seconds.isFinite else { return }
        let normalizedSeconds = max(seconds, 0)
        realtimeProgressSeconds = normalizedSeconds
        if normalizedSeconds - playbackWatchdogBaseline >= 1.0 || (playbackWatchdogBaseline < 1.0 && normalizedSeconds >= 1.0) {
            cancelPlaybackWatchdog()
            cancelDirectPlaybackProbe()
        }
    }

    /// 播放器已进入实际播放状态，避免慢进度/分段流被启动 watchdog 误判。
    func markPlaybackStarted() {
        cancelPlaybackWatchdog()
        cancelDirectPlaybackProbe()
        if playbackFallbackMessage == networkReconnectPlaybackMessage {
            playbackFallbackMessage = nil
        }
    }

    var isAwaitingNetworkPlaybackReconnect: Bool {
        playbackFallbackMessage == networkReconnectPlaybackMessage
    }
    
    /// 当前实时进度（不触发 UI 高频刷新）
    func currentPlaybackSeconds() -> Double {
        max(realtimeProgressSeconds, resumeSeconds)
    }
    
    /// 仅在必要时同步快照到可观察状态
    func commitPlaybackProgressSnapshot() {
        let snapshot = max(realtimeProgressSeconds, 0)
        if abs(snapshot - resumeSeconds) >= 1 {
            resumeSeconds = snapshot
        }
    }
    
    /// 播放下一集
    func playNext() -> Bool {
        guard let info = vodInfo else { return false }
        let episodes = info.currentEpisodes
        if selectedEpisodeIndex + 1 < episodes.count {
            selectEpisode(index: selectedEpisodeIndex + 1)
            return true
        }
        return false
    }
    
    /// 播放上一集
    func playPrevious() -> Bool {
        if selectedEpisodeIndex > 0 {
            selectEpisode(index: selectedEpisodeIndex - 1)
            return true
        }
        return false
    }

    /// 播放器报告失败、卡住或首帧超时后，按 FongMi 的思路自动尝试其它线路/站点。
    func handlePlaybackFailure(reason: String) {
        guard playUrl != nil || isResolvingBridgePlayback else { return }
        if startBridgeMediaFallbackIfPossible(trigger: reason) { return }
        startAutomaticPlaybackRecovery(trigger: reason)
    }

    /// 网络接口切换后，保留当前进度并重新打开当前剧集。
    func reconnectCurrentPlaybackAfterNetworkPathChange() {
        guard isPlaying,
              !isResolvingBridgePlayback,
              !isAutoSwitchingPlayback,
              let episode = vodInfo?.currentEpisode else {
            return
        }
        let progress = max(currentPlaybackSeconds(), 0)
        resumeSeconds = progress.isFinite && progress >= 3 ? progress : 0
        realtimeProgressSeconds = resumeSeconds
        playbackFallbackMessage = networkReconnectPlaybackMessage
        errorMessage = nil
        bridgePlaybackMessage = nil
        startPlayback(episodeURL: episode.url, flag: selectedFlag)
    }
    
    /// 当前剧集列表
    var currentEpisodes: [VodInfo.Episode] {
        vodInfo?.playUrlMap[selectedFlag] ?? []
    }
    
    /// 可选线路列表
    var flags: [String] {
        vodInfo?.playFlags ?? []
    }
    
    /// 是否存在可选清晰度
    var hasQualityChoices: Bool {
        qualityOptions.count > 1
    }
    
    private func selectedPlayableURL(fallback: String) -> String {
        // 若当前清晰度存在有效 URL，则优先使用；否则回退剧集原始地址。
        let selected = qualityOptions.first(where: { $0.id == selectedQualityId })?.url
        if let selected, !selected.isEmpty {
            return selected
        }
        return fallback
    }

    private func applyPlayback(_ playback: PlayableItem?) {
        currentPlayback = playback
        playUrl = playback?.url
        playHeaders = playback?.headers ?? [:]
    }

    private func applyBridgeStartPosition(_ startPosition: TimeInterval?) {
        guard let startPosition, startPosition.isFinite else { return }
        let normalizedSeconds = max(startPosition, 0)
        resumeSeconds = normalizedSeconds
        realtimeProgressSeconds = normalizedSeconds
    }

    private func applyBridgePlaybackMetadata(_ playback: BridgePlayback) {
        let artwork = playback.artwork?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let description = playback.descriptionText?.stripHTML.nilIfBlank
        guard artwork != nil || description != nil else { return }

        if var info = vodInfo {
            if let artwork { info.pic = artwork }
            if let description { info.des = description }
            vodInfo = info
        }

        if var video = activeVideo {
            if let artwork { video.pic = artwork }
            if let description { video.des = description }
            activeVideo = video
        }
    }

    private func applyBridgeQualityOptions(_ playback: BridgePlayback) {
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        qualityResolveToken = UUID()
        qualityBaseEpisodeURL = playback.url

        let options = playback.qualities.enumerated().compactMap { offset, quality -> PlaybackQualityOption? in
            let name = quality.name ?? "清晰度\(offset + 1)"
            return PlaybackQualityOption(
                id: "bridge-\(offset)-\(quality.url)",
                name: name,
                url: quality.url
            )
        }

        guard options.count > 1 else {
            qualityOptions = []
            selectedQualityId = PlaybackQualityOption.autoIdentifier
            return
        }

        qualityOptions = options
        selectedQualityId = options.first(where: { $0.url == playback.url })?.id ?? options[0].id
    }

    private func directPlayableItem(url: String, episodeURL: String, flag: String) -> PlayableItem {
        PlayableItem(
            url: url,
            sourceKey: currentSource?.key,
            flag: flag,
            episodeId: episodeURL,
            origin: .direct
        )
    }

    private func bridgePlayableItem(
        from playback: BridgePlayback,
        source: SourceBean,
        episodeURL: String,
        flag: String
    ) -> PlayableItem {
        PlayableItem(
            url: playback.url,
            headers: playback.headers,
            format: playback.format,
            parse: playback.parse,
            sourceKey: source.key,
            flag: playback.flag ?? flag,
            episodeId: episodeURL,
            fallbackURL: playback.fallbackURL,
            proxied: playback.proxied,
            jxFrom: playback.jxFrom,
            expiresAt: playback.expiresAt,
            subtitles: playback.subtitles.compactMap {
                PlayableSubtitle(url: $0.url, name: $0.name, lang: $0.lang, format: $0.format, flag: $0.flag)
            },
            danmakus: playback.danmakus.compactMap {
                PlayableDanmaku(name: $0.name, url: $0.url)
            },
            drm: playback.drm,
            origin: .bridge
        )
    }
    
    private func startPlayback(episodeURL: String, flag: String) {
        cancelPlaybackWatchdog()
        cancelDirectPlaybackProbe()
        bridgeMediaFallbackURL = nil
        isUsingBridgeMediaFallback = false
        guard let source = currentSource, source.requiresBridge else {
            playbackResolveToken = UUID()
            isResolvingBridgePlayback = false
            bridgePlaybackMessage = nil
            bridgeTokenPrompt = nil
            isBridgeTokenPromptPresented = false
            advancePlaybackReloadToken()
            applyPlayback(directPlayableItem(url: selectedPlayableURL(fallback: episodeURL), episodeURL: episodeURL, flag: flag))
            isPlaying = true
            schedulePlaybackWatchdog()
            return
        }
        let token = UUID()
        playbackResolveToken = token
        isPlaying = false
        isResolvingBridgePlayback = true
        bridgePlaybackMessage = "正在获取播放地址..."
        applyPlayback(nil)
        bridgeTokenPrompt = nil
        isBridgeTokenPromptPresented = false
        bridgeJarUiResponse = nil
        isBridgeJarUiPresented = false
        bridgeTokenErrorMessage = nil
        errorMessage = nil
        detailPlaybackLogger.info("bridge play start source=\(source.key, privacy: .public) flag=\(flag, privacy: .public)")
        Task { [source, episodeURL, flag, token] in
            do {
                let playback = try await BridgeClient.shared.play(source: source, flag: flag, id: episodeURL)
                guard playbackResolveToken == token else { return }
                detailPlaybackLogger.info("bridge play resolved source=\(source.key, privacy: .public) flag=\(flag, privacy: .public)")
                isResolvingBridgePlayback = false
                bridgePlaybackMessage = nil
                bridgeMediaFallbackURL = playback.fallbackURL
                isUsingBridgeMediaFallback = false
                applyBridgeStartPosition(playback.startPosition)
                applyBridgePlaybackMetadata(playback)
                applyBridgeQualityOptions(playback)
                advancePlaybackReloadToken()
                applyPlayback(bridgePlayableItem(from: playback, source: source, episodeURL: episodeURL, flag: flag))
                isPlaying = true
                scheduleDirectPlaybackProbeIfNeeded(url: playback.url, headers: playback.headers, fallbackURL: playback.fallbackURL, token: token)
                schedulePlaybackWatchdog()
                errorMessage = nil
            } catch {
                guard playbackResolveToken == token else { return }
                isResolvingBridgePlayback = false
                if case BridgeError.tokenRequired(let prompt) = error {
                    detailPlaybackLogger.info("bridge token required source=\(source.key, privacy: .public) provider=\(prompt.provider, privacy: .public)")
                    let credentialKey = "\(source.key)|\(prompt.provider)|\(flag)|\(episodeURL)"
                    if !bridgeCredentialAutoSubmitted.contains(credentialKey) {
                        bridgeCredentialAutoSubmitted.insert(credentialKey)
                        if await BridgeClient.shared.submitSavedTokenIfAvailable(source: source, prompt: prompt) {
                            bridgePlaybackMessage = "已同步本地保存的授权到 Android Bridge，正在重试..."
                            startPlayback(episodeURL: episodeURL, flag: flag)
                            return
                        }
                    }
                    pendingBridgePlayback = PendingBridgePlayback(source: source, episodeURL: episodeURL, flag: flag)
                    isPlaying = false
                    applyPlayback(nil)
                    bridgePlaybackMessage = prompt.message
                    bridgeTokenErrorMessage = nil
                    errorMessage = nil
                    bridgeTokenPrompt = prompt
                    isBridgeTokenPromptPresented = true
                    return
                }
                if case BridgeError.jarUiRequired(let response) = error {
                    detailPlaybackLogger.info("bridge jar ui required source=\(source.key, privacy: .public) flag=\(flag, privacy: .public)")
                    pendingBridgePlayback = PendingBridgePlayback(source: source, episodeURL: episodeURL, flag: flag)
                    isPlaying = false
                    applyPlayback(nil)
                    bridgePlaybackMessage = response.message ?? "请在 macOS 上操作 Android Jar 弹窗"
                    bridgeTokenErrorMessage = nil
                    errorMessage = nil
                    bridgeTokenPrompt = nil
                    isBridgeTokenPromptPresented = false
                    bridgeJarUiTitle = "Android Jar 弹窗"
                    bridgeJarUiResponse = response
                    isBridgeJarUiPresented = true
                    return
                }
                detailPlaybackLogger.error("bridge play failed source=\(source.key, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                bridgePlaybackMessage = nil
                startAutomaticPlaybackRecovery(trigger: error.localizedDescription)
            }
        }
    }

    func presentBridgeTokenPrompt() {
        guard bridgeTokenPrompt != nil else { return }
        isBridgeTokenPromptPresented = true
    }

    func dismissBridgeTokenPromptPresentation() {
        isBridgeTokenPromptPresented = false
    }

    func cancelBridgeTokenPrompt() {
        bridgeTokenPrompt = nil
        isBridgeTokenPromptPresented = false
        bridgeTokenErrorMessage = nil
        bridgePlaybackMessage = nil
        isSubmittingBridgeToken = false
    }

    func submitBridgeToken(values: [String: String]) async {
        guard let prompt = bridgeTokenPrompt, let pending = pendingBridgePlayback else { return }
        isSubmittingBridgeToken = true
        bridgeTokenErrorMessage = nil
        do {
            try await BridgeClient.shared.submitToken(source: pending.source, prompt: prompt, values: values)
            isSubmittingBridgeToken = false
            bridgeTokenPrompt = nil
            isBridgeTokenPromptPresented = false
            bridgeTokenErrorMessage = nil
            bridgePlaybackMessage = nil
            let retryEpisodeURL = prompt.retry?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let retryFlag = prompt.retry?.flag?.trimmingCharacters(in: .whitespacesAndNewlines)
            startPlayback(
                episodeURL: retryEpisodeURL?.isEmpty == false ? retryEpisodeURL! : pending.episodeURL,
                flag: retryFlag?.isEmpty == false ? retryFlag! : pending.flag
            )
        } catch {
            isSubmittingBridgeToken = false
            bridgeTokenErrorMessage = error.localizedDescription
        }
    }

    func openBridgeJarUi(prompt: BridgeTokenPrompt) async throws -> BridgeJarUiResponse {
        guard let pending = pendingBridgePlayback else { throw BridgeError.notConfigured }
        return try await BridgeClient.shared.openJarUi(source: pending.source, prompt: prompt)
    }

    func pollBridgeJarUi() async throws -> BridgeJarUiStatusResponse {
        guard let pending = pendingBridgePlayback, let prompt = bridgeTokenPrompt else { throw BridgeError.notConfigured }
        return try await BridgeClient.shared.jarUiStatus(source: pending.source, prompt: prompt)
    }

    func closeBridgeJarUi() async {
        guard let pending = pendingBridgePlayback, let prompt = bridgeTokenPrompt else { return }
        do {
            try await BridgeClient.shared.closeJarUi(source: pending.source, prompt: prompt)
        } catch {
            bridgeTokenErrorMessage = error.localizedDescription
            return
        }
        bridgeTokenPrompt = nil
        isBridgeTokenPromptPresented = false
        bridgeTokenErrorMessage = nil
        bridgePlaybackMessage = nil
        startPlayback(episodeURL: pending.episodeURL, flag: pending.flag)
    }

    func sendBridgeJarUiAction(_ action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        guard let pending = pendingBridgePlayback, let prompt = bridgeTokenPrompt else { throw BridgeError.notConfigured }
        return try await BridgeClient.shared.jarUiAction(source: pending.source, prompt: prompt, action: action)
    }

    func pollPlaybackBridgeJarUi() async throws -> BridgeJarUiStatusResponse {
        guard let pending = pendingBridgePlayback else { throw BridgeError.notConfigured }
        return try await BridgeClient.shared.jarUiStatus(source: pending.source)
    }

    func sendPlaybackBridgeJarUiAction(_ action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        guard let pending = pendingBridgePlayback else { throw BridgeError.notConfigured }
        return try await BridgeClient.shared.jarUiAction(source: pending.source, action: action)
    }

    func cancelPlaybackBridgeJarUi() {
        Task { await closePlaybackBridgeJarUi(retryPlayback: false) }
    }

    func dismissPlaybackBridgeJarUiPresentation() {
        bridgeJarUiResponse = nil
        isBridgeJarUiPresented = false
    }

    func closePlaybackBridgeJarUi(retryPlayback: Bool = true) async {
        guard let pending = pendingBridgePlayback else {
            dismissPlaybackBridgeJarUiPresentation()
            return
        }
        do {
            try await BridgeClient.shared.closeJarUi(source: pending.source)
        } catch {
            bridgeTokenErrorMessage = error.localizedDescription
        }
        bridgeJarUiResponse = nil
        isBridgeJarUiPresented = false
        bridgePlaybackMessage = nil
        if retryPlayback {
            startPlayback(episodeURL: pending.episodeURL, flag: pending.flag)
        }
    }

    private func startBridgeMediaFallbackIfPossible(trigger: String) -> Bool {
        guard currentSource?.requiresBridge == true else { return false }
        guard !isUsingBridgeMediaFallback else { return false }
        guard let fallbackURL = bridgeMediaFallbackURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallbackURL.isEmpty,
              playUrl != fallbackURL else {
            return false
        }

        detailPlaybackLogger.info("bridge media fallback start trigger=\(trigger, privacy: .public)")
        cancelPlaybackWatchdog()
        cancelDirectPlaybackProbe()
        isUsingBridgeMediaFallback = true
        let fallbackPlayback = currentPlayback?.replacingStream(url: fallbackURL, headers: [:], origin: .bridgeFallback)
            ?? PlayableItem(
                url: fallbackURL,
                sourceKey: currentSource?.key,
                flag: selectedFlag,
                episodeId: vodInfo?.currentEpisode?.url,
                origin: .bridgeFallback
            )
        advancePlaybackReloadToken()
        applyPlayback(fallbackPlayback)
        isPlaying = true
        bridgePlaybackMessage = nil
        playbackFallbackMessage = "直连播放异常，已切换到 Bridge 代理兜底"
        resumeSeconds = currentPlaybackSeconds() >= 5 ? currentPlaybackSeconds() : 0
        schedulePlaybackWatchdog()
        return true
    }

    private func startAutomaticPlaybackRecovery(trigger: String) {
        guard currentSource?.isChangeable == true else {
            cancelPlaybackWatchdog()
            isAutoSwitchingPlayback = false
            playbackFallbackMessage = nil
            isPlaying = false
            errorMessage = "播放失败：\(trigger)"
            return
        }
        guard autoRecoveryTask == nil else { return }
        markCurrentPlaybackAttemptFailed()
        cancelPlaybackWatchdog()
        isAutoSwitchingPlayback = true
        playbackFallbackMessage = "播放异常，正在尝试其它线路..."
        errorMessage = nil
        bridgePlaybackMessage = nil
        isResolvingBridgePlayback = false
        isPlaying = false
        applyPlayback(nil)

        autoRecoveryTask = Task { [trigger] in
            await self.performAutomaticPlaybackRecovery(trigger: trigger)
        }
    }

    private func performAutomaticPlaybackRecovery(trigger: String) async {
        guard !Task.isCancelled else {
            autoRecoveryTask = nil
            isAutoSwitchingPlayback = false
            return
        }
        if switchToNextFlag(trigger: trigger) {
            autoRecoveryTask = nil
            isAutoSwitchingPlayback = false
            return
        }

        guard !Task.isCancelled else {
            autoRecoveryTask = nil
            isAutoSwitchingPlayback = false
            return
        }
        if await switchToNextSite(trigger: trigger) {
            autoRecoveryTask = nil
            isAutoSwitchingPlayback = false
            return
        }

        autoRecoveryTask = nil
        isAutoSwitchingPlayback = false
        playbackFallbackMessage = nil
        errorMessage = "当前播放源不可用，已尝试其它线路和可搜索站点"
    }

    private func switchToNextFlag(trigger: String) -> Bool {
        guard let info = vodInfo, let source = currentSource else { return false }
        guard !info.playFlags.isEmpty else { return false }
        let currentFlagIndex = info.playFlags.firstIndex(of: selectedFlag) ?? -1
        let startIndex = max(currentFlagIndex + 1, 0)
        guard startIndex < info.playFlags.count else { return false }

        for flagIndex in startIndex..<info.playFlags.count {
            let flag = info.playFlags[flagIndex]
            let episodes = info.playUrlMap[flag] ?? []
            guard !episodes.isEmpty else { continue }
            let targetEpisodeIndex = min(max(selectedEpisodeIndex, 0), episodes.count - 1)
            let episodeURL = episodes[targetEpisodeIndex].url
            let key = playbackAttemptKey(
                sourceKey: source.key,
                vodId: info.id,
                flag: flag,
                episodeIndex: targetEpisodeIndex,
                url: episodeURL
            )
            guard !failedPlaybackAttempts.contains(key) else { continue }

            let progress = max(currentPlaybackSeconds(), 0)
            selectedFlag = flag
            selectedEpisodeIndex = targetEpisodeIndex
            vodInfo?.playFlag = flag
            vodInfo?.playIndex = targetEpisodeIndex
            resumeSeconds = progress >= 5 ? progress : 0
            realtimeProgressSeconds = resumeSeconds
            if currentSource?.requiresBridge == true {
                resetQualityState()
            } else {
                updateQualityOptions(for: episodeURL, resetSelection: true)
            }
            playbackFallbackMessage = "播放异常，已自动切换到线路 \(flag)"
            detailPlaybackLogger.info("auto switch flag source=\(source.key, privacy: .public) flag=\(flag, privacy: .public) trigger=\(trigger, privacy: .public)")
            startPlayback(episodeURL: episodeURL, flag: flag)
            return true
        }

        return false
    }

    private func switchToNextSite(trigger: String) async -> Bool {
        guard let info = vodInfo else { return false }
        let keyword = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return false }
        playbackFallbackMessage = "线路不可用，正在搜索其它站点..."

        let targetName = Self.normalizedAutoMatchText(keyword)
        guard !targetName.isEmpty else { return false }
        let groups = await sourceService.searchGroups(keyword: keyword)
        guard !Task.isCancelled else { return false }

        for group in groups where group.source.isChangeable && group.source.isAvailableForPlayback {
            for candidate in group.videos {
                let candidateName = Self.normalizedAutoMatchText(candidate.name)
                guard candidateName == targetName else { continue }
                let siteVideoKey = playbackSiteVideoKey(sourceKey: group.source.key, vodId: candidate.id)
                guard !failedSiteVideoKeys.contains(siteVideoKey) else { continue }

                var video = candidate
                video.sourceKey = group.source.key
                do {
                    guard var detail = try await sourceService.getDetail(sourceBean: group.source, vodId: video.id) else {
                        failedSiteVideoKeys.insert(siteVideoKey)
                        continue
                    }
                    guard applyAutomaticSiteCandidate(video: video, source: group.source, detail: &detail, trigger: trigger) else {
                        failedSiteVideoKeys.insert(siteVideoKey)
                        continue
                    }
                    return true
                } catch {
                    failedSiteVideoKeys.insert(siteVideoKey)
                    continue
                }
            }
        }

        return false
    }

    private func applyAutomaticSiteCandidate(video: Movie.Video, source: SourceBean, detail: inout VodInfo, trigger: String) -> Bool {
        guard !detail.playFlags.isEmpty else { return false }
        let previousIndex = selectedEpisodeIndex
        let previousEpisodeName = vodInfo?.currentEpisode?.name ?? ""
        let targetFlag = detail.playFlags.contains(selectedFlag) ? selectedFlag : (detail.playFlag.isEmpty ? detail.playFlags[0] : detail.playFlag)
        let episodes = detail.playUrlMap[targetFlag] ?? []
        guard !episodes.isEmpty else { return false }

        let matchedIndex = episodes.firstIndex {
            Self.normalizedAutoMatchText($0.name) == Self.normalizedAutoMatchText(previousEpisodeName)
        }
        let targetEpisodeIndex = matchedIndex ?? min(max(previousIndex, 0), episodes.count - 1)
        let episodeURL = episodes[targetEpisodeIndex].url
        let candidateKey = playbackAttemptKey(
            sourceKey: source.key,
            vodId: detail.id,
            flag: targetFlag,
            episodeIndex: targetEpisodeIndex,
            url: episodeURL
        )
        guard !failedPlaybackAttempts.contains(candidateKey) else { return false }

        currentSource = source
        activeVideo = video
        detail.playFlag = targetFlag
        detail.playIndex = targetEpisodeIndex
        vodInfo = detail
        selectedFlag = targetFlag
        selectedEpisodeIndex = targetEpisodeIndex
        bridgeCredentialAutoSubmitted.removeAll()
        pendingBridgePlayback = nil
        bridgeTokenPrompt = nil
        isBridgeTokenPromptPresented = false
        bridgeJarUiResponse = nil
        isBridgeJarUiPresented = false
        resumeSeconds = currentPlaybackSeconds() >= 5 ? currentPlaybackSeconds() : 0
        realtimeProgressSeconds = resumeSeconds
        if source.requiresBridge {
            resetQualityState()
        } else {
            updateQualityOptions(for: episodeURL, resetSelection: true)
        }
        let detailId = detail.id
        playbackFallbackMessage = "播放异常，已自动切换到 \(source.name)"
        detailPlaybackLogger.info("auto switch site source=\(source.key, privacy: .public) vod=\(detailId, privacy: .public) trigger=\(trigger, privacy: .public)")
        startPlayback(episodeURL: episodeURL, flag: targetFlag)
        return true
    }

    private func markCurrentPlaybackAttemptFailed() {
        guard let info = vodInfo, let source = currentSource else { return }
        let currentURL = playUrl ?? info.currentEpisode?.url ?? ""
        failedPlaybackAttempts.insert(playbackAttemptKey(
            sourceKey: source.key,
            vodId: info.id,
            flag: selectedFlag,
            episodeIndex: selectedEpisodeIndex,
            url: currentURL
        ))
        failedSiteVideoKeys.insert(playbackSiteVideoKey(sourceKey: source.key, vodId: info.id))
    }

    private func resetAutomaticPlaybackRecovery(clearAttempts: Bool) {
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        cancelPlaybackWatchdog()
        cancelDirectPlaybackProbe()
        isAutoSwitchingPlayback = false
        playbackFallbackMessage = nil
        if clearAttempts {
            failedPlaybackAttempts.removeAll()
            failedSiteVideoKeys.removeAll()
        }
    }

    private func advancePlaybackReloadToken() {
        playbackReloadToken = UUID()
    }

    private func schedulePlaybackWatchdog() {
        cancelPlaybackWatchdog()
        guard isPlaying, let currentURL = playUrl, !currentURL.isEmpty else { return }
        let token = UUID()
        playbackWatchdogToken = token
        playbackWatchdogBaseline = currentPlaybackSeconds()
        let baseline = playbackWatchdogBaseline
        let timeout = shouldFastFallbackCurrentPlayback ? bridgeDirectStartupTimeoutNanoseconds : playbackStartupTimeoutNanoseconds
        playbackWatchdogTask = Task { [token, currentURL, baseline, timeout] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.playbackWatchdogToken == token,
                      self.isPlaying,
                      self.playUrl == currentURL else { return }
                let advanced = self.currentPlaybackSeconds() - baseline
                if advanced < 1.0 {
                    self.handlePlaybackFailure(reason: "播放启动超时")
                }
            }
        }
    }

    private func cancelPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
        playbackWatchdogToken = UUID()
    }

    private var shouldFastFallbackCurrentPlayback: Bool {
        currentSource?.requiresBridge == true
            && !isUsingBridgeMediaFallback
            && bridgeMediaFallbackURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func scheduleDirectPlaybackProbeIfNeeded(url: String, headers: [String: String], fallbackURL: String?, token: UUID) {
        cancelDirectPlaybackProbe()
        guard currentSource?.requiresBridge == true else { return }
        guard fallbackURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        guard let parsedURL = URL(string: url), ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "") else { return }
        guard !BridgeServerEndpoint.isBridgeProxyURL(parsedURL) else { return }

        directPlaybackProbeTask = Task { [url, headers, token] in
            let reachable = await Self.canReachDirectPlaybackURL(url, headers: headers)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.playbackResolveToken == token,
                      self.isPlaying,
                      self.playUrl == url,
                      !self.isUsingBridgeMediaFallback,
                      self.currentPlaybackSeconds() < 1 else { return }
                if !reachable {
                    _ = self.startBridgeMediaFallbackIfPossible(trigger: "直连探测失败")
                }
            }
        }
    }

    private func cancelDirectPlaybackProbe() {
        directPlaybackProbeTask?.cancel()
        directPlaybackProbeTask = nil
    }

    private static func canReachDirectPlaybackURL(_ urlString: String, headers: [String: String]) async -> Bool {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = directPlaybackProbeTimeout
        configuration.timeoutIntervalForResource = directPlaybackProbeTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: directPlaybackProbeTimeout)
        request.httpMethod = "GET"
        for (key, value) in PlaybackHTTPHeaders.normalizedForPlayback(headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !looksLikeHLSURL(url) {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return true }
            if (200..<400).contains(http.statusCode) { return true }
            if [405, 416, 501].contains(http.statusCode) { return true }
            return false
        } catch {
            return false
        }
    }

    private func playbackAttemptKey(sourceKey: String, vodId: String, flag: String, episodeIndex: Int, url: String) -> String {
        [
            sourceKey,
            vodId,
            flag,
            String(episodeIndex),
            url.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
    }

    private func playbackSiteVideoKey(sourceKey: String, vodId: String) -> String {
        "\(sourceKey)|\(vodId)"
    }

    private static func normalizedAutoMatchText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
    
    /// 重置清晰度解析与选择状态。
    private func resetQualityState() {
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        qualityBaseEpisodeURL = ""
        qualityOptions = []
        selectedQualityId = PlaybackQualityOption.autoIdentifier
        qualityResolveToken = UUID()
    }
    
    private func updateQualityOptions(for episodeURL: String, resetSelection: Bool) {
        let trimmedEpisodeURL = episodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEpisodeURL.isEmpty else {
            resetQualityState()
            return
        }
        
        // 切换剧集时先取消旧任务，避免异步回写错位。
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        
        let autoOption = PlaybackQualityOption.auto(url: trimmedEpisodeURL)
        let previousSelected = selectedQualityId
        
        qualityBaseEpisodeURL = trimmedEpisodeURL
        if resetSelection {
            selectedQualityId = PlaybackQualityOption.autoIdentifier
        }
        
        qualityOptions = [autoOption]
        
        if let cached = qualityOptionCache[trimmedEpisodeURL] {
            // 缓存命中时直接复用，避免重复网络解析。
            qualityOptions = cached
            if resetSelection || !cached.contains(where: { $0.id == selectedQualityId }) {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if previousSelected != selectedQualityId && cached.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            }
            return
        }
        
        let token = UUID()
        qualityResolveToken = token
        qualityResolveTask = Task { [trimmedEpisodeURL, resetSelection, previousSelected] in
            let resolved = await resolveQualityOptions(for: trimmedEpisodeURL)
            guard !Task.isCancelled else { return }
            guard qualityResolveToken == token, qualityBaseEpisodeURL == trimmedEpisodeURL else { return }
            guard !resolved.isEmpty else { return }
            
            qualityOptionCache[trimmedEpisodeURL] = resolved
            qualityOptions = resolved
            
            if resetSelection {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if resolved.contains(where: { $0.id == selectedQualityId }) {
                // 当前选择仍有效，保持不变
            } else if resolved.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            } else {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            }
        }
    }
    
    /// 尝试从 HLS 主播放列表解析多清晰度选项。
    private func resolveQualityOptions(for episodeURL: String) async -> [PlaybackQualityOption] {
        guard let url = URL(string: episodeURL), Self.looksLikeHLSURL(url) else { return [] }
        guard let playlist = try? await network.getString(from: episodeURL) else { return [] }
        return Self.parseMasterPlaylist(playlist, masterURL: url)
    }
    
    /// HLS 变体流中间模型。
    private struct HLSVariant {
        let url: String
        let name: String?
        let height: Int?
        let bandwidth: Int?
    }
    
    /// 轻量判断 URL 是否可能是 HLS 播放列表。
    private static func looksLikeHLSURL(_ url: URL) -> Bool {
        let lowercased = url.absoluteString.lowercased()
        if lowercased.contains(".m3u8") { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }
    
    /// 解析 HLS 主播放列表并生成清晰度选项。
    /// 仅当解析出 2 个及以上有效变体时才返回（否则不显示清晰度切换）。
    private static func parseMasterPlaylist(_ content: String, masterURL: URL) -> [PlaybackQualityOption] {
        guard content.localizedCaseInsensitiveContains("#EXT-X-STREAM-INF") else { return [] }
        
        let lines = content.components(separatedBy: .newlines)
        var variants: [HLSVariant] = []
        var index = 0
        
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            
            let attributeString = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let attributes = parseAttributeMap(attributeString)
            
            var uri: String?
            var nextIndex = index + 1
            while nextIndex < lines.count {
                let candidate = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty {
                    nextIndex += 1
                    continue
                }
                if candidate.hasPrefix("#") {
                    nextIndex += 1
                    continue
                }
                uri = candidate
                break
            }
            
            if let uri, !uri.isEmpty {
                let resolvedURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL.absoluteString ?? uri
                let name = attributes["NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init)
                let height: Int?
                if let resolution = attributes["RESOLUTION"] {
                    let parts = resolution.split(separator: "x")
                    if parts.count == 2 {
                        height = Int(parts[1])
                    } else {
                        height = nil
                    }
                } else {
                    height = nil
                }
                
                variants.append(HLSVariant(
                    url: resolvedURL,
                    name: name?.isEmpty == true ? nil : name,
                    height: height,
                    bandwidth: bandwidth
                ))
            }
            
            index = nextIndex + 1
        }
        
        guard !variants.isEmpty else { return [] }
        
        var seenURLs = Set<String>()
        let deduped = variants.filter { variant in
            let inserted = seenURLs.insert(variant.url).inserted
            return inserted
        }
        
        let sorted = deduped.sorted { lhs, rhs in
            let lhsHeight = lhs.height ?? -1
            let rhsHeight = rhs.height ?? -1
            if lhsHeight != rhsHeight {
                return lhsHeight > rhsHeight
            }
            let lhsBandwidth = lhs.bandwidth ?? -1
            let rhsBandwidth = rhs.bandwidth ?? -1
            if lhsBandwidth != rhsBandwidth {
                return lhsBandwidth > rhsBandwidth
            }
            return lhs.url < rhs.url
        }
        
        let masterURLString = masterURL.absoluteString
        var displayNameCount: [String: Int] = [:]
        let options = sorted.enumerated().map { offset, variant -> PlaybackQualityOption in
            let baseName: String
            if let name = variant.name, !name.isEmpty {
                baseName = name
            } else if let height = variant.height {
                baseName = "\(height)p"
            } else if let bandwidth = variant.bandwidth, bandwidth > 0 {
                baseName = "\(bandwidth / 1000)K"
            } else {
                baseName = "清晰度\(offset + 1)"
            }
            
            let newCount = (displayNameCount[baseName] ?? 0) + 1
            displayNameCount[baseName] = newCount
            let finalName = newCount > 1 ? "\(baseName) \(newCount)" : baseName
            
            return PlaybackQualityOption(id: variant.url, name: finalName, url: variant.url)
        }.filter { !$0.url.isEmpty && $0.url != masterURLString }
        
        guard options.count >= 2 else { return [] }
        
        var merged = [PlaybackQualityOption.auto(url: masterURLString)]
        merged.append(contentsOf: options)
        return merged
    }
    
    /// 解析 `EXT-X-STREAM-INF` 的属性串为键值字典。
    private static func parseAttributeMap(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = splitAttributes(raw)
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
    
    /// 按逗号分隔属性，但保留引号内逗号。
    private static func splitAttributes(_ raw: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var inQuotes = false
        
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
                buffer.append(char)
                continue
            }
            
            if char == "," && !inQuotes {
                let item = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty {
                    parts.append(item)
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            
            buffer.append(char)
        }
        
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }

    private struct PendingBridgePlayback {
        let source: SourceBean
        let episodeURL: String
        let flag: String
    }
}
