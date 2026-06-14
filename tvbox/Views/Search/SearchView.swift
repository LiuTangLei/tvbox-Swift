import SwiftUI

/// 搜索页 - 对应 Android 版 SearchActivity
struct SearchView: View {
    /// 搜索状态与结果管理。
    @StateObject private var viewModel = SearchViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var navigationPath = NavigationPath()
    @State private var searchWordTask: Task<Void, Never>?
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    #endif

    #if os(iOS)
    /// iOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // 搜索栏
                searchBar

                // 内容
                if viewModel.isSearching && viewModel.results.isEmpty {
                    Spacer()
                    ProgressView("搜索中...")
                        .tint(.orange)
                    Spacer()
                } else if !viewModel.results.isEmpty {
                    searchResults
                } else if viewModel.keyword.isEmpty || !viewModel.searchWords.isEmpty {
                    // 空输入展示历史/热搜；输入中展示联想词。
                    searchHistorySection
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            .navigationTitle("搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") {
                        isSearchFieldFocused = false
                    }
                }
            }
            #endif
        }
        .onAppear {
            consumePendingSearchKeyword()
            scheduleSearchWordRefresh(immediate: true)
        }
        .onDisappear {
            searchWordTask?.cancel()
            searchWordTask = nil
        }
        .onChange(of: appState.pendingSearchKeyword) { _, _ in
            consumePendingSearchKeyword()
        }
        .onChange(of: viewModel.keyword) { _, _ in
            viewModel.prepareForKeywordEditing()
            scheduleSearchWordRefresh()
        }
        #if os(iOS)
        .toolbar((navigationPath.isEmpty && !viewModel.isBrowsingFolder) ? .visible : .hidden, for: .tabBar)
        #endif
    }

    private func consumePendingSearchKeyword() {
        Task { @MainActor in
            guard let keyword = appState.consumePendingSearchKeyword() else { return }
            navigationPath = NavigationPath()
            dismissSearchKeyboard()
            await viewModel.search(keyword: keyword)
        }
    }

    private func scheduleSearchWordRefresh(immediate: Bool = false) {
        searchWordTask?.cancel()
        searchWordTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }
            await viewModel.loadSearchWords()
        }
    }

    // MARK: - 搜索栏

    /// 顶部搜索输入区。
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))

                TextField("搜索影片...", text: $viewModel.keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .onSubmit {
                        submitSearch()
                    }
                    #if os(iOS)
                    .autocapitalization(.none)
                    .focused($isSearchFieldFocused)
                    #endif

                if !viewModel.keyword.isEmpty {
                    Button {
                        withAnimation {
                            viewModel.clearCurrentSearch()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(colors: [.orange.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )

            Button {
                submitSearch()
            } label: {
                Text("搜索")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 搜索结果

    /// 搜索结果网格。
    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.isBrowsingFolder {
                    folderPathBar
                    folderResults
                } else {
                    sourceFilterBar

                    if viewModel.isShowingAllSources {
                        ForEach(viewModel.resultGroups) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Text(group.source.name)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text("\(group.videos.count)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.white.opacity(0.72))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.white.opacity(0.1)))
                                }
                                resultGrid(group.videos)
                            }
                        }
                    } else {
                        resultGrid(viewModel.visibleResults)
                    }

                    if viewModel.isSearching {
                        searchingMoreIndicator
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }

    private var searchingMoreIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
            Text("继续搜索更多来源...")
                .font(.footnote.weight(.medium))
                .foregroundColor(.white.opacity(0.66))
            if viewModel.completedSourceCount > 0 {
                Text("\(viewModel.completedSourceCount) 个来源已有结果")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var sourceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceFilterButton(
                    title: "全部",
                    count: viewModel.results.count,
                    selected: viewModel.isShowingAllSources
                ) {
                    viewModel.showAllSources()
                }

                ForEach(viewModel.resultGroups) { group in
                    sourceFilterButton(
                        title: group.source.name,
                        count: group.videos.count,
                        selected: viewModel.selectedSourceKey == group.source.key
                    ) {
                        viewModel.showSource(group.source.key)
                    }
                }
            }
        }
    }

    private func sourceFilterButton(
        title: String,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(selected ? .black.opacity(0.7) : .white.opacity(0.72))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(selected ? .black : .white.opacity(0.86))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(selected ? Color.orange : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func resultGrid(_ videos: [Movie.Video]) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(videos) { video in
                if video.isFolder {
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
                } else {
                    NavigationLink(value: video) {
                        VodCardView(video: video)
                    }
                    #if os(iOS)
                    .buttonStyle(VodCardPressStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
    }

    private var folderPathBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.closeFolderLevel()
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
    }

    @ViewBuilder
    private var folderResults: some View {
        if viewModel.isFolderLoading && viewModel.folderVideos.isEmpty {
            HStack {
                Spacer()
                ProgressView("加载目录...")
                    .tint(.orange)
                    .foregroundColor(.white.opacity(0.72))
                Spacer()
            }
            .padding(.vertical, 48)
        } else if let error = viewModel.folderErrorMessage, viewModel.folderVideos.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else if viewModel.folderVideos.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text("目录为空")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.folderVideos) { video in
                    folderRowLink(video)
                        .onAppear {
                            Task { await viewModel.loadMoreFolderIfNeeded(currentItem: video) }
                        }
                }
            }

            if viewModel.isFolderLoading || viewModel.currentFolderHasMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.orange)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func folderRowLink(_ video: Movie.Video) -> some View {
        if video.isFolder {
            Button {
                Task { await viewModel.openFolder(video) }
            } label: {
                folderRow(video)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: video) {
                folderRow(video)
            }
            .buttonStyle(.plain)
        }
    }

    private func folderRow(_ video: Movie.Video) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(request: ImageRequest.poster(from: video.pic)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Image(systemName: video.isFolder ? "folder.fill" : "play.rectangle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(video.isFolder ? .orange : .white.opacity(0.5))
                    )
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                if !video.note.isEmpty {
                    Text(video.note)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: video.isFolder ? "folder" : "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(video.isFolder ? .orange : .white.opacity(0.35))
                .frame(width: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - 搜索历史

    /// 搜索历史区域，支持复用历史关键词与一键清空。
    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.searchHistory.isEmpty {
                HStack {
                    Text("搜索历史")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        viewModel.clearHistory()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("清空")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                FlowLayout(spacing: 8) {
                    ForEach(viewModel.searchHistory, id: \.self) { keyword in
                        Button {
                            submitSearch(keyword: keyword)
                        } label: {
                            Text(keyword)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            if !viewModel.searchWords.isEmpty {
                HStack {
                    Text(viewModel.searchWordTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, viewModel.searchHistory.isEmpty ? 16 : 6)

                FlowLayout(spacing: 8) {
                    ForEach(viewModel.searchWords, id: \.self) { word in
                        searchWordButton(word)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer()
        }
    }

    private func searchWordButton(_ word: String) -> some View {
        Button {
            submitSearch(keyword: word)
        } label: {
            Text(word)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.86))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.1))
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    private func submitSearch(keyword: String? = nil) {
        if let keyword {
            viewModel.keyword = keyword
        }
        dismissSearchKeyboard()
        Task { await viewModel.search() }
    }

    private func dismissSearchKeyboard() {
        #if os(iOS)
        isSearchFieldFocused = false
        #endif
    }
}

/// 流式布局
struct FlowLayout: Layout {
    /// 子项间距。
    var spacing: CGFloat = 8

    /// 计算整体尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return result.size
    }

    /// 按计算结果放置子视图。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    /// 核心排版算法：按最大宽度逐个放置，超宽后自动换行。
    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
