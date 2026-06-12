import SwiftUI

/// 设置页 - 对应 Android 版 SettingActivity + ModelSettingFragment
struct SettingsView: View {
    enum ApiInputType: String, Identifiable {
        case vod
        case live
        case bridge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .vod: return "点播接口地址"
            case .live: return "直播接口地址"
            case .bridge: return "Bridge Server 地址"
            }
        }

        var placeholder: String {
            switch self {
            case .vod: return "请输入点播接口地址"
            case .live: return "请输入直播接口地址（可留空跟随点播）"
            case .bridge: return "例如 https://tva.yesican.top 或 http://192.168.1.10:9978"
            }
        }
    }

    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var activeApiInputType: ApiInputType?
    @State private var showAbout = false
    @State private var sourceSearchText = ""
    @State private var showingPicker: PickerType = .none
    @State private var showingUserAgentInput = false
    @State private var userAgentDraft = ""

    enum PickerType {
        case none
        case vodPlayer
        case livePlayer
        case liveSource
        case decode
        case videoScale
        case vlcBuffer
        case playTimeStep
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // API 配置
                    SectionCard(title: "数据源") {
                        SettingsRow(
                            icon: "film",
                            title: "点播接口地址",
                            value: viewModel.vodApiUrl.isEmpty ? "未配置" : viewModel.vodApiUrl
                        ) {
                            activeApiInputType = .vod
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(
                            icon: "tv",
                            title: "直播接口地址",
                            value: viewModel.liveApiUrl.isEmpty ? "跟随点播接口" : viewModel.liveApiUrl
                        ) {
                            activeApiInputType = .live
                        }
                        if apiConfig.liveSourceOptions.count > 1 {
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(
                                icon: "dot.radiowaves.left.and.right",
                                title: "主页直播源",
                                value: apiConfig.homeLiveSourceOption?.name ?? ""
                            ) {
                                showingPicker = .liveSource
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        if !apiConfig.sourceBeanList.isEmpty {
                            NavigationLink {
                                sourcePickerView
                            } label: {
                                SettingsRow(icon: "server.rack", title: "主页数据源", value: apiConfig.homeSourceBean?.name ?? "", action: nil)
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        HStack(spacing: 16) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 16))
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            Text("启用 Type=3 Bridge")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { viewModel.bridgeEnabled },
                                set: { viewModel.setBridgeEnabled($0) }
                            ))
                            .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(
                            icon: "network",
                            title: "Bridge Server",
                            value: viewModel.bridgeServerSummary
                        ) {
                            activeApiInputType = .bridge
                        }
                    }

                    // 播放设置
                    SectionCard(title: "播放设置") {
                        SettingsRow(icon: "play.rectangle", title: "点播播放器", value: viewModel.vodPlayerEngine.title) {
                            if viewModel.playerEngineOptions.count > 1 {
                                showingPicker = .vodPlayer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "dot.radiowaves.left.and.right", title: "直播播放器", value: viewModel.livePlayerEngine.title) {
                            if viewModel.playerEngineOptions.count > 1 {
                                showingPicker = .livePlayer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "cpu", title: "视频解码", value: viewModel.decodeMode.title) {
                            showingPicker = .decode
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "arrow.up.left.and.arrow.down.right", title: "画面缩放", value: viewModel.videoScaleMode.title) {
                            showingPicker = .videoScale
                        }
                        if PlayerEngine.isVLCAvailable {
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "externaldrive.badge.wifi", title: "VLC缓冲", value: viewModel.vlcBufferMode.title) {
                                showingPicker = .vlcBuffer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "forward", title: "快进步长", value: "\(viewModel.playTimeStep)秒") {
                            showingPicker = .playTimeStep
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "network", title: "播放UA", value: viewModel.playerUserAgentSummary) {
                            userAgentDraft = viewModel.playerUserAgent
                            showingUserAgentInput = true
                        }
                    }

                    // 功能
                    SectionCard(title: "功能") {
                        HStack(spacing: 16) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 16))
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            Text("无痕模式")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { viewModel.incognitoMode },
                                set: { viewModel.setIncognitoMode($0) }
                            ))
                            .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        Divider().background(Color.white.opacity(0.1))
                        NavigationLink {
                            HistoryView()
                        } label: {
                            SettingsRow(icon: "clock", title: "播放历史", value: "", action: nil)
                        }
                        Divider().background(Color.white.opacity(0.1))
                        NavigationLink {
                            FavoritesView()
                        } label: {
                            SettingsRow(icon: "heart", title: "我的收藏", value: "", action: nil)
                        }
                    }

                    // 缓存
                    SectionCard(title: "缓存") {
                        SettingsRow(icon: "trash", title: "清除缓存", value: viewModel.cacheSizeString) {
                            viewModel.clearCache(context: modelContext)
                        }
                    }

                    // 关于
                    SectionCard(title: "关于") {
                        SettingsRow(icon: "info.circle", title: "版本", value: "1.0.0", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "globe", title: "站点数量", value: "\(apiConfig.sourceBeanList.count)", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "wand.and.stars", title: "解析数量", value: "\(apiConfig.parseBeanList.count)", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "tv", title: "直播分组", value: "\(apiConfig.liveChannelGroupList.count)", action: nil)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(AppTheme.primaryGradient.ignoresSafeArea())
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .sheet(item: $activeApiInputType) { inputType in
                apiInputSheet(for: inputType)
            }
            .sheet(isPresented: $showingUserAgentInput) {
                userAgentInputSheet
            }
            .alert("缓存", isPresented: cacheClearAlertBinding) {
                Button("好", role: .cancel) {
                    viewModel.cacheClearMessage = nil
                }
            } message: {
                Text(viewModel.cacheClearMessage ?? "")
            }
        }
        .overlay(pickerOverlay)
    }

    private var cacheClearAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.cacheClearMessage != nil },
            set: { if !$0 { viewModel.cacheClearMessage = nil } }
        )
    }

    // MARK: - 选择器 Overlay

    @ViewBuilder
    private var pickerOverlay: some View {
        switch showingPicker {
        case .vodPlayer:
            SelectionModal(
                title: "选择点播播放器",
                icon: "play.rectangle.fill",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.vodPlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setVodPlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .livePlayer:
            SelectionModal(
                title: "选择直播播放器",
                icon: "dot.radiowaves.left.and.right",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.livePlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setLivePlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .liveSource:
            SelectionModal(
                title: "选择直播源",
                icon: "tv.fill",
                items: apiConfig.liveSourceOptions,
                selectedItem: apiConfig.homeLiveSourceOption,
                itemTitle: { $0.name },
                onSelect: { option in
                    apiConfig.setHomeLiveSource(option)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .decode:
            SelectionModal(
                title: "视频解码模式",
                icon: "cpu.fill",
                items: viewModel.decodeModeOptions,
                selectedItem: viewModel.decodeMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setDecodeMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .videoScale:
            SelectionModal(
                title: "画面缩放模式",
                icon: "arrow.up.left.and.arrow.down.right",
                items: viewModel.videoScaleModeOptions,
                selectedItem: viewModel.videoScaleMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setVideoScaleMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .vlcBuffer:
            SelectionModal(
                title: "VLC 缓冲策略",
                icon: "externaldrive.fill",
                items: viewModel.vlcBufferModeOptions,
                selectedItem: viewModel.vlcBufferMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setVLCBufferMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .playTimeStep:
            SelectionModal(
                title: "快进步长",
                icon: "forward.fill",
                items: viewModel.playTimeStepOptions,
                selectedItem: viewModel.playTimeStep,
                itemTitle: { "\($0) 秒" },
                onSelect: { step in
                    viewModel.setPlayTimeStep(step)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .none:
            EmptyView()
        }
    }

    // MARK: - API 输入弹窗

    private func apiInputSheet(for inputType: ApiInputType) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                    TextField(inputType.placeholder, text: currentApiBinding(for: inputType))
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)

                // 粘贴按钮
                HStack {
                    Button {
                        if let text = readPasteboardText() {
                            currentApiBinding(for: inputType).wrappedValue = text
                        }
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                    }

                    Spacer()
                }

                // 历史记录
                if !history(for: inputType).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("历史记录")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(history(for: inputType), id: \.self) { url in
                            HStack {
                                Button {
                                    currentApiBinding(for: inputType).wrappedValue = url
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                            .font(.caption)
                                        Text(url)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button {
                                    viewModel.removeAddressHistory(url, kind: historyKind(for: inputType))
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }

                if let error = viewModel.configError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .padding()
            .navigationTitle(inputType.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { activeApiInputType = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if inputType == .bridge {
                                await viewModel.saveBridgeSettingsAndTest()
                                activeApiInputType = nil
                            } else {
                                await viewModel.loadConfig()
                                if viewModel.configSuccess {
                                    appState.applyLoadedConfigState()
                                    activeApiInputType = nil
                                }
                            }
                        }
                    } label: {
                        if viewModel.isLoadingConfig || viewModel.isTestingBridge {
                            ProgressView()
                        } else {
                            Text("确认")
                        }
                    }
                    .disabled(
                        viewModel.isLoadingConfig
                        || viewModel.isTestingBridge
                        || (inputType != .bridge && viewModel.vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
        }
        .overlay(multiRepoSelectionOverlay)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var userAgentInputSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $userAgentDraft)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                Button {
                    userAgentDraft = PlaybackHTTPHeaders.defaultUserAgent
                } label: {
                    Label("填入默认 UA", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("播放 UA")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingUserAgentInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.setPlayerUserAgent(userAgentDraft)
                        showingUserAgentInput = false
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        if let pending = viewModel.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await viewModel.selectPendingMultiRepoOption(option)
                        if viewModel.configSuccess {
                            appState.applyLoadedConfigState()
                            activeApiInputType = nil
                        }
                    }
                },
                onCancel: {
                    viewModel.cancelPendingMultiRepoSelection()
                }
            )
        }
    }

    private func currentApiBinding(for inputType: ApiInputType) -> Binding<String> {
        switch inputType {
        case .vod:
            return $viewModel.vodApiUrl
        case .live:
            return $viewModel.liveApiUrl
        case .bridge:
            return $viewModel.bridgeServerUrl
        }
    }

    private func historyKind(for inputType: ApiInputType) -> SettingsViewModel.AddressHistoryKind {
        switch inputType {
        case .bridge:
            return .bridge
        case .vod, .live:
            return .config
        }
    }

    private func history(for inputType: ApiInputType) -> [String] {
        viewModel.addressHistory(for: historyKind(for: inputType))
    }

    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    // MARK: - 源选择

    private var filteredSources: [SourceBean] {
        let sources = apiConfig.sourceBeanList
        if sourceSearchText.isEmpty {
            return sources
        } else {
            return sources.filter { $0.name.localizedCaseInsensitiveContains(sourceSearchText) || $0.api.localizedCaseInsensitiveContains(sourceSearchText) }
        }
    }

    private var sourcePickerView: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索数据源", text: $sourceSearchText)
                    .textFieldStyle(.plain)
                if !sourceSearchText.isEmpty {
                    Button(action: { sourceSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredSources) { source in
                        Button {
                            guard source.isAvailableForPlayback else { return }
                            apiConfig.setHomeSource(source)
                            appState.currentSourceKey = source.key
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(source.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(source.isAvailableForPlayback ? .white : .white.opacity(0.5))

                                        // 类型标签
                                        Text(source.typeDescription)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(source.isAvailableForPlayback ? .orange : .gray)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(
                                                    source.isAvailableForPlayback ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2)
                                                )
                                            )

                                        if source.requiresBridge && BridgeClient.shared.isEnabled {
                                            Text("Bridge")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.green.opacity(0.9))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                        } else if !source.isAvailableForPlayback {
                                            Text("暂不支持")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.red.opacity(0.8))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill(Color.red.opacity(0.15)))
                                        }
                                    }

                                    Text(source.api)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }

                                Spacer()

                                HStack(spacing: 12) {
                                    if source.isSearchable {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.green.opacity(0.8))
                                    }

                                    if source.key == apiConfig.homeSourceBean?.key {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.orange)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                            .frame(width: 20, height: 20)
                                    }
                                }
                            }
                            .padding(16)
                            .glassCard(cornerRadius: 16)
                            .opacity(source.isAvailableForPlayback ? 1 : 0.58)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        source.key == apiConfig.homeSourceBean?.key ? Color.orange.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!source.isAvailableForPlayback)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(AppTheme.primaryGradient.ignoresSafeArea())
        .navigationTitle("选择数据源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 辅助组件

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.6))
                .padding(.leading, 8)

            VStack(spacing: 0) {
                content()
            }
            .glassCard(cornerRadius: 16)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.orange)
                .frame(width: 24)

            Text(title)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
