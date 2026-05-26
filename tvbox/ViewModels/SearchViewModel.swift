import Foundation
import SwiftUI

/// 搜索结果中的目录浏览层级，对齐 Android 搜索结果打开 FolderActivity 的行为。
struct SearchFolderLevel: Identifiable {
    let id = UUID()
    let source: SourceBean
    let sort: MovieSort.SortData
    var videos: [Movie.Video]
    var page: Int
    var pageCount: Int?
    var hasMore: Bool
}

/// 搜索 ViewModel
@MainActor
class SearchViewModel: ObservableObject {
    /// 搜索关键词输入。
    @Published var keyword: String = ""
    /// 当前结果列表。
    @Published var results: [Movie.Video] = []
    /// 多源搜索结果分组，对应 Android 搜索页的站点筛选。
    @Published var resultGroups: [SearchResultGroup] = []
    /// 当前选中的站点；nil 表示查看全部来源。
    @Published var selectedSourceKey: String?
    /// 搜索加载状态，用于控制进度指示器。
    @Published var isSearching = false
    /// 本地搜索历史（最近在前）。
    @Published var searchHistory: [String] = []
    /// 搜索失败或空结果提示。
    @Published var errorMessage: String?
    /// 已返回结果的源数量。
    @Published var completedSourceCount = 0
    /// folder 类型的搜索结果进入后按来源继续浏览分类列表。
    @Published var folderStack: [SearchFolderLevel] = []
    @Published var isFolderLoading = false
    @Published var folderErrorMessage: String?

    /// 源数据服务（负责多源并发搜索）。
    private let sourceService = SourceService.shared
    /// 搜索请求序号（用于丢弃过期异步结果）。
    private var latestSearchRequestId: UUID = UUID()

    /// 初始化时同步加载本地历史记录，确保搜索页首次渲染即可展示。
    init() {
        loadSearchHistory()
    }

    var visibleResults: [Movie.Video] {
        guard let selectedSourceKey else { return results }
        return resultGroups.first(where: { $0.source.key == selectedSourceKey })?.videos ?? []
    }

    var isShowingAllSources: Bool {
        selectedSourceKey == nil
    }

    var isBrowsingFolder: Bool {
        !folderStack.isEmpty
    }

    var folderVideos: [Movie.Video] {
        folderStack.last?.videos ?? []
    }

    var folderPathTitle: String {
        folderStack.map { $0.sort.name }.joined(separator: " / ")
    }

    var currentFolderHasMore: Bool {
        folderStack.last?.hasMore ?? false
    }

    /// 执行搜索
    func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestId = UUID()
        latestSearchRequestId = requestId

        isSearching = true
        completedSourceCount = 0
        errorMessage = nil
        results = []
        resultGroups = []
        selectedSourceKey = nil
        resetFolderBrowsing()

        // 搜索一旦触发就先落历史，保持行为与移动端常见搜索体验一致。
        addToHistory(trimmed)

        // 走多源并发搜索，每个源完成后先追加到界面，避免一直空等最终结果。
        let groups = await sourceService.searchGroups(keyword: trimmed) { [weak self] group in
            await MainActor.run {
                guard let self, requestId == self.latestSearchRequestId else { return }
                self.appendSearchGroup(group)
            }
        }
        guard requestId == latestSearchRequestId else { return }
        self.resultGroups = groups
        self.results = groups.flatMap(\.videos)

        if results.isEmpty {
            errorMessage = "未找到相关内容"
        }

        isSearching = false
    }

    func search(keyword newKeyword: String) async {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyword = trimmed
        await search()
    }

    func clearCurrentSearch() {
        latestSearchRequestId = UUID()
        keyword = ""
        results = []
        resultGroups = []
        selectedSourceKey = nil
        completedSourceCount = 0
        isSearching = false
        errorMessage = nil
        resetFolderBrowsing()
    }

    /// 在指定源搜索
    func searchInSource(_ source: SourceBean) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestId = UUID()
        latestSearchRequestId = requestId

        isSearching = true
        completedSourceCount = 0
        errorMessage = nil
        resultGroups = []
        selectedSourceKey = source.key
        resetFolderBrowsing()

        do {
            let videos = try await sourceService.search(sourceBean: source, keyword: trimmed)
            guard requestId == latestSearchRequestId else { return }
            resultGroups = [SearchResultGroup(source: source, videos: videos)]
            self.results = videos
            completedSourceCount = videos.isEmpty ? 0 : 1
        } catch {
            guard requestId == latestSearchRequestId else { return }
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }

    // MARK: - 搜索历史

    /// 从本地读取历史。
    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: HawkConfig.SEARCH_HISTORY) ?? []
    }

    /// 新增历史项并去重，最多保留 20 条。
    private func addToHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }

    /// 清空历史。
    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: HawkConfig.SEARCH_HISTORY)
    }

    /// 删除单条历史。
    func removeFromHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }

    func showAllSources() {
        selectedSourceKey = nil
    }

    func showSource(_ sourceKey: String) {
        selectedSourceKey = sourceKey
    }

    private func appendSearchGroup(_ group: SearchResultGroup) {
        guard !group.videos.isEmpty else { return }
        if let index = resultGroups.firstIndex(where: { $0.source.key == group.source.key }) {
            resultGroups[index] = group
        } else {
            resultGroups.append(group)
        }
        completedSourceCount = resultGroups.count
        results = resultGroups.flatMap(\.videos)
    }

    func openFolder(_ video: Movie.Video) async {
        guard video.isFolder else { return }
        guard let source = source(for: video) else {
            folderErrorMessage = "找不到目录所属来源"
            return
        }
        guard !isFolderLoading else { return }

        let folderSort = MovieSort.SortData(id: video.id, name: video.name, flag: "1")
        let level = SearchFolderLevel(
            source: source,
            sort: folderSort,
            videos: [],
            page: 0,
            pageCount: nil,
            hasMore: true
        )
        folderStack.append(level)
        isFolderLoading = true
        folderErrorMessage = nil
        defer { isFolderLoading = false }

        do {
            let page = try await sourceService.getListPage(sourceBean: source, sortData: folderSort, page: 1)
            guard folderStack.last?.id == level.id else { return }
            folderStack[folderStack.count - 1] = SearchFolderLevel(
                source: source,
                sort: folderSort,
                videos: page.videos,
                page: page.page,
                pageCount: page.pageCount,
                hasMore: hasMore(after: page)
            )
        } catch {
            guard folderStack.last?.id == level.id else { return }
            folderErrorMessage = error.localizedDescription
        }
    }

    func closeFolderLevel() {
        guard !folderStack.isEmpty else { return }
        folderStack.removeLast()
        folderErrorMessage = nil
    }

    func loadMoreFolderIfNeeded(currentItem: Movie.Video) async {
        guard !isFolderLoading, var folder = folderStack.last else { return }
        guard folder.hasMore, folder.videos.last?.id == currentItem.id else { return }

        let nextPage = folder.page + 1
        isFolderLoading = true
        defer { isFolderLoading = false }

        do {
            let page = try await sourceService.getListPage(
                sourceBean: folder.source,
                sortData: folder.sort,
                page: nextPage
            )
            guard folderStack.last?.id == folder.id else { return }
            folder.videos.append(contentsOf: page.videos)
            folder.page = page.page
            folder.pageCount = page.pageCount
            folder.hasMore = hasMore(after: page)
            folderStack[folderStack.count - 1] = folder
        } catch {
            guard folderStack.last?.id == folder.id else { return }
            folderErrorMessage = error.localizedDescription
        }
    }

    func resetFolderBrowsing() {
        folderStack = []
        folderErrorMessage = nil
        isFolderLoading = false
    }

    private func source(for video: Movie.Video) -> SourceBean? {
        if let current = folderStack.last?.source {
            return current
        }
        return resultGroups.first(where: { $0.source.key == video.sourceKey })?.source
    }

    private func hasMore(after page: VideoPage) -> Bool {
        if let pageCount = page.pageCount { return page.page < pageCount }
        return !page.videos.isEmpty
    }
}
