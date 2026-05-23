import SwiftUI
import SwiftData
import WebKit
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// 详情页 - 对应 Android 版 DetailActivity
struct DetailView: View {
    let video: Movie.Video
    @StateObject private var viewModel = DetailViewModel()
    @StateObject private var sharedSystemController = SystemPlayerSessionController()
    @StateObject private var sharedVLCController = VLCPlayerController()
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var showFullScreen = false
    /// VLC 全屏退出动画期间为 true，防止内联播放器与全屏播放器同时争抢 drawable
    @State private var isFullScreenDismissing = false
    #if os(macOS)
    @State private var pendingMacWindowFullScreen = false
    #endif
    @State private var lastPersistedProgress: Double = 0
    @State private var isCollected = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 播放器区域
                if !showFullScreen, !isFullScreenDismissing, viewModel.isPlaying, let url = viewModel.playUrl {
                    PlayerView(
                        urlString: url,
                        startPosition: viewModel.currentPlaybackSeconds(),
                        onProgressChanged: handlePlaybackProgress,
                        onPlaybackEnded: playNextEpisodeIfNeeded,
                        onToggleFullScreen: {
                            openFullScreenPlayer()
                        },
                        canPlayNext: canPlayNextEpisode,
                        onPlayNext: playNextEpisodeIfNeeded,
                        systemController: sharedSystemController,
                        vlcController: sharedVLCController
                    )
                        .id("\(viewModel.selectedFlag)-\(viewModel.selectedEpisodeIndex)-\(url)")
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)
                        .onTapGesture(count: 2) {
                            openFullScreenPlayer()
                        }
                }
                
                // 视频信息
                videoInfoSection
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                if shouldShowPlaybackStatus {
                    playbackStatusSection
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 线路选择
                if viewModel.flags.count > 1 {
                    flagSelector
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 清晰度选择
                if viewModel.hasQualityChoices {
                    qualitySelector
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 剧集列表
                if !viewModel.currentEpisodes.isEmpty {
                    episodeSection
                        .padding(.top, 16)
                }
                
                // 简介
                if let info = viewModel.vodInfo, !info.des.isEmpty {
                    descriptionSection(info.des)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 40)
        }
        .background(AppTheme.primaryGradient)
        .navigationTitle(video.name)
        #if os(macOS)
        .toolbar((showFullScreen || pendingMacWindowFullScreen) ? .hidden : .visible, for: .windowToolbar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(video.sourceKey)-\(video.id)") {
            await viewModel.loadDetail(video: video)
            restorePlaybackFromHistory()
            refreshCollectState()
        }
        .onDisappear {
            viewModel.commitPlaybackProgressSnapshot()
            persistHistoryIfNeeded(force: true)
            showFullScreen = false
            sharedSystemController.stop()
            sharedVLCController.stop()
            #if os(macOS)
            pendingMacWindowFullScreen = false
            appState.exitPlayerFullScreen()
            #endif
        }
        #if os(macOS)
        .overlay {
            if showFullScreen, let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: closeMacFullScreenOverlay
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            guard pendingMacWindowFullScreen else { return }
            pendingMacWindowFullScreen = false
            showFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            pendingMacWindowFullScreen = false
            if showFullScreen {
                showFullScreen = false
            }
            appState.exitPlayerFullScreen()
            refreshMacDrawableAfterFullScreenExit()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            isFullScreenDismissing = false
        }) {
            if let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: {
                        isFullScreenDismissing = true
                        showFullScreen = false
                    }
                )
            }
        }
        #endif
        .sheet(
            isPresented: $viewModel.isBridgeTokenPromptPresented,
            onDismiss: { viewModel.dismissBridgeTokenPromptPresentation() }
        ) {
            if let prompt = viewModel.bridgeTokenPrompt {
                BridgeTokenPromptSheet(
                    prompt: prompt,
                    isSubmitting: viewModel.isSubmittingBridgeToken,
                    errorMessage: viewModel.bridgeTokenErrorMessage,
                    onCancel: viewModel.cancelBridgeTokenPrompt,
                    onOpenAndroidJarUi: { prompt in
                        try await viewModel.openBridgeJarUi(prompt: prompt)
                    },
                    onPollAndroidJarUi: {
                        try await viewModel.pollBridgeJarUi()
                    },
                    onActionAndroidJarUi: { action in
                        try await viewModel.sendBridgeJarUiAction(action)
                    },
                    onCompleteAndroidJarUi: {
                        await viewModel.closeBridgeJarUi()
                    },
                    onSubmit: { values in
                        Task { await viewModel.submitBridgeToken(values: values) }
                    }
                )
            }
        }
        .sheet(
            isPresented: $viewModel.isBridgeJarUiPresented,
            onDismiss: { viewModel.dismissPlaybackBridgeJarUiPresentation() }
        ) {
            if let response = viewModel.bridgeJarUiResponse {
                BridgeJarUiSheet(
                    title: viewModel.bridgeJarUiTitle,
                    initialResponse: response,
                    onPoll: {
                        try await viewModel.pollPlaybackBridgeJarUi()
                    },
                    onAction: { action in
                        try await viewModel.sendPlaybackBridgeJarUiAction(action)
                    },
                    onCancel: viewModel.cancelPlaybackBridgeJarUi,
                    onComplete: {
                        await viewModel.closePlaybackBridgeJarUi()
                    }
                )
            }
        }
    }
    
    // MARK: - 视频信息
    
    #if os(iOS)
    @ViewBuilder
    private var videoInfoSection: some View {
        VStack(spacing: 16) {
            // Poster centered, height capped to 30% of screen
            let posterHeight = UIScreen.main.bounds.height * 0.30
            CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                image.resizable().aspectRatio(2/3, contentMode: .fit)
            } placeholder: {
                Color.white.opacity(0.05)
                    .aspectRatio(2/3, contentMode: .fit)
            }
            .frame(maxHeight: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))

            // Info below poster
            videoDetails

            // Action buttons with 48pt height
            HStack(spacing: 12) {
                playButton
                collectButton
            }
            .frame(minHeight: 48)
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #else
    @ViewBuilder
    private var videoInfoSection: some View {
        HStack(alignment: .top, spacing: 20) {
            videoPoster
            
            videoDetails
            
            Spacer()
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #endif

    @ViewBuilder
    private var videoPoster: some View {
        CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
            image.resizable().aspectRatio(2/3, contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.white.opacity(0.05)
                Image(systemName: "film.fill").foregroundColor(.white.opacity(0.2))
            }
            .aspectRatio(2/3, contentMode: .fill)
        }
        .frame(width: 130)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private var videoDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.vodInfo?.name ?? video.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            
            if let info = viewModel.vodInfo {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("年份", info.year)
                    infoRow("地区", info.area)
                    infoRow("类型", info.typeName)
                    infoRow("导演", info.director)
                    infoRow("演员", info.actor)
                }
            }
            
            #if os(macOS)
            Spacer(minLength: 10)
            
            HStack(spacing: 10) {
                playButton
                collectButton
            }
            #endif
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if !viewModel.isPlaying && viewModel.vodInfo != nil {
            Button {
                guard !viewModel.isResolvingBridgePlayback else { return }
                viewModel.selectEpisode(index: 0)
                saveHistoryForCurrentEpisode()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isResolvingBridgePlayback {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("解析中")
                    } else {
                        Image(systemName: "play.fill")
                        Text("立即播放")
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(AppTheme.accentGradient)
                .clipShape(Capsule())
                .shadow(color: .red.opacity(0.4), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isResolvingBridgePlayback)
        }
    }
    
    private var collectButton: some View {
        Button {
            toggleCollect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollected ? "heart.fill" : "heart")
                Text(isCollected ? "已收藏" : "收藏")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isCollected {
                        AppTheme.accentGradient
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isCollected ? 0 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 36, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
    }
    
    // MARK: - 线路选择
    
    @ViewBuilder
    private var flagSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放线路")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            flagScrollView
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    @ViewBuilder
    private var flagScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.flags, id: \.self) { flag in
                    flagButton(flag)
                }
            }
        }
    }

    @ViewBuilder
    private func flagButton(_ flag: String) -> some View {
        Button {
            withAnimation {
                viewModel.selectFlag(flag)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(flag)
                .font(.system(size: 14, weight: viewModel.selectedFlag == flag ? .bold : .medium))
                .foregroundColor(viewModel.selectedFlag == flag ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedFlag == flag {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 清晰度选择
    
    @ViewBuilder
    private var qualitySelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频清晰度")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.qualityOptions) { option in
                        qualityButton(option)
                    }
                }
            }
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    
    @ViewBuilder
    private func qualityButton(_ option: PlaybackQualityOption) -> some View {
        Button {
            withAnimation {
                viewModel.selectQuality(option)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(option.name)
                .font(.system(size: 14, weight: viewModel.selectedQualityId == option.id ? .bold : .medium))
                .foregroundColor(viewModel.selectedQualityId == option.id ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedQualityId == option.id {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 剧集列表
    
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选集播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            EpisodeListView(
                episodes: viewModel.currentEpisodes,
                selectedIndex: viewModel.selectedEpisodeIndex,
                isResolving: viewModel.isResolvingBridgePlayback,
                resolvingIndex: viewModel.selectedEpisodeIndex,
                onSelect: { index in
                    withAnimation {
                        viewModel.selectEpisode(index: index)
                    }
                    saveHistoryForCurrentEpisode()
                }
            )
        }
    }
    
    // MARK: - 简介
    
    private func descriptionSection(_ des: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("影片简介")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            Text(des)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .lineSpacing(4)
                .lineLimit(nil)
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    private var canPlayNextEpisode: Bool {
        viewModel.selectedEpisodeIndex + 1 < viewModel.currentEpisodes.count
    }

    private var shouldShowPlaybackStatus: Bool {
        viewModel.isResolvingBridgePlayback
            || viewModel.bridgeTokenPrompt != nil
            || !(viewModel.bridgePlaybackMessage ?? "").isEmpty
            || !(viewModel.errorMessage ?? "").isEmpty
    }

    @ViewBuilder
    private var playbackStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isResolvingBridgePlayback {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(viewModel.bridgePlaybackMessage ?? "正在获取播放地址...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
            } else if let prompt = viewModel.bridgeTokenPrompt {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: prompt.login?.type.hasPrefix("androidJar") == true ? "rectangle.on.rectangle" : (prompt.login == nil ? "key.fill" : "qrcode.viewfinder"))
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(prompt.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text(prompt.message)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button {
                        viewModel.presentBridgeTokenPrompt()
                    } label: {
                        Text(prompt.login?.type.hasPrefix("androidJar") == true ? "打开 Jar" : (prompt.login == nil ? "输入 Token" : "扫码登录"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(AppTheme.accentGradient)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else if let message = viewModel.bridgePlaybackMessage, !message.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.yellow)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = viewModel.errorMessage, !error.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    
    private func saveHistoryForCurrentEpisode(progressOverride: Double? = nil) {
        let episodeName = viewModel.vodInfo?.currentEpisode?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let episodeLabel = episodeName.isEmpty ? "第\(viewModel.selectedEpisodeIndex + 1)集" : episodeName
        let progress = max(progressOverride ?? viewModel.currentPlaybackSeconds(), 0)
        let timeLabel = progress > 0 ? Int(progress).durationString : ""
        let playNote = timeLabel.isEmpty ? episodeLabel : "\(episodeLabel) \(timeLabel)"
        
        let playbackState = VodPlaybackState(
            flag: viewModel.selectedFlag,
            episodeIndex: viewModel.selectedEpisodeIndex,
            progressSeconds: progress
        )
        
        Task { @MainActor in
            CacheStore.shared.addRecord(
                video,
                playNote: playNote,
                playbackState: playbackState,
                context: modelContext
            )
        }
    }
    
    private func handlePlaybackProgress(_ seconds: Double, _: Double?) {
        viewModel.updatePlaybackProgress(seconds: seconds)
        persistHistoryIfNeeded(force: false, currentProgress: seconds)
    }
    
    private func persistHistoryIfNeeded(force: Bool, currentProgress: Double? = nil) {
        guard viewModel.isPlaying else { return }
        let progress = max(currentProgress ?? viewModel.currentPlaybackSeconds(), 0)
        guard progress.isFinite else { return }
        
        if !force && abs(progress - lastPersistedProgress) < 20 {
            return
        }
        
        lastPersistedProgress = progress
        saveHistoryForCurrentEpisode(progressOverride: progress)
    }
    
    private func restorePlaybackFromHistory() {
        guard let playbackState = CacheStore.shared.getPlaybackState(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        ) else { return }
        
        viewModel.applyPlaybackState(playbackState)
        lastPersistedProgress = max(playbackState.progressSeconds, 0)
    }
    
    private func refreshCollectState() {
        isCollected = CacheStore.shared.isCollected(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        )
    }
    
    private func toggleCollect() {
        if isCollected {
            CacheStore.shared.removeCollect(
                vodId: video.id,
                sourceKey: video.sourceKey,
                context: modelContext
            )
        } else {
            CacheStore.shared.addCollect(video, context: modelContext)
        }
        refreshCollectState()
    }
    
    private func playNextEpisodeIfNeeded() {
        var moved = false
        withAnimation {
            moved = viewModel.playNext()
        }
        
        if moved {
            saveHistoryForCurrentEpisode()
        }
    }
    
    private func openFullScreenPlayer() {
        #if os(iOS)
        showFullScreen = true
        #else
        guard viewModel.playUrl != nil else { return }
        appState.enterPlayerFullScreen()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            showFullScreen = true
            return
        }
        
        pendingMacWindowFullScreen = requestMacWindowFullScreen(enter: true)
        if !pendingMacWindowFullScreen {
            showFullScreen = true
        }
        #endif
    }
    
    #if os(macOS)
    @discardableResult
    private func requestMacWindowFullScreen(enter: Bool) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard enter != isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }
    
    private func closeMacFullScreenOverlay() {
        pendingMacWindowFullScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if window?.styleMask.contains(.fullScreen) == true {
            requestMacWindowFullScreen(enter: false)
            return
        }
        showFullScreen = false
        appState.exitPlayerFullScreen()
        refreshMacDrawableAfterFullScreenExit()
    }

    private func refreshMacDrawableAfterFullScreenExit() {
        [0.0, 0.12, 0.35].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                sharedVLCController.forceDrawableRefresh()
            }
        }
    }
    #endif
}

struct BridgeTokenPromptSheet: View {
    let prompt: BridgeTokenPrompt
    let isSubmitting: Bool
    let errorMessage: String?
    let submitTitle: String
    let onCancel: () -> Void
    let onOpenAndroidJarUi: ((BridgeTokenPrompt) async throws -> BridgeJarUiResponse)?
    let onPollAndroidJarUi: (() async throws -> BridgeJarUiStatusResponse)?
    let onActionAndroidJarUi: ((BridgeJarUiAction) async throws -> BridgeJarUiResponse)?
    let onCompleteAndroidJarUi: (() async -> Void)?
    let onSubmit: ([String: String]) -> Void
    @State private var values: [String: String]
    @State private var showWebLogin = false
    @State private var showAndroidJarUi = false

    init(
        prompt: BridgeTokenPrompt,
        isSubmitting: Bool,
        errorMessage: String?,
        submitTitle: String = "保存并重试",
        onCancel: @escaping () -> Void,
        onOpenAndroidJarUi: ((BridgeTokenPrompt) async throws -> BridgeJarUiResponse)? = nil,
        onPollAndroidJarUi: (() async throws -> BridgeJarUiStatusResponse)? = nil,
        onActionAndroidJarUi: ((BridgeJarUiAction) async throws -> BridgeJarUiResponse)? = nil,
        onCompleteAndroidJarUi: (() async -> Void)? = nil,
        onSubmit: @escaping ([String: String]) -> Void
    ) {
        self.prompt = prompt
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.submitTitle = submitTitle
        self.onCancel = onCancel
        self.onOpenAndroidJarUi = onOpenAndroidJarUi
        self.onPollAndroidJarUi = onPollAndroidJarUi
        self.onActionAndroidJarUi = onActionAndroidJarUi
        self.onCompleteAndroidJarUi = onCompleteAndroidJarUi
        self.onSubmit = onSubmit
        _values = State(initialValue: BridgeCredentialStore.shared.values(provider: prompt.provider, fields: prompt.fields))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if prompt.login?.type.hasPrefix("androidJar") == true {
                    Section {
                        Button {
                            showAndroidJarUi = true
                        } label: {
                            Label("打开 Jar 登录窗口", systemImage: "rectangle.on.rectangle")
                        }
                        .disabled(isSubmitting)
                    }
                } else if prompt.login != nil {
                    Section {
                        Button {
                            showWebLogin = true
                        } label: {
                            Label("扫码登录", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(isSubmitting)
                    }
                }

                Section {
                    ForEach(prompt.fields) { field in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(field.label)
                                .font(.subheadline.weight(.semibold))
                            if field.secure == true && field.multiline != true {
                                SecureField(field.placeholder ?? field.label, text: binding(for: field.key))
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField(field.placeholder ?? field.label, text: binding(for: field.key), axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(field.multiline == true ? 4...8 : 1...3)
                            }
                        }
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(prompt.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        onCancel()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "保存中" : submitTitle) {
                        onSubmit(trimmedValues)
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
        .sheet(isPresented: $showAndroidJarUi) {
            BridgeJarUiSheet(
                prompt: prompt,
                onStart: onOpenAndroidJarUi,
                onPoll: onPollAndroidJarUi,
                onAction: onActionAndroidJarUi,
                onCancel: { showAndroidJarUi = false },
                onComplete: {
                    showAndroidJarUi = false
                    if let onCompleteAndroidJarUi {
                        await onCompleteAndroidJarUi()
                    }
                }
            )
        }
        .sheet(isPresented: $showWebLogin) {
            if let login = prompt.login {
                BridgeWebLoginSheet(
                    login: login,
                    isSubmitting: isSubmitting,
                    onCancel: { showWebLogin = false },
                    onSubmit: { cookieValue in
                        var submitted = trimmedValues
                        let key = login.cookieKey?.isEmpty == false ? login.cookieKey! : "token"
                        submitted[key] = cookieValue
                        submitted["token"] = cookieValue
                        submitted["cookie"] = cookieValue
                        showWebLogin = false
                        onSubmit(submitted)
                    }
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var canSubmit: Bool {
        trimmedValues.values.contains { !$0.isEmpty }
    }

    private var trimmedValues: [String: String] {
        values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key, default: ""] },
            set: { values[key] = $0 }
        )
    }
}

struct BridgeJarUiSheet: View {
    let title: String
    let initialResponse: BridgeJarUiResponse?
    let onStart: (() async throws -> BridgeJarUiResponse)?
    let onPoll: (() async throws -> BridgeJarUiStatusResponse)?
    let onAction: ((BridgeJarUiAction) async throws -> BridgeJarUiResponse)?
    let onCancel: () -> Void
    let onComplete: () async -> Void
    @State private var imageData: Data?
    @State private var canvasWidth: Double = 0
    @State private var canvasHeight: Double = 0
    @State private var elements: [BridgeUiElement] = []
    @State private var selectedInput: BridgeUiElement?
    @State private var inputText = ""
    @State private var message = "正在请求 Android Jar 登录窗口..."
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isPolling = false
    @State private var isCompleting = false
    @State private var isSendingAction = false
    @State private var didAutoComplete = false
    @State private var didFinish = false
    @State private var pollFailureCount = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    init(
        prompt: BridgeTokenPrompt,
        onStart: ((BridgeTokenPrompt) async throws -> BridgeJarUiResponse)?,
        onPoll: (() async throws -> BridgeJarUiStatusResponse)?,
        onAction: ((BridgeJarUiAction) async throws -> BridgeJarUiResponse)?,
        onCancel: @escaping () -> Void,
        onComplete: @escaping () async -> Void
    ) {
        self.title = prompt.login?.title ?? prompt.title
        self.initialResponse = nil
        self.onStart = onStart.map { start in { try await start(prompt) } }
        self.onPoll = onPoll
        self.onAction = onAction
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    init(
        title: String,
        initialResponse: BridgeJarUiResponse?,
        onPoll: (() async throws -> BridgeJarUiStatusResponse)?,
        onAction: ((BridgeJarUiAction) async throws -> BridgeJarUiResponse)?,
        onCancel: @escaping () -> Void,
        onComplete: @escaping () async -> Void
    ) {
        self.title = title
        self.initialResponse = initialResponse
        self.onStart = nil
        self.onPoll = onPoll
        self.onAction = onAction
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                }

                if let imageData {
                    ZStack(alignment: .bottom) {
                        remoteCanvas(data: imageData)
                        if let toastMessage, !toastMessage.isEmpty {
                            Text(toastMessage)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.black.opacity(0.72), in: Capsule())
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: toastMessage)
                }

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if isPolling {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("等待 Android 端登录完成...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let selectedInput {
                    HStack(spacing: 8) {
                        TextField(selectedInput.hint?.isEmpty == false ? selectedInput.hint! : "输入内容", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await send(.input(element: selectedInput, text: inputText)) }
                            }
                        Button(isSendingAction ? "发送中" : "输入") {
                            Task { await send(.input(element: selectedInput, text: inputText)) }
                        }
                        .disabled(isSendingAction)
                        Button("确认") {
                            Task { await send(.submit(element: selectedInput)) }
                        }
                        .disabled(isSendingAction)
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("取消", role: .cancel) { Task { await cancelLogin() } }
                        .buttonStyle(.bordered)
                        .disabled(isCompleting)

                    Button("返回") {
                        Task { await send(.named("back")) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCompleting || isSendingAction)

                    Button("刷新") {
                        Task { await send(.named("refresh")) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCompleting || isSendingAction)

                    Button {
                        Task { await complete() }
                    } label: {
                        HStack(spacing: 8) {
                            if isCompleting { ProgressView().controlSize(.small) }
                            Text(isCompleting ? "处理中" : "已完成，重试播放")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCompleting || didAutoComplete)
                }
            }
            .padding(20)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { Task { await cancelLogin() } }
                        .disabled(isCompleting)
                }
            }
        }
        .task { await loadJarUi() }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
            toastTask?.cancel()
            toastTask = nil
            guard !didFinish, let onAction else { return }
            Task { _ = try? await onAction(.named("cancel")) }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    @MainActor
    private func loadJarUi() async {
        if let initialResponse {
            apply(initialResponse)
            startPolling()
            return
        }
        guard let onStart else {
            errorMessage = "当前页面没有连接 Android Jar 弹窗接口"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await onStart()
            apply(response)
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
            message = "未能打开 Android Jar 登录窗口"
        }
    }

    @MainActor
    private func startPolling() {
        guard onPoll != nil, pollTask == nil else { return }
        isPolling = true
        pollFailureCount = 0
        pollTask = Task { await pollUntilComplete() }
    }

    @MainActor
    private func pollUntilComplete() async {
        defer {
            isPolling = false
            pollTask = nil
        }
        while !Task.isCancelled && !didAutoComplete {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let onPoll else { return }
            do {
                let response = try await onPoll()
                pollFailureCount = 0
                apply(response)
                if response.isCompleted {
                    didAutoComplete = true
                    errorMessage = nil
                    message = response.message ?? "Android 端已完成登录，正在重试播放..."
                    await complete()
                    return
                }
                if response.status == "failed" || response.status == "cancelled" {
                    errorMessage = response.message ?? "Android Jar 操作未完成"
                    return
                }
                if errorMessage?.hasPrefix("状态检测失败") == true {
                    errorMessage = nil
                }
            } catch {
                pollFailureCount += 1
                if pollFailureCount >= 3 {
                    errorMessage = "状态检测失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func send(_ action: BridgeJarUiAction) async {
        guard let onAction else {
            errorMessage = "当前页面没有连接 Android Jar 弹窗操作接口"
            return
        }
        isSendingAction = true
        errorMessage = nil
        defer { isSendingAction = false }
        do {
            let response = try await onAction(action)
            apply(response)
            if action.action == "submit" { selectedInput = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func complete() async {
        let taskToCancel = pollTask
        pollTask = nil
        isPolling = false
        if !didAutoComplete { taskToCancel?.cancel() }
        didFinish = true
        isCompleting = true
        defer { isCompleting = false }
        await onComplete()
    }

    @MainActor
    private func cancelLogin() async {
        guard !isCompleting else { return }
        didFinish = true
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        if let onAction {
            isSendingAction = true
            _ = try? await onAction(.named("cancel"))
            isSendingAction = false
        }
        onCancel()
    }

    @MainActor
    private func apply(_ response: BridgeJarUiResponse) {
        if let responseMessage = response.message, !responseMessage.isEmpty { message = responseMessage }
        applySnapshot(image: response.image, width: response.width, height: response.height, elements: response.elements)
        applyToast(response.toast)
    }

    @MainActor
    private func apply(_ response: BridgeJarUiStatusResponse) {
        if let responseMessage = response.message, !responseMessage.isEmpty { message = responseMessage }
        applySnapshot(image: response.image, width: response.width, height: response.height, elements: response.elements)
        applyToast(response.toast)
    }

    @MainActor
    private func applySnapshot(image: String?, width: Double?, height: Double?, elements: [BridgeUiElement]?) {
        if let data = Self.decodeDataURL(image) { imageData = data }
        if let width, width > 0 { canvasWidth = width }
        if let height, height > 0 { canvasHeight = height }
        if let elements { self.elements = elements }
    }

    @MainActor
    private func applyToast(_ toast: BridgeTransientOverlay?) {
        guard let toast, !toast.message.isEmpty else { return }
        toastTask?.cancel()
        toastMessage = toast.message
        let duration = UInt64(max(toast.durationMs ?? 2200, 800)) * 1_000_000
        toastTask = Task {
            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }
            await MainActor.run {
                toastMessage = nil
                toastTask = nil
            }
        }
    }

    private func remoteCanvas(data: Data) -> some View {
        GeometryReader { proxy in
            let layout = canvasLayout(in: proxy.size)
            ZStack(alignment: .topLeading) {
                platformImage(data: data)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: layout.displayWidth, height: layout.displayHeight)
                    .background(Color.black.opacity(0.04))
                    .position(x: layout.offsetX + layout.displayWidth / 2, y: layout.offsetY + layout.displayHeight / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { value in
                            guard layout.scale > 0 else { return }
                            let x = Double((value.location.x - layout.offsetX) / layout.scale)
                            let y = Double((value.location.y - layout.offsetY) / layout.scale)
                            guard x >= 0, y >= 0, x <= canvasWidth, y <= canvasHeight else { return }
                            Task { await send(.click(x: x, y: y)) }
                        }
                    )

                ForEach(elements.filter { $0.isInteractive && $0.enabled != false }) { element in
                    Button {
                        if element.role == "input" {
                            selectedInput = element
                            inputText = element.value ?? ""
                            Task { await send(.click(element: element)) }
                        } else {
                            Task { await send(.click(element: element)) }
                        }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(element.role == "input" ? Color.accentColor.opacity(0.14) : Color.accentColor.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(element.focused == true ? Color.yellow.opacity(0.8) : Color.accentColor.opacity(element.role == "input" ? 0.65 : 0.35), lineWidth: element.focused == true ? 2 : 1)
                                )
                            if element.role == "input" || element.focused == true {
                                Text(element.displayText)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.55), in: Capsule())
                                    .padding(3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: CGFloat(element.width) * layout.scale, height: CGFloat(element.height) * layout.scale)
                    .position(
                        x: layout.offsetX + CGFloat(element.x + element.width / 2) * layout.scale,
                        y: layout.offsetY + CGFloat(element.y + element.height / 2) * layout.scale
                    )
                    .accessibilityLabel(element.displayText)
                }
            }
        }
        .frame(height: 430)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func canvasLayout(in size: CGSize) -> RemoteCanvasLayout {
        let sourceWidth = max(CGFloat(canvasWidth), 1)
        let sourceHeight = max(CGFloat(canvasHeight), 1)
        let scale = min(size.width / sourceWidth, size.height / sourceHeight)
        let displayWidth = sourceWidth * scale
        let displayHeight = sourceHeight * scale
        return RemoteCanvasLayout(
            scale: scale,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            offsetX: (size.width - displayWidth) / 2,
            offsetY: (size.height - displayHeight) / 2
        )
    }

    private static func decodeDataURL(_ value: String?) -> Data? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let range = text.range(of: "base64,") { text = String(text[range.upperBound...]) }
        return Data(base64Encoded: text)
    }

    private func platformImage(data: Data) -> Image {
        #if os(macOS)
        if let image = NSImage(data: data) {
            return Image(nsImage: image)
        }
        return Image(systemName: "rectangle.on.rectangle")
        #else
        if let image = UIImage(data: data) {
            return Image(uiImage: image)
        }
        return Image(systemName: "rectangle.on.rectangle")
        #endif
    }
}

private struct RemoteCanvasLayout {
    let scale: CGFloat
    let displayWidth: CGFloat
    let displayHeight: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
}

private struct BridgeWebLoginSheet: View {
    let login: BridgePromptLogin
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: (String) -> Void
    @State private var webView: WKWebView?
    @State private var errorMessage: String?
    @State private var statusMessage = "正在打开登录页..."
    @State private var isReadingCookies = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let url = URL(string: login.url) {
                    BridgeLoginWebView(url: url, webView: $webView)
                } else {
                    Text("登录地址无效")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack(spacing: 8) {
                    if isReadingCookies || isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                HStack(spacing: 12) {
                    Button("取消", role: .cancel) { onCancel() }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)

                    Button {
                        Task { await extractCookies() }
                    } label: {
                        HStack(spacing: 8) {
                            if isReadingCookies || isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isReadingCookies || isSubmitting ? "保存中" : "保存登录状态")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || isReadingCookies)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle(login.title ?? "扫码登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { onCancel() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isReadingCookies || isSubmitting ? "保存中" : "保存授权") {
                        Task { await extractCookies() }
                    }
                    .disabled(isSubmitting || isReadingCookies)
                }
            }
        }
        .task {
            await waitForLoginPage()
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 620)
        #endif
    }

    private func waitForLoginPage() async {
        while webView == nil && !Task.isCancelled {
            statusMessage = "正在打开登录页..."
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        statusMessage = "请在隔离登录页完成扫码后点击保存授权"
    }

    @MainActor
    private func extractCookies() async -> Bool {
        guard let webView else {
            statusMessage = "登录页还在初始化"
            errorMessage = "请稍等片刻再试"
            return false
        }
        isReadingCookies = true
        statusMessage = "正在检测登录状态..."
        errorMessage = nil
        defer {
            isReadingCookies = false
        }
        let domains = login.domains ?? []
        let selected = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { cookie in matches(cookie: cookie, domains: domains) }
        let cookieValue = selected
            .sorted { left, right in
                left.domain == right.domain ? left.name < right.name : left.domain < right.domain
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        guard !cookieValue.isEmpty else {
            statusMessage = "未检测到登录状态"
            errorMessage = "请先完成网页登录或扫码确认"
            return false
        }
        guard looksAuthenticated(cookies: selected) else {
            statusMessage = "等待扫码确认..."
            errorMessage = "请先完成网页登录或扫码确认"
            return false
        }
        isReadingCookies = true
        statusMessage = "已检测到登录状态，正在保存到 Android Bridge..."
        errorMessage = nil
        onSubmit(cookieValue)
        return true
    }

    private func matches(cookie: HTTPCookie, domains: [String]) -> Bool {
        guard !domains.isEmpty else { return true }
        let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { domain in
            let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cookieDomain == normalized || cookieDomain.hasSuffix("." + normalized)
        }
    }

    private func looksAuthenticated(cookies: [HTTPCookie]) -> Bool {
        let names = Set(cookies.map { $0.name.lowercased() })
        let url = login.url.lowercased()
        if url.contains("quark") || url.contains("uc.cn") {
            let authNames: Set<String> = ["__pus", "__puus"]
            return names.contains { authNames.contains($0) }
        }
        if url.contains("alipan") || url.contains("aliyundrive") {
            return names.contains { $0.contains("token") || $0.contains("login") || $0.contains("session") }
                || cookies.contains { $0.value.count > 80 }
        }
        if url.contains("baidu") {
            let authNames: Set<String> = ["bduss", "stoken", "baiduid", "panweb"]
            return names.contains { authNames.contains($0) }
        }
        return cookies.contains { $0.value.count > 40 }
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

#if os(iOS)
private struct BridgeLoginWebView: UIViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: makeBridgeLoginConfiguration())
        DispatchQueue.main.async { webView = view }
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
private struct BridgeLoginWebView: NSViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: makeBridgeLoginConfiguration())
        DispatchQueue.main.async { webView = view }
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

private func makeBridgeLoginConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return configuration
}

/// 全屏播放器
struct FullScreenPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    var onCloseRequested: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var requestedVideoOrientation: Bool?
    #endif
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                let shouldRotatePlayerContent = shouldRotatePlayerContent(in: proxy.size)

                PlayerView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: {
                        if let onCloseRequested {
                            onCloseRequested()
                        } else {
                            dismiss()
                        }
                    },
                    onVideoOrientationChanged: { isLandscape in
                        #if os(iOS)
                        applyFullScreenOrientation(for: isLandscape)
                        #endif
                    },
                    isFullscreen: true,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    systemController: systemController,
                    vlcController: vlcController
                )
                .frame(
                    width: shouldRotatePlayerContent ? proxy.size.height : proxy.size.width,
                    height: shouldRotatePlayerContent ? proxy.size.width : proxy.size.height
                )
                .rotationEffect(.degrees(shouldRotatePlayerContent ? 90 : 0))
                .background(Color.black)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(.easeInOut(duration: 0.25), value: shouldRotatePlayerContent)
            }
            .ignoresSafeArea()

            #if !os(iOS)
            VStack {
                HStack {
                    Button {
                        if let onCloseRequested {
                            onCloseRequested()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
            #endif
        }
        #if os(iOS)
        .statusBar(hidden: true)
        .onDisappear {
            requestedVideoOrientation = nil
        }
        #endif
    }

    #if os(iOS)
    private func applyFullScreenOrientation(for isLandscape: Bool?) {
        guard let isLandscape else { return }
        guard requestedVideoOrientation != isLandscape else { return }
        requestedVideoOrientation = isLandscape
    }

    #endif

    private func shouldRotatePlayerContent(in size: CGSize) -> Bool {
        #if os(iOS)
        requestedVideoOrientation == true && size.height > size.width
        #else
        false
        #endif
    }
}
