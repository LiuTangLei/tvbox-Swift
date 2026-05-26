import SwiftUI
import AVKit
import CoreMedia
import Darwin

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SubtitleAppearance: Equatable {
    static let defaultTextScale = 100
    static let defaultVerticalOffset = 0
    static let textScaleStep = 10
    static let verticalOffsetStep = 12
    static let minTextScale = 70
    static let maxTextScale = 180
    static let minVerticalOffset = -40
    static let maxVerticalOffset = 240

    var textScale: Int
    var verticalOffset: Int

    static func load() -> SubtitleAppearance {
        let defaults = UserDefaults.standard
        let scale = defaults.object(forKey: HawkConfig.SUBTITLE_TEXT_SIZE) as? Int ?? defaultTextScale
        let offset = defaults.object(forKey: HawkConfig.SUBTITLE_POSITION) as? Int ?? defaultVerticalOffset
        return SubtitleAppearance(textScale: clamp(scale, minTextScale, maxTextScale), verticalOffset: clamp(offset, minVerticalOffset, maxVerticalOffset))
    }

    func save() {
        UserDefaults.standard.set(textScale, forKey: HawkConfig.SUBTITLE_TEXT_SIZE)
        UserDefaults.standard.set(verticalOffset, forKey: HawkConfig.SUBTITLE_POSITION)
    }

    func resized(by delta: Int) -> SubtitleAppearance {
        SubtitleAppearance(textScale: Self.clamp(textScale + delta, Self.minTextScale, Self.maxTextScale), verticalOffset: verticalOffset)
    }

    func moved(by delta: Int) -> SubtitleAppearance {
        SubtitleAppearance(textScale: textScale, verticalOffset: Self.clamp(verticalOffset + delta, Self.minVerticalOffset, Self.maxVerticalOffset))
    }

    static var defaults: SubtitleAppearance {
        SubtitleAppearance(textScale: defaultTextScale, verticalOffset: defaultVerticalOffset)
    }

    var vlcRelativeFontSize: Int {
        // libVLC stores the relative subtitle size as a divisor: lower values render larger text.
        Self.clamp(Int((1600.0 / Double(textScale)).rounded()), 6, 24)
    }

    var vlcSubtitleMargin: Int {
        verticalOffset
    }

    var avLinePosition: Double {
        min(95, max(15, 90 - Double(verticalOffset) / 4.0))
    }

    var avTextStyleRules: [AVTextStyleRule] {
        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: NSNumber(value: textScale),
            kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String: NSNumber(value: avLinePosition)
        ]
        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else { return [] }
        return [rule]
    }

    var positionLabel: String {
        if verticalOffset == 0 { return "默认" }
        return verticalOffset > 0 ? "上移 \(verticalOffset)" : "下移 \(abs(verticalOffset))"
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(upper, max(lower, value))
    }
}

/// 跨平台播放器：macOS 使用 AVPlayerView，避免 SwiftUI.VideoPlayer 在 macOS 的崩溃问题
struct PlatformVideoPlayer: View {
    let player: AVPlayer

    var body: some View {
        #if os(macOS)
        MacOSPlayerView(player: player)
        #else
        VideoPlayer(player: player)
        #endif
    }
}

#if os(macOS)
private struct MacOSPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.layer?.backgroundColor = NSColor.black.cgColor
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
#endif

/// 系统播放器会话控制器：用于在页面内联与全屏视图间复用同一 AVPlayer，避免重复拉流
@MainActor
final class SystemPlayerSessionController: ObservableObject {
    fileprivate var player: AVPlayer?
    fileprivate var mediaURLString: String?

    func setPlayer(_ newPlayer: AVPlayer, urlString: String) {
        if let previousPlayer = player, previousPlayer !== newPlayer {
            previousPlayer.pause()
            DispatchQueue.global(qos: .utility).async {
                previousPlayer.replaceCurrentItem(with: nil)
            }
        }
        player = newPlayer
        mediaURLString = urlString
    }

    func stop() {
        let stoppingPlayer = player
        player?.pause()
        player = nil
        mediaURLString = nil
        // AVPlayer.replaceCurrentItem(with: nil) 在播放网络流时会同步阻塞主线程数秒。
        // 将其移到后台执行，闭包持有 AVPlayer 强引用防止提前 dealloc。
        if let stoppingPlayer {
            DispatchQueue.global(qos: .utility).async {
                stoppingPlayer.replaceCurrentItem(with: nil)
            }
        }
    }
}

/// 视频播放器组件 - 对应 Android 版 PlayFragment
struct PlayerView: View {
    let urlString: String
    var httpHeaders: [String: String] = [:]
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var onVideoOrientationChanged: ((Bool?) -> Void)? = nil
    var onVideoSizeChanged: ((CGSize) -> Void)? = nil
    var isFullscreen: Bool = false
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    @AppStorage(HawkConfig.PLAY_TYPE_VOD) private var vodPlayTypeRaw = -1
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue

    private var selectedEngine: PlayerEngine {
        if shouldUseVLCForBridgeProxy {
            return .vlc
        }
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) != nil {
            rawValue = vodPlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.defaultVodEngine.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }

    private var shouldUseVLCForBridgeProxy: Bool {
        guard PlayerEngine.isVLCAvailable, let url = URL(string: urlString) else { return false }
        return BridgeServerEndpoint.isBridgeProxyURL(url)
    }

    var body: some View {
        Group {
            switch selectedEngine {
            case .system:
                AVPlayerContentView(
                    urlString: urlString,
                    httpHeaders: httpHeaders,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackStarted: onPlaybackStarted,
                    onPlaybackEnded: onPlaybackEnded,
                    onPlaybackFailed: onPlaybackFailed,
                    onToggleFullScreen: onToggleFullScreen,
                    onVideoOrientationChanged: onVideoOrientationChanged,
                    onVideoSizeChanged: onVideoSizeChanged,
                    isFullscreen: isFullscreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: systemController
                )
            case .vlc:
                VLCVodPlayerView(
                    urlString: urlString,
                    httpHeaders: httpHeaders,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackStarted: onPlaybackStarted,
                    onPlaybackEnded: onPlaybackEnded,
                    onPlaybackFailed: onPlaybackFailed,
                    onToggleFullScreen: onToggleFullScreen,
                    onVideoOrientationChanged: onVideoOrientationChanged,
                    onVideoSizeChanged: onVideoSizeChanged,
                    isFullscreen: isFullscreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: vlcController
                )
            }
        }
        .id(selectedEngine.rawValue)
        .onAppear {
            if selectedEngine != .system {
                systemController?.stop()
            }
            if selectedEngine != .vlc {
                vlcController?.stop()
            }
        }
        .onChange(of: selectedEngine) { _, newValue in
            if newValue != .system {
                systemController?.stop()
            }
            if newValue != .vlc {
                vlcController?.stop()
            }
        }
    }
}

/// 基于系统 AVPlayer 的点播播放器实现
struct AVPlayerContentView: View {
    private enum TrackSelectionSheetKind: String, Identifiable {
        case audio
        case subtitle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audio: return "音轨"
            case .subtitle: return "字幕"
            }
        }
    }

    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let urlString: String
    var httpHeaders: [String: String] = [:]
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var onVideoOrientationChanged: ((Bool?) -> Void)? = nil
    var onVideoSizeChanged: ((CGSize) -> Void)? = nil
    var isFullscreen: Bool = false
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: SystemPlayerSessionController? = nil
    @AppStorage(HawkConfig.PLAY_SPEED) private var savedPlaybackRate = 1.0
    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var playbackFailedObserver: NSObjectProtocol?
    @State private var playbackStalledObserver: NSObjectProtocol?
    @State private var timeObserverToken: Any?

    // UI 状态
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Double = 1.0
    @State private var rate: Float = 1.0
    @State private var isPreparing = true
    @State private var playbackError: String?
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    @State private var playerObservers: [NSKeyValueObservation] = []
    @State private var audioTracks: [MediaTrackOption] = []
    @State private var subtitleTracks: [MediaTrackOption] = []
    @State private var selectedAudioTrackID: String?
    @State private var selectedSubtitleTrackID: String?
    @State private var subtitleAppearance = SubtitleAppearance.load()
    @State private var audioSelectionOptions: [String: AVMediaSelectionOption] = [:]
    @State private var subtitleSelectionOptions: [String: AVMediaSelectionOption] = [:]
    @State private var audioItemTracks: [String: AVPlayerItemTrack] = [:]
    @State private var trackSelectionSheetKind: TrackSelectionSheetKind?
    @State private var hasReportedPlaybackFailure = false
    @State private var stalledRecoveryWorkItem: DispatchWorkItem?

    @State private var videoZoomScale: CGFloat = 1.0
    @State private var lastReportedVideoOrientation: Bool?
    @State private var lastReportedVideoSize: CGSize = .zero

    var body: some View {
        ZStack {
            Group {
                if let player = player {
                    PlatformVideoPlayer(player: player)
                        #if os(iOS)
                        .scaleEffect(videoZoomScale)
                        #endif
                } else {
                    Color.black
                }
            }
            #if !os(iOS)
            .onTapGesture(count: 2) {
                onToggleFullScreen?()
            }
            .onTapGesture(count: 1) {
                togglePlayPauseWithOSD()
            }
            #endif

            if player == nil || isPreparing {
                LoadingSpeedOverlay()
            }

            if let error = playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.yellow)
                    Text("播放失败")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding()
            }

            if let osdIcon = osdIcon {
                Image(systemName: osdIcon)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        .overlay {
            PlayerGestureLayer(
                onSeek: { offset in seek(by: offset) },
                onTogglePlayPause: { togglePlayPauseWithOSD() },
                onToggleControls: { wakeUpControls() },
                onZoomChanged: { scale in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        videoZoomScale = scale
                    }
                },
                currentTime: currentTime,
                duration: duration
            )
        }
        #endif
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                if player != nil {
                    playbackControls(containerWidth: proxy.size.width)
                        .opacity(showControls ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.3), value: showControls)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .overlay {
            SystemPlayerKeyboardCaptureView(
                onLeft: { seek(by: -seekStep) },
                onRight: { seek(by: seekStep) },
                onTogglePlayPause: { togglePlayPause() },
                onToggleFullScreen: { onToggleFullScreen?() },
                onVolumeDown: { wakeUpControls(); adjustVolume(by: -volumeStep) },
                onVolumeUp: { wakeUpControls(); adjustVolume(by: volumeStep) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): wakeUpControls()
            case .ended: break
            }
        }
        .onAppear {
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onChange(of: urlString) { _, _ in
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onChange(of: httpHeaders) { _, _ in
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onDisappear {
            cleanupPlayer(keepSharedPlayer: sharedController != nil)
            controlsTimer?.invalidate()
            osdTimer?.invalidate()
        }
        #if os(iOS)
        .sheet(item: $trackSelectionSheetKind) { kind in
            trackSelectionSheet(for: kind)
        }
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func setupPlayer() {
        guard let url = Self.sanitizedURL(from: urlString) else {
            print("[AVPlayer] URL sanitization failed for: \(urlString)")
            return
        }
        let targetURLString = url.absoluteString
        let normalizedHeaders = PlaybackHTTPHeaders.normalized(httpHeaders)
        let targetPlaybackKey = targetURLString + "\n" + PlaybackHTTPHeaders.cacheKey(normalizedHeaders)
        let preferredRate = normalizedSavedPlaybackRate
        rate = preferredRate
        playbackError = nil
        hasReportedPlaybackFailure = false

        if let sharedController,
           sharedController.mediaURLString == targetPlaybackKey,
           let sharedPlayer = sharedController.player {
            cleanupPlayer(keepSharedPlayer: true)
            // 强制重新关联 AVPlayerItem，修复从全屏退出后 VideoPlayer 黑屏问题。
            // SwiftUI.VideoPlayer 在复用已有 AVPlayer 时可能无法正确连接视频渲染层，
            // 通过 replaceCurrentItem 触发内部 layer 重新绑定。
            #if os(iOS)
            if let currentItem = sharedPlayer.currentItem {
                let currentTime = sharedPlayer.currentTime()
                let wasPlaying = sharedPlayer.rate != 0
                sharedPlayer.replaceCurrentItem(with: nil)
                sharedPlayer.replaceCurrentItem(with: currentItem)
                sharedPlayer.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    if wasPlaying {
                        sharedPlayer.playImmediately(atRate: self.normalizedSavedPlaybackRate)
                    }
                }
            }
            #endif
            player = sharedPlayer
            applyPreferredPlaybackRate(to: sharedPlayer)
            applySubtitleAppearance(to: sharedPlayer.currentItem)
            bindPlayerObservers(for: sharedPlayer)
            reportProgress(for: sharedPlayer)
            return
        }

        // 清理旧播放器
        cleanupPlayer()

        let assetOptions: [String: Any]? = normalizedHeaders.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": normalizedHeaders]
        let asset = AVURLAsset(url: url, options: assetOptions)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        applySubtitleAppearance(to: playerItem)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.defaultRate = preferredRate
        if let sharedController {
            sharedController.setPlayer(newPlayer, urlString: targetPlaybackKey)
        }

        player = newPlayer
        bindPlayerObservers(for: newPlayer)
        startPlayback(for: newPlayer)
    }

    /// 将原始 URL 字符串转换为合法的 URL，处理未编码的特殊字符。
    private static func sanitizedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            return url
        }
        // 尝试对整个字符串进行百分号编码（保留已编码部分）
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }

    private func bindPlayerObservers(for player: AVPlayer) {
        var observations: [NSKeyValueObservation] = [
            player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                let status = p.timeControlStatus
                DispatchQueue.main.async {
                    isPlaying = status == .playing
                    if status == .playing { onPlaybackStarted?() }
                }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { p, _ in
                let reason = p.reasonForWaitingToPlay
                DispatchQueue.main.async { isPreparing = reason != nil }
            },
            player.observe(\.volume, options: [.new]) { p, _ in
                let vol = Double(p.volume)
                DispatchQueue.main.async { volume = vol }
            },
            player.observe(\.rate, options: [.new]) { p, _ in
                let currentRate = p.rate
                guard currentRate > 0 else { return }
                let normalized = Self.normalizedPlaybackRate(from: currentRate)
                DispatchQueue.main.async {
                    rate = normalized
                    if abs(savedPlaybackRate - Double(normalized)) > 0.001 {
                        savedPlaybackRate = Double(normalized)
                    }
                }
            }
        ]
        // 监听 AVPlayerItem 状态，捕获加载失败的具体原因
        if let item = player.currentItem {
            observations.append(item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
                if observedItem.status == .failed {
                    let errorDesc = observedItem.error?.localizedDescription ?? "未知错误"
                    DispatchQueue.main.async {
                        self.reportPlaybackFailure(errorDesc)
                    }
                } else if observedItem.status == .readyToPlay {
                    DispatchQueue.main.async {
                        playbackError = nil
                        hasReportedPlaybackFailure = false
                        reportVideoOrientation(for: observedItem.presentationSize)
                        refreshMediaTracks(for: player)
                    }
                }
            })
            observations.append(item.observe(\.presentationSize, options: [.initial, .new]) { observedItem, _ in
                let presentationSize = observedItem.presentationSize
                DispatchQueue.main.async {
                    reportVideoOrientation(for: presentationSize)
                }
            })
            observePlaybackFailure(for: item, player: player)
        }
        playerObservers = observations
        observePlaybackProgress(for: player)
        observePlaybackEnd(for: player)
        refreshMediaTracks(for: player)
        isPlaying = player.timeControlStatus == .playing
        if isPlaying { onPlaybackStarted?() }
        isPreparing = player.reasonForWaitingToPlay != nil
        volume = Double(player.volume)
        rate = normalizedSavedPlaybackRate
    }

    private func detachPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailedObserver = nil
        }
        if let observer = playbackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackStalledObserver = nil
        }
        stalledRecoveryWorkItem?.cancel()
        stalledRecoveryWorkItem = nil
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }

    private func cleanupPlayer(keepSharedPlayer: Bool = false) {
        let currentPlayer = player
        detachPlayerObservers()
        lastReportedVideoOrientation = nil
        lastReportedVideoSize = .zero
        if !keepSharedPlayer {
            resetMediaTracks()
        }

        guard let currentPlayer else { return }
        if keepSharedPlayer, sharedController?.player === currentPlayer {
            player = nil
            return
        }

        currentPlayer.pause()
        if sharedController?.player === currentPlayer {
            sharedController?.player = nil
            sharedController?.mediaURLString = nil
        }
        player = nil
        // replaceCurrentItem(with: nil) 在播放网络流时会阻塞主线程，移到后台
        DispatchQueue.global(qos: .utility).async {
            currentPlayer.replaceCurrentItem(with: nil)
        }
    }

    private func reportVideoOrientation(for size: CGSize) {
        reportVideoSizeIfNeeded(size)
        let normalizedOrientation: Bool?
        if size.width > size.height, size.height > 0 {
            normalizedOrientation = true
        } else if size.height > size.width, size.width > 0 {
            normalizedOrientation = false
        } else {
            normalizedOrientation = nil
        }

        guard normalizedOrientation != lastReportedVideoOrientation else { return }
        lastReportedVideoOrientation = normalizedOrientation
        onVideoOrientationChanged?(normalizedOrientation)
    }

    private func reportVideoSizeIfNeeded(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - lastReportedVideoSize.width) > 1 || abs(size.height - lastReportedVideoSize.height) > 1 else { return }
        lastReportedVideoSize = size
        onVideoSizeChanged?(size)
    }

    private func startPlayback(for player: AVPlayer) {
        let target = max(startPosition, 0)

        if target > 0 {
            let seekTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                reportProgress(for: player)
                playAtPreferredRate(player)
            }
        } else {
            playAtPreferredRate(player)
        }
    }

    private func togglePlayPause() {
        guard let player = player else { return }
        if player.rate == 0 {
            playAtPreferredRate(player)
        } else {
            player.pause()
        }
    }

    private func togglePlayPauseWithOSD() {
        togglePlayPause()
        showOSD(icon: isPlaying ? "pause.fill" : "play.fill")
    }

    private func wakeUpControls() {
        withAnimation { showControls = true }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                showControls = false
            }
        }
    }

    private func showOSD(icon: String) {
        osdIcon = icon
        osdOpacity = 1.0
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                osdOpacity = 0.0
            }
        }
    }

    private func observePlaybackEnd(for player: AVPlayer) {
        guard let item = player.currentItem else { return }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onPlaybackEnded?()
        }
    }

    private func observePlaybackFailure(for item: AVPlayerItem, player: AVPlayer) {
        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.reportPlaybackFailure(error?.localizedDescription ?? "播放中断")
        }

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            self.scheduleStalledRecoveryCheck(for: player)
        }
    }

    private func scheduleStalledRecoveryCheck(for player: AVPlayer) {
        stalledRecoveryWorkItem?.cancel()
        let baseline = player.currentTime().seconds
        let workItem = DispatchWorkItem {
            guard self.player === player else { return }
            let current = player.currentTime().seconds
            let advanced = current.isFinite && baseline.isFinite ? current - baseline : 0
            if advanced < 0.5 && player.timeControlStatus != .playing {
                self.reportPlaybackFailure("播放卡住")
            }
        }
        stalledRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: workItem)
    }

    private func reportPlaybackFailure(_ message: String) {
        guard !hasReportedPlaybackFailure else { return }
        hasReportedPlaybackFailure = true
        isPreparing = false
        playbackError = message
        onPlaybackFailed?()
    }

    private func observePlaybackProgress(for player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            reportProgress(for: player)
        }
    }

    private func reportProgress(for player: AVPlayer?) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite, current >= 0 else { return }

        if !isDraggingProgress {
            self.currentTime = current
            self.draggingSeconds = current
        }

        let rawDuration = player.currentItem?.duration.seconds
        if let rawDuration, rawDuration.isFinite, rawDuration >= 0 {
            self.duration = rawDuration
        }
        onProgressChanged?(current, duration > 0 ? duration : nil)
    }

    private func refreshMediaTracks(for player: AVPlayer) {
        guard let item = player.currentItem else {
            resetMediaTracks()
            return
        }

        refreshAudioTracks(for: item)
        refreshSubtitleTracks(for: item)
    }

    private func refreshAudioTracks(for item: AVPlayerItem) {
        audioSelectionOptions.removeAll()
        audioItemTracks.removeAll()

        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            var tracks: [MediaTrackOption] = []
            if group.allowsEmptySelection {
                tracks.append(.disabled(kind: .audio, id: "av-audio-disabled"))
            }

            for (index, option) in group.options.enumerated() {
                let id = avMediaSelectionID(kind: .audio, index: index, option: option)
                tracks.append(MediaTrackOption(
                    id: id,
                    kind: .audio,
                    title: avMediaSelectionTitle(option: option, fallback: "音轨 \(index + 1)"),
                    rawValue: index,
                    isDisabled: false
                ))
                audioSelectionOptions[id] = option
            }

            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            audioTracks = tracks
            selectedAudioTrackID = selected.flatMap { selectedOption in
                tracks.first { audioSelectionOptions[$0.id] === selectedOption }?.id
            } ?? tracks.first(where: { $0.isDisabled })?.id ?? tracks.first?.id
            return
        }

        let itemAudioTracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        guard itemAudioTracks.count > 1 else {
            audioTracks = []
            selectedAudioTrackID = nil
            return
        }

        var tracks: [MediaTrackOption] = []
        for (index, itemTrack) in itemAudioTracks.enumerated() {
            let id = "av-item-audio-\(itemTrack.assetTrack?.trackID ?? CMPersistentTrackID(index + 1))"
            let title = itemTrack.assetTrack?.languageCode?.nilIfBlank
                ?? itemTrack.assetTrack?.extendedLanguageTag?.nilIfBlank
                ?? "音轨 \(index + 1)"
            let option = MediaTrackOption(id: id, kind: .audio, title: title, rawValue: index, isDisabled: false)
            tracks.append(option)
            audioItemTracks[id] = itemTrack
        }

        audioTracks = tracks
        selectedAudioTrackID = tracks.first { audioItemTracks[$0.id]?.isEnabled == true }?.id ?? tracks.first?.id
    }

    private func refreshSubtitleTracks(for item: AVPlayerItem) {
        subtitleSelectionOptions.removeAll()

        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            subtitleTracks = []
            selectedSubtitleTrackID = nil
            return
        }

        var tracks: [MediaTrackOption] = [.disabled(kind: .subtitle, id: "av-subtitle-disabled")]
        for (index, option) in group.options.enumerated() {
            let id = avMediaSelectionID(kind: .subtitle, index: index, option: option)
            tracks.append(MediaTrackOption(
                id: id,
                kind: .subtitle,
                title: avMediaSelectionTitle(option: option, fallback: "字幕 \(index + 1)"),
                rawValue: index,
                isDisabled: false
            ))
            subtitleSelectionOptions[id] = option
        }

        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        subtitleTracks = tracks
        selectedSubtitleTrackID = selected.flatMap { selectedOption in
            tracks.first { subtitleSelectionOptions[$0.id] === selectedOption }?.id
        } ?? tracks.first(where: { $0.isDisabled })?.id
    }

    private func resetMediaTracks() {
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        audioSelectionOptions = [:]
        subtitleSelectionOptions = [:]
        audioItemTracks = [:]
    }

    private func selectAudioTrack(_ track: MediaTrackOption) {
        guard let item = player?.currentItem else { return }
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            if track.isDisabled {
                item.select(nil, in: group)
            } else if let option = audioSelectionOptions[track.id] {
                item.select(option, in: group)
            }
            refreshAudioTracks(for: item)
            return
        }

        guard let selectedItemTrack = audioItemTracks[track.id] else { return }
        for itemTrack in audioItemTracks.values {
            itemTrack.isEnabled = itemTrack === selectedItemTrack
        }
        refreshAudioTracks(for: item)
    }

    private func selectSubtitleTrack(_ track: MediaTrackOption) {
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if track.isDisabled {
            item.select(nil, in: group)
        } else if let option = subtitleSelectionOptions[track.id] {
            item.select(option, in: group)
        }
        refreshSubtitleTracks(for: item)
    }

    private func avMediaSelectionID(kind: MediaTrackKind, index: Int, option: AVMediaSelectionOption) -> String {
        "av-\(kind.rawValue)-\(index)-\(option.displayName)-\(option.hash)"
    }

    private func avMediaSelectionTitle(option: AVMediaSelectionOption, fallback: String) -> String {
        let displayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty { return displayName }
        if let locale = option.locale,
           let languageCode = locale.language.languageCode?.identifier,
           let languageName = Locale.current.localizedString(forLanguageCode: languageCode) {
            return languageName
        }
        return fallback
    }

    private var seekStep: Double {
        let saved = UserDefaults.standard.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        return Double(saved > 0 ? saved : 10)
    }

    private var volumeStep: Double { 0.1 }

    private var progressUpperBound: Double {
        max(duration, max(currentTime, 1))
    }

    private var fullscreenToggleIconName: String {
        isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    private func playbackControls(containerWidth: CGFloat) -> some View {
        #if os(iOS)
        let controlWidth = containerWidth * 1.0
        #else
        let availableControlWidth = max(containerWidth - 24, 0)
        let controlWidth = min(
            availableControlWidth,
            max(containerWidth * 0.84, min(availableControlWidth, 760))
        )
        #endif

        return VStack(spacing: 0) {
            #if os(iOS)
            // iOS: 紧凑单行布局 — 进度条在上，按钮在下紧贴
            // 进度条行
            HStack(spacing: 8) {
                Text(currentTime.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)

                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: {
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            commitProgressSeek()
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)

                Text(duration.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 控制按钮行 — 紧凑排列
            HStack(spacing: 0) {
                // 左：倍速、音轨、字幕
                HStack(spacing: 6) {
                    playbackRateMenu
                    if shouldShowAudioTrackMenu {
                        audioTrackMenu
                    }
                    if shouldShowSubtitleTrackMenu {
                        subtitleTrackMenu
                        subtitleStyleMenu
                    }
                }
                .frame(minWidth: 36, alignment: .leading)

                Spacer()

                // 中间：主控按钮
                HStack(spacing: 20) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)

                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)

                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 16, weight: .medium))
                                .frame(minWidth: 36, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }

                Spacer()

                // 右：全屏
                if let onToggleFullScreen {
                    Button {
                        wakeUpControls()
                        onToggleFullScreen()
                    } label: {
                        Image(systemName: fullscreenToggleIconName)
                            .font(.system(size: 14, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            #else
            // macOS: 保持两行布局
            HStack(spacing: 12) {
                Text(currentTime.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: {
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            commitProgressSeek()
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)

                Text(duration.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 0) {
                // 左侧区：倍速、音轨、字幕
                HStack(spacing: 10) {
                    playbackRateMenu
                    if shouldShowAudioTrackMenu {
                        audioTrackMenu
                    }
                    if shouldShowSubtitleTrackMenu {
                        subtitleTrackMenu
                        subtitleStyleMenu
                    }
                }
                .frame(width: 356, alignment: .leading)

                Spacer()

                HStack(spacing: 24) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 38, height: 38)

                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }

                Spacer()

                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Button {
                            wakeUpControls()
                            let newVolume = volume > 0 ? 0.0 : 1.0
                            player?.volume = Float(newVolume)
                            showOSD(icon: newVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)

                        PlayerVolumeSlider(
                            value: Binding(
                                get: { volume },
                                set: {
                                    player?.volume = Float($0)
                                    wakeUpControls()
                                }
                            ),
                            range: 0...1.0
                        )
                        .frame(width: 80)
                    }

                    if let onToggleFullScreen {
                        Button {
                            wakeUpControls()
                            onToggleFullScreen()
                        } label: {
                            Image(systemName: fullscreenToggleIconName)
                                .font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.top, 8)
            #endif
        }
        #if os(iOS)
        .padding(.vertical, 2)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .padding(.bottom, 0)
        .frame(width: controlWidth)
        #else
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .foregroundColor(.white)
        .glassCard(cornerRadius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(width: controlWidth)
        #endif
        .environment(\.colorScheme, .dark)
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.supportedPlaybackRates, id: \.self) { r in
                Button {
                    wakeUpControls()
                    setPlaybackRate(r)
                    showOSD(icon: "speedometer")
                } label: {
                    HStack {
                        Text("\(String(format: "%.1f", r))x")
                        if r == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(String(format: "%.1f", rate))x")
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var shouldShowAudioTrackMenu: Bool {
        audioTracks.contains { !$0.isDisabled }
    }

    private var shouldShowSubtitleTrackMenu: Bool {
        subtitleTracks.filter { !$0.isDisabled }.isEmpty == false
    }

    private var hasSelectableAudioTracks: Bool {
        shouldShowAudioTrackMenu
    }

    private var hasSelectableSubtitleTracks: Bool {
        shouldShowSubtitleTrackMenu
    }

    private var audioTrackMenu: some View {
        #if os(iOS)
        Button {
            wakeUpControls()
            trackSelectionSheetKind = .audio
        } label: {
            trackMenuLabel(
                icon: "waveform.circle.fill",
                title: selectedTrackTitle(in: audioTracks, selectedID: selectedAudioTrackID, fallback: "音轨")
            )
        }
        .buttonStyle(.plain)
        #else
        Menu {
            ForEach(audioTracks.filter { !$0.isDisabled }) { track in
                Button {
                    wakeUpControls()
                    selectAudioTrack(track)
                    showOSD(icon: "waveform")
                } label: {
                    trackMenuItem(track: track, selectedID: selectedAudioTrackID)
                }
            }
        } label: {
            trackMenuLabel(
                icon: "waveform.circle.fill",
                title: selectedTrackTitle(in: audioTracks, selectedID: selectedAudioTrackID, fallback: "音轨")
            )
        }
        .buttonStyle(.plain)
        #endif
    }

    private var subtitleTrackMenu: some View {
        #if os(iOS)
        Button {
            wakeUpControls()
            trackSelectionSheetKind = .subtitle
        } label: {
            trackMenuLabel(
                icon: "captions.bubble.fill",
                title: selectedTrackTitle(in: subtitleTracks, selectedID: selectedSubtitleTrackID, fallback: "字幕")
            )
        }
        .buttonStyle(.plain)
        #else
        Menu {
            if subtitleTracks.isEmpty {
                Text("暂无可选字幕")
            } else {
                ForEach(subtitleTracks) { track in
                    Button {
                        wakeUpControls()
                        selectSubtitleTrack(track)
                        showOSD(icon: track.isDisabled ? "captions.bubble" : "captions.bubble.fill")
                    } label: {
                        trackMenuItem(track: track, selectedID: selectedSubtitleTrackID)
                    }
                }
            }
        } label: {
            trackMenuLabel(
                icon: "captions.bubble.fill",
                title: selectedTrackTitle(in: subtitleTracks, selectedID: selectedSubtitleTrackID, fallback: "字幕")
            )
        }
        .buttonStyle(.plain)
        #endif
    }

    private var subtitleStyleMenu: some View {
        Menu {
            Text("大小 \(subtitleAppearance.textScale)%")
            Button {
                changeSubtitleAppearance(subtitleAppearance.resized(by: SubtitleAppearance.textScaleStep), icon: "textformat.size.larger")
            } label: {
                Label("增大字幕", systemImage: "textformat.size.larger")
            }
            Button {
                changeSubtitleAppearance(subtitleAppearance.resized(by: -SubtitleAppearance.textScaleStep), icon: "textformat.size.smaller")
            } label: {
                Label("减小字幕", systemImage: "textformat.size.smaller")
            }
            Divider()
            Text("位置 \(subtitleAppearance.positionLabel)")
            Button {
                changeSubtitleAppearance(subtitleAppearance.moved(by: SubtitleAppearance.verticalOffsetStep), icon: "arrow.up")
            } label: {
                Label("字幕上移", systemImage: "arrow.up")
            }
            Button {
                changeSubtitleAppearance(subtitleAppearance.moved(by: -SubtitleAppearance.verticalOffsetStep), icon: "arrow.down")
            } label: {
                Label("字幕下移", systemImage: "arrow.down")
            }
            Divider()
            Button {
                changeSubtitleAppearance(.defaults, icon: "arrow.counterclockwise")
            } label: {
                Label("重置字幕", systemImage: "arrow.counterclockwise")
            }
        } label: {
            trackMenuLabel(icon: "textformat.size", title: "样式")
        }
        .buttonStyle(.plain)
    }

    private func trackMenuItem(track: MediaTrackOption, selectedID: String?) -> some View {
        HStack {
            Text(track.title)
            if track.id == selectedID {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func trackSelectionSheet(for kind: TrackSelectionSheetKind) -> some View {
        NavigationStack {
            List {
                if kind == .audio {
                    ForEach(audioTracks.filter { !$0.isDisabled }) { track in
                        Button {
                            wakeUpControls()
                            selectAudioTrack(track)
                            showOSD(icon: "waveform")
                            trackSelectionSheetKind = nil
                        } label: {
                            trackSelectionSheetRow(track: track, selectedID: selectedAudioTrackID)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(subtitleTracks) { track in
                        Button {
                            wakeUpControls()
                            selectSubtitleTrack(track)
                            showOSD(icon: track.isDisabled ? "captions.bubble" : "captions.bubble.fill")
                            trackSelectionSheetKind = nil
                        } label: {
                            trackSelectionSheetRow(track: track, selectedID: selectedSubtitleTrackID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        trackSelectionSheetKind = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func trackSelectionSheetRow(track: MediaTrackOption, selectedID: String?) -> some View {
        HStack(spacing: 12) {
            Text(track.title)
                .foregroundColor(.white)
            Spacer()
            if track.id == selectedID {
                Image(systemName: "checkmark")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 6)
    }
    #endif

    private func trackMenuLabel(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 92, alignment: .leading)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
    }

    private func selectedTrackTitle(in tracks: [MediaTrackOption], selectedID: String?, fallback: String) -> String {
        tracks.first { $0.id == selectedID }?.compactTitle ?? fallback
    }

    private var volumeIconName: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var normalizedSavedPlaybackRate: Float {
        Self.normalizedPlaybackRate(from: Float(savedPlaybackRate))
    }

    private static func normalizedPlaybackRate(from raw: Float) -> Float {
        guard !supportedPlaybackRates.isEmpty else { return 1.0 }
        return supportedPlaybackRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private func syncRateFromSettings() {
        rate = normalizedSavedPlaybackRate
    }

    private func setPlaybackRate(_ value: Float) {
        let normalized = Self.normalizedPlaybackRate(from: value)
        rate = normalized
        savedPlaybackRate = Double(normalized)
        guard let player else { return }
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func applyPreferredPlaybackRate(to player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func changeSubtitleAppearance(_ appearance: SubtitleAppearance, icon: String) {
        subtitleAppearance = appearance
        appearance.save()
        applySubtitleAppearance(to: player?.currentItem)
        wakeUpControls()
        showOSD(icon: icon)
    }

    private func applySubtitleAppearance(to item: AVPlayerItem?) {
        item?.textStyleRules = subtitleAppearance.avTextStyleRules
    }

    private func playAtPreferredRate(_ player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        player.playImmediately(atRate: normalized)
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let target = clampedProgressSeconds(seconds)
        currentTime = target
        draggingSeconds = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        isPreparing = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                guard self.player === player else { return }
                self.isPreparing = player.reasonForWaitingToPlay != nil
                    || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    private func commitProgressSeek() {
        let target = clampedProgressSeconds(draggingSeconds)
        draggingSeconds = target
        currentTime = target
        seek(to: target)
    }

    private func clampedProgressSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), progressUpperBound)
    }

    private func seek(by offset: Double) {
        guard let player else { return }

        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let wasPlaying = player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        var target = max(current + offset, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            target = min(target, duration)
        }

        isPreparing = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            DispatchQueue.main.async {
                guard self.player === player else { return }
                reportProgress(for: player)
                if wasPlaying {
                    playAtPreferredRate(player)
                }
                self.isPreparing = player.reasonForWaitingToPlay != nil
                    || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    private func adjustVolume(by delta: Double) {
        guard let player else { return }
        let current = Double(player.volume)
        let target = min(max(current + delta, 0), 1)
        player.volume = Float(target)
        showOSD(icon: target <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
}

struct LoadingSpeedOverlay: View {
    @StateObject private var trafficMonitor = NetworkTrafficMonitor()

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.white)
            Text(trafficMonitor.speedText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .frame(minWidth: 72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { trafficMonitor.start() }
        .onDisappear { trafficMonitor.stop() }
    }
}

struct PlayerVolumeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = CGFloat(fraction)
            let knobRadius = knobSize / 2
            let knobX = min(max(width * progress, knobRadius), max(knobRadius, width - knobRadius))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.white.opacity(0.82))
                    .frame(width: max(0, width * progress), height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .position(x: knobX, y: proxy.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateValue(locationX: gesture.location.x, width: width)
                    }
            )
        }
        .frame(height: 18)
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func updateValue(locationX: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let progress = min(max(locationX / width, 0), 1)
        value = range.lowerBound + (range.upperBound - range.lowerBound) * Double(progress)
    }
}

@MainActor
final class NetworkTrafficMonitor: ObservableObject {
    @Published private(set) var speedText = "0 KB/s"

    private var timer: Timer?
    private var warmupWorkItem: DispatchWorkItem?
    private var lastReceivedBytes: UInt64?
    private var lastSampleDate: Date?

    func start() {
        timer?.invalidate()
        warmupWorkItem?.cancel()
        lastReceivedBytes = nil
        lastSampleDate = nil
        sample()

        let warmupWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        self.warmupWorkItem = warmupWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: warmupWorkItem)

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        warmupWorkItem?.cancel()
        timer = nil
        warmupWorkItem = nil
        lastReceivedBytes = nil
        lastSampleDate = nil
        speedText = "0 KB/s"
    }

    private func sample() {
        let receivedBytes = Self.currentReceivedBytes()
        let date = Date()
        defer {
            lastReceivedBytes = receivedBytes
            lastSampleDate = date
        }

        guard let lastReceivedBytes, let lastSampleDate else {
            speedText = "0 KB/s"
            return
        }

        let interval = max(date.timeIntervalSince(lastSampleDate), 0.001)
        let delta = receivedBytes >= lastReceivedBytes ? receivedBytes - lastReceivedBytes : 0
        speedText = Self.format(bytesPerSecond: Double(delta) / interval)
    }

    private static func currentReceivedBytes() -> UInt64 {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return 0 }
        defer { freeifaddrs(addresses) }

        var preferredTotal: UInt64 = 0
        var fallbackTotal: UInt64 = 0
        var cursor = addresses
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next

            guard let address = interface.ifa_addr else { continue }
            guard Int32(address.pointee.sa_family) == AF_LINK else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let dataPointer = interface.ifa_data else { continue }

            let name = String(cString: interface.ifa_name)
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            let bytes = UInt64(data.ifi_ibytes)
            if Self.isPreferredTrafficInterface(name) {
                preferredTotal &+= bytes
            } else if Self.isFallbackTrafficInterface(name) {
                fallbackTotal &+= bytes
            }
        }
        return preferredTotal > 0 ? preferredTotal : fallbackTotal
    }

    private static func isPreferredTrafficInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    private static func isFallbackTrafficInterface(_ name: String) -> Bool {
        let ignoredPrefixes = ["lo", "utun", "ipsec", "gif", "stf", "awdl", "llw", "bridge", "p2p", "anpi"]
        return ignoredPrefixes.contains { name.hasPrefix($0) } == false
    }

    private static func format(bytesPerSecond: Double) -> String {
        let kilobytes = max(bytesPerSecond / 1024.0, 0)
        if kilobytes < 1000 {
            return "\(Int(kilobytes.rounded())) KB/s"
        }
        return String(format: "%.1f MB/s", kilobytes / 1024.0)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if os(macOS)
private struct SystemPlayerKeyboardCaptureView: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void

    func makeNSView(context: Context) -> SystemPlayerKeyCaptureNSView {
        let view = SystemPlayerKeyCaptureNSView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }

    func updateNSView(_ nsView: SystemPlayerKeyCaptureNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.activate()
        }
    }

    private func applyCallbacks(to view: SystemPlayerKeyCaptureNSView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureNSView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activate()
    }

    func activate() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 123: // left
            onLeft?()
            return
        case 124: // right
            onRight?()
            return
        case 125: // down
            onVolumeDown?()
            return
        case 126: // up
            onVolumeUp?()
            return
        case 49: // space
            onTogglePlayPause?()
            return
        default: break
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "k": onTogglePlayPause?()
        case "f": onToggleFullScreen?()
        default: super.keyDown(with: event)
        }
    }
}
#else
private struct SystemPlayerKeyboardCaptureView: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void

    func makeUIView(context: Context) -> SystemPlayerKeyCaptureUIView {
        let view = SystemPlayerKeyCaptureUIView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }

    func updateUIView(_ uiView: SystemPlayerKeyCaptureUIView, context: Context) {
        applyCallbacks(to: uiView)
        DispatchQueue.main.async {
            uiView.activate()
        }
    }

    private func applyCallbacks(to view: SystemPlayerKeyCaptureUIView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureUIView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleVolumeDown)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleVolumeUp)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "k", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(handleToggleFullScreen))
        ]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }

    func activate() {
        becomeFirstResponder()
    }

    @objc private func handleLeft() { onLeft?() }
    @objc private func handleRight() { onRight?() }
    @objc private func handleVolumeDown() { onVolumeDown?() }
    @objc private func handleVolumeUp() { onVolumeUp?() }
    @objc private func handleTogglePlayPause() { onTogglePlayPause?() }
    @objc private func handleToggleFullScreen() { onToggleFullScreen?() }
}
#endif
