import SwiftUI
import AVKit
import Darwin

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
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
        if player !== newPlayer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
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
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
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
        let path = url.path.lowercased()
        return path.hasPrefix("/bridge/local/") || path.hasPrefix("/bridge/media/")
    }
    
    var body: some View {
        Group {
            switch selectedEngine {
            case .system:
                AVPlayerContentView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: systemController
                )
            case .vlc:
                VLCVodPlayerView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
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
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: SystemPlayerSessionController? = nil
    @AppStorage(HawkConfig.PLAY_SPEED) private var savedPlaybackRate = 1.0
    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
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
    @State private var audioSelectionOptions: [String: AVMediaSelectionOption] = [:]
    @State private var subtitleSelectionOptions: [String: AVMediaSelectionOption] = [:]
    @State private var audioItemTracks: [String: AVPlayerItemTrack] = [:]
    
    @State private var videoZoomScale: CGFloat = 1.0

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
        .onDisappear {
            cleanupPlayer(keepSharedPlayer: sharedController != nil)
            controlsTimer?.invalidate()
            osdTimer?.invalidate()
        }
    }
    
    private func setupPlayer() {
        guard let url = Self.sanitizedURL(from: urlString) else {
            print("[AVPlayer] URL sanitization failed for: \(urlString)")
            return
        }
        let targetURLString = url.absoluteString
        let preferredRate = normalizedSavedPlaybackRate
        rate = preferredRate
        playbackError = nil
        
        if let sharedController,
           sharedController.mediaURLString == targetURLString,
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
            bindPlayerObservers(for: sharedPlayer)
            reportProgress(for: sharedPlayer)
            return
        }
        
        // 清理旧播放器
        cleanupPlayer()
        
        // 使用 AVURLAsset 并设置自定义 HTTP 头，解决部分 CDN 拒绝无 User-Agent 请求的问题
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.defaultRate = preferredRate
        if let sharedController {
            sharedController.setPlayer(newPlayer, urlString: targetURLString)
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
                DispatchQueue.main.async { isPlaying = status == .playing }
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
                        isPreparing = false
                        playbackError = errorDesc
                    }
                } else if observedItem.status == .readyToPlay {
                    DispatchQueue.main.async {
                        playbackError = nil
                        refreshMediaTracks(for: player)
                    }
                }
            })
        }
        playerObservers = observations
        observePlaybackProgress(for: player)
        observePlaybackEnd(for: player)
        refreshMediaTracks(for: player)
        isPlaying = player.timeControlStatus == .playing
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
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }
    
    private func cleanupPlayer(keepSharedPlayer: Bool = false) {
        let currentPlayer = player
        detachPlayerObservers()
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

    private func playbackControls(containerWidth: CGFloat) -> some View {
        #if os(iOS)
        let controlWidth = containerWidth * 1.0
        #else
        let controlWidth = containerWidth * 0.7
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
                            seek(to: draggingSeconds)
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
                // 左：倍速
                playbackRateMenu
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
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
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
                            seek(to: draggingSeconds)
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
                    }
                }
                .frame(width: 260, alignment: .leading)
                
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

                        Slider(
                            value: Binding(
                                get: { volume },
                                set: {
                                    player?.volume = Float($0)
                                    wakeUpControls()
                                }
                            ),
                            in: 0...1.0
                        )
                        .accentColor(.white.opacity(0.8))
                        .frame(width: 80)
                    }
                    
                    if let onToggleFullScreen {
                        Button {
                            wakeUpControls()
                            onToggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
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
        audioTracks.filter { !$0.isDisabled }.count > 1 || audioTracks.contains(where: { $0.isDisabled })
    }

    private var shouldShowSubtitleTrackMenu: Bool {
        subtitleTracks.filter { !$0.isDisabled }.isEmpty == false
    }

    private var audioTrackMenu: some View {
        Menu {
            ForEach(audioTracks) { track in
                Button {
                    wakeUpControls()
                    selectAudioTrack(track)
                    showOSD(icon: track.isDisabled ? "speaker.slash.fill" : "waveform")
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
    }

    private var subtitleTrackMenu: some View {
        Menu {
            ForEach(subtitleTracks) { track in
                Button {
                    wakeUpControls()
                    selectSubtitleTrack(track)
                    showOSD(icon: track.isDisabled ? "captions.bubble" : "captions.bubble.fill")
                } label: {
                    trackMenuItem(track: track, selectedID: selectedSubtitleTrackID)
                }
            }
        } label: {
            trackMenuLabel(
                icon: "captions.bubble.fill",
                title: selectedTrackTitle(in: subtitleTracks, selectedID: selectedSubtitleTrackID, fallback: "字幕")
            )
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

    private func playAtPreferredRate(_ player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        player.playImmediately(atRate: normalized)
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
        
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            reportProgress(for: player)
            if wasPlaying {
                playAtPreferredRate(player)
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

@MainActor
final class NetworkTrafficMonitor: ObservableObject {
    @Published private(set) var speedText = "0 KB/s"

    private var timer: Timer?
    private var lastReceivedBytes: UInt64?
    private var lastSampleDate: Date?

    func start() {
        timer?.invalidate()
        lastReceivedBytes = nil
        lastSampleDate = nil
        sample()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

        var total: UInt64 = 0
        var cursor = addresses
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next

            guard let address = interface.ifa_addr else { continue }
            guard Int32(address.pointee.sa_family) == AF_LINK else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let dataPointer = interface.ifa_data else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            total &+= UInt64(data.ifi_ibytes)
        }
        return total
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
