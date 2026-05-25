import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?

    // 网格布局
    #if os(iOS)
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部栏
                headerBar

                // 分类标签栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }

                if viewModel.isInFolder {
                    folderPathBar
                }

                if !viewModel.activeFilterGroups.isEmpty {
                    filterBar
                }

                // 内容区
                contentArea
            }
            .background(AppTheme.primaryGradient)
        }
        .task {
            await viewModel.loadSorts()
            if let first = viewModel.sorts.first {
                viewModel.selectSort(first)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvboxBridgeAvailabilityDidChange)) { _ in
            let newSourceKey = apiConfig.homeSourceBean?.key ?? ""
            if appState.currentSourceKey == newSourceKey {
                Task { await viewModel.resetAndReload() }
            } else {
                appState.currentSourceKey = newSourceKey
            }
        }
        .onChange(of: appState.currentSourceKey) { oldValue, newValue in
            guard oldValue != newValue else { return }
            Task { await viewModel.resetAndReload() }
        }
    }

    // MARK: - 顶部栏（源选择器）

    private var headerBar: some View {
        HStack(spacing: 12) {
            // 源切换按钮
            Menu {
                ForEach(apiConfig.playableSourceBeanList) { source in
                    Button {
                        apiConfig.setHomeSource(source)
                        appState.currentSourceKey = source.key
                    } label: {
                        HStack {
                            Text(source.name)
                            if source.key == apiConfig.homeSourceBean?.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(apiConfig.homeSourceBean?.name ?? "TVBox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var folderPathBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await viewModel.closeFolderLevel() }
            } label: {
                Label("上一级", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Text(viewModel.folderPathTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.activeFilterGroups, id: \.key) { filter in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text(filter.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(minWidth: 42, alignment: .leading)

                        ForEach(filter.values, id: \.v) { value in
                            let selected = viewModel.isFilterValueSelected(filter, value: value)
                            Button {
                                viewModel.selectFilter(filter, value: value)
                            } label: {
                                Text(value.n)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .foregroundColor(selected ? .white : .white.opacity(0.68))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(selected ? Color.orange.opacity(0.78) : Color.white.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - 分类标签栏

    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(viewModel.sorts) { sort in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.selectSort(sort)
                            }
                            categoryScrollAnchorId = sort.id
                            scrollCategoryBar(to: sort.id, proxy: proxy)
                        } label: {
                            VStack(spacing: 6) {
                                Text(sort.name)
                                    .font(.system(size: 14, weight: viewModel.selectedSort?.id == sort.id ? .bold : .regular))
                                    .foregroundColor(viewModel.selectedSort?.id == sort.id ? .white : .white.opacity(0.6))

                                // 底部指示条
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.orange)
                                    .frame(width: 20, height: 3)
                                    .opacity(viewModel.selectedSort?.id == sort.id ? 1 : 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .id(sort.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.sorts.map(\.id)) { oldValue, newValue in
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.selectedSort?.id) { oldId, newId in
                guard let newId else { return }
                categoryScrollAnchorId = newId
                scrollCategoryBar(to: newId, proxy: proxy)
            }
        }
        .padding(.bottom, 4)
    }

    private func categoryIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        return viewModel.sorts.firstIndex(where: { $0.id == id })
    }

    private func syncCategoryScrollAnchorIfNeeded() {
        guard !viewModel.sorts.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }

        if let selectedId = viewModel.selectedSort?.id,
           viewModel.sorts.contains(where: { $0.id == selectedId }) {
            categoryScrollAnchorId = selectedId
            return
        }

        if let anchorId = categoryScrollAnchorId,
           viewModel.sorts.contains(where: { $0.id == anchorId }) {
            return
        }

        categoryScrollAnchorId = viewModel.sorts.first?.id
    }

    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: - 内容区

    private var contentArea: some View {
        Group {
            if viewModel.isLoading && viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.orange)
                    Text("加载中...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                    Spacer()
                }
            } else if let error = viewModel.errorMessage, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    // 如果是不支持的源类型，显示类型信息
                    if let source = apiConfig.homeSourceBean, !source.isAvailableForPlayback {
                        Text("当前源类型: \(source.typeDescription)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
            } else {
                let videos = viewModel.displayVideos

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(videos) { video in
                            if viewModel.isBridgeActionCard(video) {
                                Button {
                                    Task { await viewModel.performAction(for: video) }
                                } label: {
                                    VodCardView(video: video)
                                }
                                #if os(iOS)
                                .buttonStyle(VodCardPressStyle())
                                #else
                                .buttonStyle(.plain)
                                #endif
                                .disabled(viewModel.isPerformingAction)
                                .onAppear {
                                    Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                                }
                            } else if video.isFolder {
                                Button {
                                    Task { await viewModel.openFolder(video) }
                                } label: {
                                    VodCardView(video: video)
                                }
                                #if os(iOS)
                                .buttonStyle(VodCardPressStyle())
                                #else
                                .buttonStyle(.plain)
                                #endif
                                .onAppear {
                                    Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                                }
                            } else if viewModel.shouldOpenSearch(for: video) {
                                Button {
                                    appState.openSearch(keyword: video.name)
                                } label: {
                                    VodCardView(video: video)
                                }
                                #if os(iOS)
                                .buttonStyle(VodCardPressStyle())
                                #else
                                .buttonStyle(.plain)
                                #endif
                                .onAppear {
                                    Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                                }
                            } else {
                                NavigationLink(value: video) {
                                    VodCardView(video: video)
                                }
                                #if os(iOS)
                                .buttonStyle(VodCardPressStyle())
                                #else
                                .buttonStyle(.plain)
                                #endif
                                .onAppear {
                                    Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    // 加载更多
                    if viewModel.isPagedListing && viewModel.hasMore {
                        ProgressView()
                            .padding()
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
        .confirmationDialog("选择登录方式", isPresented: $viewModel.isBridgeActionPromptPresented, titleVisibility: .visible) {
            ForEach(viewModel.bridgeActionPrompts) { prompt in
                Button(prompt.title) {
                    viewModel.selectBridgeActionPrompt(prompt)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("登录状态只保存到 Android Bridge")
        }
        .sheet(
            isPresented: $viewModel.isBridgeTokenPromptPresented,
            onDismiss: { viewModel.dismissBridgeTokenPromptPresentation() }
        ) {
            if let prompt = viewModel.bridgeTokenPrompt {
                BridgeTokenPromptSheet(
                    prompt: prompt,
                    isSubmitting: viewModel.isSubmittingBridgeToken,
                    errorMessage: viewModel.bridgeTokenErrorMessage,
                    submitTitle: "保存到 Android",
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
            onDismiss: { viewModel.dismissActionBridgeJarUiPresentation() }
        ) {
            if let response = viewModel.bridgeJarUiResponse {
                BridgeJarUiSheet(
                    title: viewModel.bridgeJarUiTitle,
                    initialResponse: response,
                    onPoll: {
                        try await viewModel.pollActionBridgeJarUi()
                    },
                    onAction: { action in
                        try await viewModel.sendActionBridgeJarUiAction(action)
                    },
                    onCancel: viewModel.cancelActionBridgeJarUi,
                    onComplete: {
                        await viewModel.closeActionBridgeJarUi()
                    }
                )
            }
        }
        .alert("提示", isPresented: actionMessageBinding) {
            Button("好", role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    private var actionMessageBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.actionMessage != nil
                    && !viewModel.isBridgeJarUiPresented
                    && viewModel.bridgeJarUiResponse == nil
            },
            set: { if !$0 { viewModel.actionMessage = nil } }
        )
    }
}
