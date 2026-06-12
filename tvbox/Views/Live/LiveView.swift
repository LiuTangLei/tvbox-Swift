import SwiftUI
import AVKit
#if os(macOS)
import AppKit
#endif

/// 直播页 - 对应 Android 版 LivePlayActivity
struct LiveView: View {
    /// 退出直播回调（iOS 用于返回首页并显示 TabBar）。
    var onExit: (() -> Void)? = nil
    /// 直播频道与选中状态管理。
    @StateObject private var viewModel = LiveViewModel()
    /// 全局应用状态（用于 macOS 全屏时调整分栏布局）。
    @EnvironmentObject var appState: AppState
    /// 系统播放器实例（仅在选择系统内核时使用）。
    @State private var avPlayer: AVPlayer?
    /// 直播播放器内核配置（新字段）。
    @AppStorage(HawkConfig.PLAY_TYPE_LIVE) private var livePlayTypeRaw = -1
    /// 兼容旧版本单播放器字段。
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    /// 直播专用画面缩放；未配置时回退点播缩放。
    @AppStorage(HawkConfig.LIVE_SCALE) private var liveVideoScaleRaw = -1
    /// 点播缩放兜底值，对齐 Android LiveSetting.getScale()。
    @AppStorage(HawkConfig.PLAY_SCALE) private var vodVideoScaleRaw = VideoScaleMode.defaultMode.rawValue
    /// 是否展示左侧频道抽屉。
    @State private var showChannelDrawer = true
    #if os(iOS)
    /// iOS 全屏频道覆盖层是否显示。
    @State private var showChannelOverlay = false
    #endif
    /// 隐藏直播分组解锁面板是否显示。
    @State private var showLiveGroupUnlockPanel = false
    /// 隐藏直播分组密码输入。
    @State private var liveGroupPassword = ""
    /// 最近一次隐藏分组解锁是否失败。
    @State private var liveGroupUnlockFailed = false
    /// 当前窗口是否处于全屏。
    @State private var isWindowFullScreen = false
    /// 底部频道信息卡最大宽度。
    private let currentChannelInfoMaxWidth: CGFloat = 600
    /// AVPlayer 状态观察者。
    @State private var itemStatusObserver: NSKeyValueObservation?
    /// 播放失败通知观察者。
    @State private var playbackFailedObserver: NSObjectProtocol?
    /// 播放卡顿通知观察者。
    @State private var playbackStalledObserver: NSObjectProtocol?
    /// 当前频道已失败的线路索引，用于自动切线去重。
    @State private var failedSourceIndices: Set<Int> = []
    /// 当前跟踪的频道 ID（频道切换时重置失败状态）。
    @State private var trackedChannelId: String = ""
    /// 底部频道信息是否显示。
    @State private var showCurrentChannelInfo = true
    /// 自动隐藏频道信息的定时器。
    @State private var channelInfoTimer: Timer?
    /// 频道信息自动隐藏延迟（秒）。
    private let channelInfoAutoHideDelay: TimeInterval = 3.0
    /// 用户交互令牌，递增后可通知 VLC 子视图重置自动隐藏逻辑。
    @State private var vlcInteractionToken = 0
    
    /// 当前实际生效的播放器内核。
    /// 优先读取直播专用字段，再回退老字段，最后使用默认值。
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) != nil {
            rawValue = livePlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.isVLCAvailable
                ? PlayerEngine.vlc.rawValue
                : PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }

    private var liveVideoScaleMode: VideoScaleMode {
        let defaults = UserDefaults.standard
        let rawValue = defaults.object(forKey: HawkConfig.LIVE_SCALE) == nil
            ? vodVideoScaleRaw
            : liveVideoScaleRaw
        return VideoScaleMode.fromStoredValue(rawValue)
    }
    
    var body: some View {
        NavigationStack {
            contentLayer
            .navigationTitle("直播")
            #if os(macOS)
            .toolbar(isWindowFullScreen ? .hidden : .visible, for: .windowToolbar)
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            #endif
            .onAppear {
                // 首次进入时加载频道并展示频道信息卡。
                viewModel.loadChannels()
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: viewModel.currentPlaybackIdentifier) { _, _ in
                if selectedEngine == .system {
                    playChannel(playback: viewModel.currentPlayback)
                } else {
                    cleanupPlayer()
                }
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: viewModel.currentChannel?.id) { _, _ in
                // 切台后清空失败线路记录，避免复用上个频道的失败状态。
                resetFailureTracking(for: viewModel.currentChannel)
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: selectedEngine) { _, _ in
                if selectedEngine == .system {
                    playChannel(playback: viewModel.currentPlayback)
                } else {
                    cleanupPlayer()
                }
            }
            .onDisappear {
                cleanupPlayer()
                cancelChannelInfoAutoHide()
                #if os(macOS)
                appState.exitPlayerFullScreen()
                isWindowFullScreen = false
                #endif
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isWindowFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isWindowFullScreen = false
                appState.exitPlayerFullScreen()
            }
            .onExitCommand {
                if showChannelDrawer {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChannelDrawer = false
                    }
                }
            }
            #endif
        }
    }

    private var contentLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.channelGroups.isEmpty && !viewModel.hasHiddenGroups {
                emptyState
            } else {
                activePlayerLayer
                overlayUI
            }
        }
    }

    @ViewBuilder
    private var activePlayerLayer: some View {
        if selectedEngine == .vlc {
            if let playback = viewModel.currentPlayback, !playback.url.isEmpty {
                VLCLivePlayerView(
                    urlString: playback.url,
                    playback: playback,
                    httpHeaders: playback.headers,
                    videoScaleMode: liveVideoScaleMode,
                    activityToken: vlcInteractionToken,
                    onPlaybackFailed: {
                        handlePlaybackFailure(trigger: "vlc_error")
                    },
                    onToggleFullScreen: {
                        toggleWindowFullScreen()
                    }
                )
                .ignoresSafeArea()
                .id("vlc-live-\(viewModel.currentPlaybackIdentifier)-\(viewModel.currentChannel?.id ?? "")")
            }
        } else if let player = avPlayer {
            PlatformVideoPlayer(player: player, videoScaleMode: liveVideoScaleMode)
                .ignoresSafeArea()
        }
    }
    
    // MARK: - 空状态
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("暂无直播源")
                .font(.headline)
                .foregroundColor(.gray)
            Text("请在设置中配置包含直播源的接口")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - 覆盖 UI
    
    private var overlayUI: some View {
        ZStack(alignment: .leading) {
            #if os(macOS)
            if showChannelDrawer {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showChannelDrawer = false
                        }
                    }
            }
            #endif
            
            VStack(spacing: 0) {
                HStack {
                    #if os(iOS)
                    liveBackButton
                    #endif
                    channelDrawerToggleButton
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.horizontal, 16)
                
                Spacer()
                
                // 底部当前频道信息
                if let channel = viewModel.currentChannel, showCurrentChannelInfo {
                    currentChannelInfo(channel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            #if os(macOS)
            if showChannelDrawer {
                channelDrawer
                    .padding(.leading, 12)
                    .padding(.vertical, 20)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            #endif

            if showLiveGroupUnlockPanel {
                liveGroupUnlockOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if !showLiveGroupUnlockPanel, let message = viewModel.currentDRMPlaybackWarning {
                DRMPlaybackWarningBanner(message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 74)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCurrentChannelInfo)
        .animation(.easeInOut(duration: 0.18), value: showLiveGroupUnlockPanel)
        .animation(.easeInOut(duration: 0.18), value: viewModel.currentDRMPlaybackWarning)
        #if os(macOS)
        .animation(.easeInOut(duration: 0.2), value: showChannelDrawer)
        #endif
        .simultaneousGesture(
            TapGesture().onEnded {
                reportUserActivity()
            }
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $showChannelOverlay) {
            ChannelOverlayView(
                channelGroups: viewModel.channelGroups,
                selectedGroupIndex: $viewModel.selectedGroupIndex,
                currentChannels: viewModel.currentChannels,
                currentChannel: viewModel.currentChannel,
                hasHiddenGroups: viewModel.hasHiddenGroups,
                hasUnlockedHiddenGroups: viewModel.hasUnlockedHiddenGroups,
                onSelectGroup: { viewModel.selectGroup($0) },
                onSelectChannel: { channel in
                    viewModel.selectChannel(channel)
                    HapticManager.shared.mediumImpact()
                    showChannelOverlay = false
                },
                onToggleHiddenGroups: handleHiddenGroupLockButton,
                onDismiss: { showChannelOverlay = false }
            )
            .presentationBackground(.clear)
            .transition(.move(edge: .bottom))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showChannelOverlay)
        }
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                reportUserActivity()
            case .ended:
                break
            }
        }
        #endif
    }
    
    private var channelDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("频道菜单", systemImage: "list.bullet.rectangle.portrait")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()

                if viewModel.hasHiddenGroups {
                    Button {
                        handleHiddenGroupLockButton()
                    } label: {
                        Image(systemName: viewModel.hasUnlockedHiddenGroups ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(viewModel.hasUnlockedHiddenGroups ? .orange : .white.opacity(0.8))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.hasUnlockedHiddenGroups ? "锁定隐藏分组" : "解锁隐藏分组")
                }
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChannelDrawer = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            
            HStack(spacing: 0) {
                channelGroupList
                    .frame(width: 150)
                
                Divider()
                    .overlay(Color.white.opacity(0.1))
                
                channelList
                    .frame(width: 240)
            }

            if viewModel.isLoading || !viewModel.epgList.isEmpty || viewModel.epgErrorMessage != nil {
                Divider()
                    .overlay(Color.white.opacity(0.1))
                epgListPanel
                    .frame(maxHeight: 220)
            }
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 14)
    }

    private var liveGroupUnlockOverlay: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissLiveGroupUnlockPanel()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                    Text("隐藏分组")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Spacer()
                    Button {
                        dismissLiveGroupUnlockPanel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                SecureField("密码", text: $liveGroupPassword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                liveGroupUnlockFailed ? Color.red.opacity(0.65) : Color.white.opacity(0.18),
                                lineWidth: 0.8
                            )
                    )
                    .onSubmit {
                        submitLiveGroupUnlock()
                    }

                if liveGroupUnlockFailed {
                    Text("密码不正确")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red.opacity(0.9))
                }

                HStack(spacing: 10) {
                    Button {
                        dismissLiveGroupUnlockPanel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                            Text("取消")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        submitLiveGroupUnlock()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open.fill")
                            Text("解锁")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(AppTheme.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(liveGroupPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(liveGroupPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                }
            }
            .padding(18)
            .frame(width: 300)
            .glassCard(cornerRadius: 14)
        }
    }

    #if os(iOS)
    private var liveBackButton: some View {
        Button {
            HapticManager.shared.lightImpact()
            onExit?()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
    #endif
    
    private var channelDrawerToggleButton: some View {
        Button {
            #if os(iOS)
            HapticManager.shared.lightImpact()
            showChannelOverlay = true
            #else
            withAnimation(.easeInOut(duration: 0.2)) {
                showChannelDrawer.toggle()
            }
            #endif
        } label: {
            HStack(spacing: 8) {
                #if os(iOS)
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                Text("频道")
                    .font(.system(size: 14, weight: .semibold))
                #else
                Image(systemName: showChannelDrawer ? "sidebar.left" : "sidebar.right")
                Text(showChannelDrawer ? "收起菜单" : "频道菜单")
                    .font(.system(size: 13, weight: .semibold))
                #endif
            }
            .foregroundColor(.white.opacity(0.9))
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            #else
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #endif
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .keyboardShortcut("m", modifiers: [.command])
        #endif
    }
    
    private func currentChannelInfo(_ channel: LiveChannelItem) -> some View {
        #if os(iOS)
        // iOS: 紧凑的底部信息栏，适合单手操作
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // 频道名称
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(channel.channelName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                
                Spacer()

                Button {
                    HapticManager.shared.lightImpact()
                    wakeUpCurrentChannelInfo()
                    viewModel.toggleFavorite(channel)
                } label: {
                    Image(systemName: viewModel.isFavorite(channel) ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(viewModel.isFavorite(channel) ? .yellow : .white.opacity(0.65))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                // 线路信息
                if viewModel.isPlayingCatchup {
                    Text("回看")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange.opacity(0.8))
                } else if channel.sourceNum > 1 {
                    Text("线路 \(channel.sourceIndex + 1)/\(channel.sourceNum)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            epgStatusLine

            // 操作按钮行
            HStack(spacing: 12) {
                Button {
                    HapticManager.shared.lightImpact()
                    wakeUpCurrentChannelInfo()
                    viewModel.toggleFavorite(channel)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isFavorite(channel) ? "star.fill" : "star")
                            .font(.system(size: 13))
                        Text(viewModel.isFavorite(channel) ? "已收藏" : "收藏")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(viewModel.isFavorite(channel) ? .yellow : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                if viewModel.isPlayingCatchup {
                    Button {
                        HapticManager.shared.lightImpact()
                        wakeUpCurrentChannelInfo()
                        viewModel.returnToLive()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 13))
                            Text("返回直播")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                if channel.sourceNum > 1 {
                    Button {
                        HapticManager.shared.mediumImpact()
                        wakeUpCurrentChannelInfo()
                        resetFailureTracking(for: viewModel.currentChannel)
                        viewModel.switchSource()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13))
                            Text("切换线路")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(AppTheme.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        #else
        // macOS: 保持原有宽屏布局
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(channel.channelName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
                
                if viewModel.isPlayingCatchup {
                    Text("正在回看：\(viewModel.catchupPlayback?.epg.title ?? "")")
                        .font(.system(size: 12))
                        .foregroundColor(.orange.opacity(0.8))
                        .lineLimit(1)
                } else if channel.sourceNum > 1 {
                    Text("正在播放：线路 \(channel.sourceIndex + 1) / \(channel.sourceNum)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }

                epgStatusLine
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    wakeUpCurrentChannelInfo()
                    viewModel.toggleFavorite(channel)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isFavorite(channel) ? "star.fill" : "star")
                        Text(viewModel.isFavorite(channel) ? "已收藏" : "收藏")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(viewModel.isFavorite(channel) ? .yellow : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                if viewModel.isPlayingCatchup {
                    Button {
                        wakeUpCurrentChannelInfo()
                        viewModel.returnToLive()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("返回直播")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if channel.sourceNum > 1 {
                    Button {
                        wakeUpCurrentChannelInfo()
                        resetFailureTracking(for: viewModel.currentChannel)
                        viewModel.switchSource()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                            Text("切换线路")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(AppTheme.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                
                Button {
                    wakeUpCurrentChannelInfo()
                    toggleWindowFullScreen()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("全屏")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: AppTheme.glassRadius)
        .frame(maxWidth: currentChannelInfoMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(20)
        #endif
    }

    @ViewBuilder
    private var epgStatusLine: some View {
        if let playback = viewModel.catchupPlayback {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                Text([playback.epg.timeRange, playback.epg.title].filter { !$0.isEmpty }.joined(separator: "  "))
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
        } else if viewModel.isLoading {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("节目单加载中")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
            .lineLimit(1)
        } else if let current = viewModel.currentEpg {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                Text([current.timeRange, current.title].filter { !$0.isEmpty }.joined(separator: "  "))
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.72))
        } else if let next = viewModel.nextEpg {
            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text([next.timeRange, next.title].filter { !$0.isEmpty }.joined(separator: "  "))
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.62))
        }
    }

    private var epgListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("节目单", systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)

            if !viewModel.epgDates.isEmpty {
                Picker(
                    "",
                    selection: Binding(
                        get: { viewModel.selectedEpgDateIndex },
                        set: { viewModel.selectEpgDate($0) }
                    )
                ) {
                    ForEach(viewModel.epgDates) { date in
                        Text(date.datePresent)
                            .tag(date.index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if viewModel.epgList.isEmpty {
                Text(viewModel.isLoading ? "加载中" : "暂无节目单")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.epgList) { item in
                            epgListRow(item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func epgListRow(_ item: Epginfo) -> some View {
        let canCatchup = viewModel.canPlayCatchup(item)
        if canCatchup {
            Button {
                wakeUpCurrentChannelInfo()
                viewModel.playCatchup(item)
            } label: {
                epgRowContent(item, canCatchup: canCatchup)
            }
            .buttonStyle(.plain)
        } else {
            epgRowContent(item, canCatchup: canCatchup)
        }
    }

    private func epgRowContent(_ item: Epginfo, canCatchup: Bool) -> some View {
        HStack(spacing: 8) {
            Text(item.timeRange)
                .font(.system(size: 11, weight: item.isLive ? .semibold : .regular))
                .foregroundColor(item.isLive ? .orange : .white.opacity(0.45))
                .frame(width: 72, alignment: .leading)

            Text(item.title)
                .font(.system(size: 12, weight: item.isLive ? .semibold : .regular))
                .foregroundColor(item.isLive ? .white.opacity(0.9) : .white.opacity(0.65))
                .lineLimit(1)

            Spacer(minLength: 0)

            if canCatchup {
                Image(systemName: viewModel.isPlayingCatchup(item) ? "play.fill" : "play.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(viewModel.isPlayingCatchup(item) ? .orange : .white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(item.isLive ? Color.orange.opacity(0.13) : Color.clear)
        .contentShape(Rectangle())
    }
    
    private func wakeUpCurrentChannelInfo() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showCurrentChannelInfo = true
        }
        channelInfoTimer?.invalidate()
        guard viewModel.currentChannel != nil else { return }
        
        channelInfoTimer = Timer.scheduledTimer(withTimeInterval: channelInfoAutoHideDelay, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.3)) {
                showCurrentChannelInfo = false
            }
        }
    }
    
    private func cancelChannelInfoAutoHide() {
        channelInfoTimer?.invalidate()
        channelInfoTimer = nil
    }
    
    private func reportUserActivity() {
        // 任意交互都刷新显示时间，并触发 VLC 子层同步交互状态。
        wakeUpCurrentChannelInfo()
        vlcInteractionToken &+= 1
    }

    private func handleHiddenGroupLockButton() {
        reportUserActivity()
        if viewModel.hasUnlockedHiddenGroups {
            viewModel.lockHiddenGroups()
            return
        }
        #if os(iOS)
        showChannelOverlay = false
        #endif
        liveGroupPassword = ""
        liveGroupUnlockFailed = false
        withAnimation(.easeInOut(duration: 0.18)) {
            showLiveGroupUnlockPanel = true
        }
    }

    private func submitLiveGroupUnlock() {
        let unlocked = viewModel.unlockHiddenGroups(password: liveGroupPassword)
        if unlocked {
            dismissLiveGroupUnlockPanel()
            wakeUpCurrentChannelInfo()
        } else {
            liveGroupUnlockFailed = true
        }
    }

    private func dismissLiveGroupUnlockPanel() {
        liveGroupPassword = ""
        liveGroupUnlockFailed = false
        withAnimation(.easeInOut(duration: 0.18)) {
            showLiveGroupUnlockPanel = false
        }
    }
    
    // MARK: - 频道分组
    
    private var channelGroupList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.channelGroups.enumerated()), id: \.offset) { index, group in
                    Button {
                        withAnimation {
                            viewModel.selectGroup(index)
                        }
                    } label: {
                        Text(group.groupName)
                            .font(.system(size: 14, weight: viewModel.selectedGroupIndex == index ? .bold : .medium))
                            .foregroundColor(viewModel.selectedGroupIndex == index ? .orange : .white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                viewModel.selectedGroupIndex == index
                                    ? Color.white.opacity(0.1)
                                    : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 频道列表
    
    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.currentChannels.enumerated()), id: \.offset) { index, channel in
                    Button {
                        withAnimation {
                            viewModel.selectedChannelIndex = index
                            viewModel.selectChannel(channel)
                        }
                    } label: {
                        HStack {
                            Text(channel.channelName)
                                .font(.system(size: 14, weight: viewModel.currentChannel?.channelName == channel.channelName ? .bold : .medium))
                                .foregroundColor(viewModel.currentChannel?.channelName == channel.channelName ? .orange : .white.opacity(0.8))
                            Spacer()
                            if viewModel.isFavorite(channel) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.yellow.opacity(0.85))
                            }
                            if channel.sourceNum > 1 {
                                Text("\(channel.sourceNum)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.3))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            viewModel.currentChannel?.channelName == channel.channelName
                                ? Color.orange.opacity(0.15)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 播放
    
    private func playChannel(playback: PlayableItem?) {
        guard let playback,
              let url = URL(string: playback.url) else {
            handlePlaybackFailure(trigger: "invalid_url")
            return
        }
        
        cleanupPlayer()
        
        // 使用 AVURLAsset 并设置自定义 HTTP 头，解决部分 CDN 拒绝无 User-Agent 请求的问题
        let headers = PlaybackHTTPHeaders.normalizedForPlayback(playback.headers)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        // 直播场景优先实时性，避免过多缓冲导致内存上涨
        playerItem.preferredForwardBufferDuration = 3
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        observePlaybackFailure(for: playerItem)
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.play()
        avPlayer = newPlayer
    }
    
    private func cleanupPlayer() {
        // 先移除观察者再释放播放器，避免悬空回调。
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailedObserver = nil
        }
        if let observer = playbackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackStalledObserver = nil
        }
        itemStatusObserver = nil
        
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
    }
    
    private func observePlaybackFailure(for item: AVPlayerItem) {
        // KVO 监听 item 状态失败。
        itemStatusObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
            if observedItem.status == .failed {
                DispatchQueue.main.async {
                    handlePlaybackFailure(trigger: "status_failed")
                }
            }
        }
        
        // 播放到结尾失败回调。
        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            handlePlaybackFailure(trigger: "item_failed")
        }
        
        // 播放卡顿回调。
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            handlePlaybackFailure(trigger: "playback_stalled")
        }
    }
    
    private func resetFailureTracking(for channel: LiveChannelItem?) {
        failedSourceIndices = []
        trackedChannelId = channel?.id ?? ""
    }
    
    private func handlePlaybackFailure(trigger: String) {
        guard let channel = viewModel.currentChannel else { return }
        guard channel.sourceNum > 1 else { return }
        
        if trackedChannelId != channel.id {
            resetFailureTracking(for: channel)
        }
        
        let failedIndex = channel.sourceIndex
        guard !failedSourceIndices.contains(failedIndex) else { return }
        failedSourceIndices.insert(failedIndex)
        
        guard switchToNextAvailableSource(totalSources: channel.sourceNum) else {
            print("直播线路全部尝试失败: channel=\(channel.channelName), trigger=\(trigger)")
            return
        }
    }
    
    private func switchToNextAvailableSource(totalSources: Int) -> Bool {
        guard failedSourceIndices.count < totalSources else { return false }
        
        // 最多轮询 `totalSources` 次，找到一条尚未失败的线路即返回。
        for _ in 0..<totalSources {
            viewModel.switchSource()
            guard let nextIndex = viewModel.currentChannel?.sourceIndex else { return false }
            if !failedSourceIndices.contains(nextIndex) {
                return true
            }
        }
        
        return false
    }
    
    #if os(macOS)
    private func toggleWindowFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let enteringFullScreen = !window.styleMask.contains(.fullScreen)
        if enteringFullScreen {
            isWindowFullScreen = true
            appState.enterPlayerFullScreen()
        }
        window.toggleFullScreen(nil)
    }
    #else
    private func toggleWindowFullScreen() {}
    #endif
}
