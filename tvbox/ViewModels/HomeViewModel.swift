import Foundation
import SwiftUI
import Combine

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    /// 当前分类筛选参数。
    @Published var selectedFilters: [String: String] = [:]
    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（分页加载）。
    @Published var categoryVideos: [Movie.Video] = []
    /// 页面加载状态（分类加载与分页共用）。
    @Published var isLoading = false
    /// 当前分类的分页页码。
    @Published var currentPage = 1
    /// 是否还有下一页。
    @Published var hasMore = true
    /// 错误提示文案。
    @Published var errorMessage: String?
    @Published var actionMessage: String?
    @Published var isPerformingAction = false
    @Published var bridgeActionPrompts: [BridgeTokenPrompt] = []
    @Published var isBridgeActionPromptPresented = false
    @Published var bridgeTokenPrompt: BridgeTokenPrompt?
    @Published var isBridgeTokenPromptPresented = false
    @Published var isSubmittingBridgeToken = false
    @Published var bridgeTokenErrorMessage: String?
    @Published var bridgeJarUiResponse: BridgeJarUiResponse?
    @Published var bridgeJarUiTitle = "Android Jar 界面"
    @Published var isBridgeJarUiPresented = false

    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    private let bridge = BridgeClient.shared
    private var bridgeTokenSource: SourceBean?
    private var bridgeJarUiSource: SourceBean?
    @Published private var folderStack: [FolderLevel] = []
    private var loadedSourceKey = ""
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?

    private struct FolderLevel: Identifiable, Hashable {
        let sort: MovieSort.SortData
        let filters: [String: String]

        var id: String { sort.id }
    }

    var isInFolder: Bool { !folderStack.isEmpty }

    var isPagedListing: Bool {
        if isInFolder { return true }
        return selectedSort?.id != "home"
    }

    var displayVideos: [Movie.Video] {
        if isPagedListing { return categoryVideos }
        return homeVideos
    }

    var activeFilterGroups: [MovieSort.SortFilter] {
        selectedSort?.filters ?? []
    }

    var folderPathTitle: String {
        folderStack.map { $0.sort.name }.joined(separator: " / ")
    }

    init() {
        setupNetworkRestoredAutoRetry()
    }

    /// 加载分类列表
    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        if loadedSourceKey != source.key {
            loadedSourceKey = source.key
            selectedSort = nil
            selectedFilters = [:]
            folderStack = []
            categoryVideos = []
            homeVideos = []
            currentPage = 1
            hasMore = true
        }
        isLoading = true
        errorMessage = nil

        do {
            let result = try await sourceService.getSort(sourceBean: source)

            // 插入本地"推荐"分类，保持 UI 与 Android 版本习惯一致。
            var allSorts = [MovieSort.SortData.home()]
            allSorts.append(contentsOf: result.sorts)

            self.sorts = allSorts
            self.homeVideos = result.homeVideos
            lastLoadFailedDueToNetwork = false

            if let selectedSort, let matched = allSorts.first(where: { $0.id == selectedSort.id }) {
                self.selectedSort = matched
            } else if let first = allSorts.first {
                selectedSort = first
                selectedFilters = defaultFilters(for: first)
            }
        } catch {
            errorMessage = error.localizedDescription
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }

        isLoading = false
    }

    /// 网络恢复时，若上次因网络错误导致首页为空，自动重新加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh()
                }
            }
    }

    /// 选择分类
    func selectSort(_ sort: MovieSort.SortData) {
        // 切分类时先重置分页状态，避免旧分类残留数据闪烁。
        selectedSort = sort
        selectedFilters = defaultFilters(for: sort)
        folderStack = []
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true

        if sort.id == "home" {
            return
        } else {
            Task {
                await loadCategoryVideos(page: 1, sort: sort, filters: selectedFilters)
            }
        }
    }

    func selectFilter(_ filter: MovieSort.SortFilter, value: MovieSort.SortFilter.SortFilterValue) {
        guard selectedSort != nil else { return }
        var filters = selectedFilters
        let trimmedValue = value.v.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            filters.removeValue(forKey: filter.key)
        } else {
            filters[filter.key] = trimmedValue
        }
        guard filters != selectedFilters else { return }
        selectedFilters = filters
        if !folderStack.isEmpty {
            folderStack = folderStack.map { FolderLevel(sort: $0.sort, filters: filters) }
        }
        categoryVideos = []
        currentPage = 1
        hasMore = true
        errorMessage = nil
        guard let sort = currentListingSort, sort.id != "home" else { return }
        Task { await loadCategoryVideos(page: 1, sort: sort, filters: filters) }
    }

    func isFilterValueSelected(_ filter: MovieSort.SortFilter, value: MovieSort.SortFilter.SortFilterValue) -> Bool {
        let selectedValue = selectedFilters[filter.key] ?? ""
        return selectedValue == value.v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openFolder(_ video: Movie.Video) async {
        guard video.isFolder else { return }
        let inheritedFilters = currentRequestFilters
        let folderSort = MovieSort.SortData(id: video.id, name: video.name, flag: "1", filters: activeFilterGroups)
        folderStack.append(FolderLevel(sort: folderSort, filters: inheritedFilters))
        categoryVideos = []
        currentPage = 1
        hasMore = true
        errorMessage = nil
        await loadCategoryVideos(page: 1, sort: folderSort, filters: inheritedFilters)
    }

    func closeFolderLevel() async {
        guard !folderStack.isEmpty else { return }
        folderStack.removeLast()
        categoryVideos = []
        currentPage = 1
        hasMore = true
        errorMessage = nil
        guard let sort = currentListingSort, sort.id != "home" else { return }
        await loadCategoryVideos(page: 1, sort: sort, filters: currentRequestFilters)
    }

    /// 加载分类视频列表
    private func loadCategoryVideos(page: Int, sort: MovieSort.SortData, filters: [String: String]) async {
        guard sort.id != "home" else { return }
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        // 防重复并发加载，避免分页错序。
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let videoPage = try await sourceService.getListPage(sourceBean: source, sortData: sort, page: page, filters: filters)
            let videos = videoPage.videos

            // 分类切换过程中，丢弃旧请求结果
            guard isCurrentListing(sort: sort, filters: filters) else { return }

            if page == 1 {
                categoryVideos = videos
            } else {
                categoryVideos.append(contentsOf: videos)
            }
            currentPage = page
            if let pageCount = videoPage.pageCount {
                hasMore = videoPage.page < pageCount
            } else {
                // 旧 XML 接口没有分页总数，只能退回到非空列表判断。
                hasMore = !videos.isEmpty
            }
        } catch {
            guard isCurrentListing(sort: sort, filters: filters) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 加载下一页
    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }

    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard isPagedListing else { return }
        guard hasMore, !isLoading else { return }
        guard categoryVideos.last?.id == currentItem.id else { return }
        guard let sort = currentListingSort else { return }

        let nextPage = currentPage + 1
        await loadCategoryVideos(page: nextPage, sort: sort, filters: currentRequestFilters)
    }

    func isBridgeActionCard(_ video: Movie.Video) -> Bool {
        if video.isAction { return true }
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey) ?? ApiConfig.shared.homeSourceBean else { return false }
        guard source.requiresBridge, isBridgeConfigSource(source) else { return false }
        return looksLikeBridgeSettingCard(video)
    }

    func shouldOpenSearch(for video: Movie.Video) -> Bool {
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey) ?? ApiConfig.shared.homeSourceBean else { return false }
        return source.isIndex && !video.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func performAction(for video: Movie.Video) async {
        let action = video.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty || isBridgeActionCard(video) else { return }
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey) ?? ApiConfig.shared.homeSourceBean else { return }
        guard source.requiresBridge else {
            actionMessage = "当前动作需要 Android Bridge"
            return
        }
        guard !isPerformingAction else { return }

        isPerformingAction = true
        actionMessage = nil
        bridgeTokenErrorMessage = nil
        defer { isPerformingAction = false }

        do {
            let response = try await bridge.action(source: source, video: video)
            handleBridgeActionResponse(response, source: source)
        } catch BridgeError.tokenRequired(let prompt) {
            presentBridgeTokenPrompt(prompt, source: source)
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func selectBridgeActionPrompt(_ prompt: BridgeTokenPrompt) {
        guard let source = bridgeTokenSource ?? ApiConfig.shared.homeSourceBean else { return }
        isBridgeActionPromptPresented = false
        presentBridgeTokenPrompt(prompt, source: source)
    }

    func cancelBridgeTokenPrompt() {
        bridgeTokenPrompt = nil
        bridgeTokenSource = nil
        bridgeTokenErrorMessage = nil
        isBridgeTokenPromptPresented = false
    }

    func dismissBridgeTokenPromptPresentation() {
        if !isSubmittingBridgeToken {
            cancelBridgeTokenPrompt()
        }
    }

    func submitBridgeToken(values: [String: String]) async {
        guard let source = bridgeTokenSource, let prompt = bridgeTokenPrompt else { return }
        isSubmittingBridgeToken = true
        bridgeTokenErrorMessage = nil
        defer { isSubmittingBridgeToken = false }

        do {
            try await bridge.submitToken(source: source, prompt: prompt, values: values)
            cancelBridgeTokenPrompt()
            actionMessage = "授权已保存到 Android Bridge"
        } catch {
            bridgeTokenErrorMessage = error.localizedDescription
        }
    }

    func openBridgeJarUi(prompt: BridgeTokenPrompt) async throws -> BridgeJarUiResponse {
        guard let source = bridgeTokenSource else { throw BridgeError.notConfigured }
        return try await bridge.openJarUi(source: source, prompt: prompt)
    }

    func pollBridgeJarUi() async throws -> BridgeJarUiStatusResponse {
        guard let source = bridgeTokenSource, let prompt = bridgeTokenPrompt else { throw BridgeError.notConfigured }
        return try await bridge.jarUiStatus(source: source, prompt: prompt)
    }

    func closeBridgeJarUi() async {
        guard let source = bridgeTokenSource, let prompt = bridgeTokenPrompt else { return }
        do {
            try await bridge.closeJarUi(source: source, prompt: prompt)
            cancelBridgeTokenPrompt()
            actionMessage = "授权已发送到 Android Bridge"
        } catch {
            bridgeTokenErrorMessage = error.localizedDescription
        }
    }

    func sendBridgeJarUiAction(_ action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        guard let source = bridgeTokenSource, let prompt = bridgeTokenPrompt else { throw BridgeError.notConfigured }
        return try await bridge.jarUiAction(source: source, prompt: prompt, action: action)
    }

    func pollActionBridgeJarUi() async throws -> BridgeJarUiStatusResponse {
        guard let source = bridgeJarUiSource else { throw BridgeError.notConfigured }
        return try await bridge.jarUiStatus(source: source)
    }

    func sendActionBridgeJarUiAction(_ action: BridgeJarUiAction) async throws -> BridgeJarUiResponse {
        guard let source = bridgeJarUiSource else { throw BridgeError.notConfigured }
        return try await bridge.jarUiAction(source: source, action: action)
    }

    func cancelActionBridgeJarUi() {
        Task { await closeActionBridgeJarUi(showMessage: false) }
    }

    func dismissActionBridgeJarUiPresentation() {
        bridgeJarUiResponse = nil
        bridgeJarUiSource = nil
        isBridgeJarUiPresented = false
    }

    func closeActionBridgeJarUi(showMessage: Bool = true) async {
        let source = bridgeJarUiSource
        bridgeJarUiResponse = nil
        bridgeJarUiSource = nil
        isBridgeJarUiPresented = false
        guard let source else { return }
        do {
            try await bridge.closeJarUi(source: source)
            if showMessage { actionMessage = "Android Jar 界面已关闭" }
        } catch {
            if showMessage { actionMessage = error.localizedDescription }
        }
    }

    /// 刷新
    func refresh() async {
        // 全量刷新时重置分页与错误态，再重新拉分类与当前分类内容。
        let previousSortId = selectedSort?.id
        let previousFilters = selectedFilters
        folderStack = []
        currentPage = 1
        hasMore = true
        categoryVideos = []
        errorMessage = nil
        await loadSorts()

        if let previousSortId, let matchedSort = sorts.first(where: { $0.id == previousSortId }) {
            selectedSort = matchedSort
            selectedFilters = validatedFilters(previousFilters, for: matchedSort)
            guard matchedSort.id != "home" else { return }
            await loadCategoryVideos(page: 1, sort: matchedSort, filters: selectedFilters)
        } else if let firstCategory = sorts.first(where: { $0.id != "home" }) {
            selectedSort = firstCategory
            selectedFilters = defaultFilters(for: firstCategory)
            await loadCategoryVideos(page: 1, sort: firstCategory, filters: selectedFilters)
        } else if let first = sorts.first {
            selectedSort = first
            selectedFilters = defaultFilters(for: first)
        }
    }

    func resetAndReload() async {
        loadedSourceKey = ApiConfig.shared.homeSourceBean?.key ?? ""
        selectedSort = nil
        selectedFilters = [:]
        folderStack = []
        sorts = []
        homeVideos = []
        categoryVideos = []
        currentPage = 1
        hasMore = true
        errorMessage = nil
        await loadSorts()
        if let first = sorts.first { selectSort(first) }
    }

    private var currentListingSort: MovieSort.SortData? {
        folderStack.last?.sort ?? selectedSort
    }

    private var currentRequestFilters: [String: String] {
        folderStack.last?.filters ?? selectedFilters
    }

    private func isCurrentListing(sort: MovieSort.SortData, filters: [String: String]) -> Bool {
        if let currentFolder = folderStack.last {
            return currentFolder.sort.id == sort.id && currentFolder.filters == filters
        }
        return selectedSort?.id == sort.id && selectedFilters == filters
    }

    private func defaultFilters(for sort: MovieSort.SortData) -> [String: String] {
        var filters: [String: String] = [:]
        for filter in sort.filters {
            guard let value = filter.initialValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            filters[filter.key] = value
        }
        return filters
    }

    private func validatedFilters(_ filters: [String: String], for sort: MovieSort.SortData) -> [String: String] {
        let allowedKeys = Set(sort.filters.map(\.key))
        let retained = filters.filter { allowedKeys.contains($0.key) }
        return retained.isEmpty ? defaultFilters(for: sort) : retained
    }

    private func isBridgeConfigSource(_ source: SourceBean) -> Bool {
        let text = "\(source.key) \(source.name) \(source.api)".lowercased()
        return text.contains("config") || text.contains("配置中心")
    }

    private func looksLikeBridgeSettingCard(_ video: Movie.Video) -> Bool {
        let id = video.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = video.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let note = video.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return false }
        let text = "\(id) \(name) \(note)"
        let hasSettingIntent = note.contains("点击")
            || name.contains("设置")
            || name.contains("清除")
            || name.contains("重置")
            || name.contains("备份")
            || name.contains("恢复")
            || name.contains("导入")
            || name.contains("查看")
            || id.contains("cookie")
            || id.contains("token")
            || id.contains("login")
            || id.contains("clear")
        let hasConfigKeyword = text.contains("cookie")
            || text.contains("token")
            || text.contains("账号")
            || text.contains("设置")
            || text.contains("清除")
            || text.contains("配置")
            || text.contains("备份")
            || text.contains("恢复")
            || text.contains("重置")
            || text.contains("dns")
            || text.contains("emby")
        return hasSettingIntent && hasConfigKeyword
    }

    private func handleBridgeActionResponse(_ response: BridgeActionResponse, source: SourceBean) {
        if response.containsJarUiSnapshot {
            presentBridgeJarUi(response, source: source)
            return
        }

        switch response.mode {
        case "cloudLogin":
            bridgeTokenSource = source
            bridgeActionPrompts = response.prompts ?? response.prompt.map { [$0] } ?? []
            if bridgeActionPrompts.count == 1, let prompt = bridgeActionPrompts.first {
                presentBridgeTokenPrompt(prompt, source: source)
            } else if bridgeActionPrompts.isEmpty {
                actionMessage = response.message ?? "Bridge 没有返回可用登录方式"
            } else {
                isBridgeActionPromptPresented = true
            }
        default:
            actionMessage = response.message?.isEmpty == false ? response.message : "操作已发送到 Android Bridge"
        }
    }

    private func presentBridgeJarUi(_ response: BridgeActionResponse, source: SourceBean) {
        actionMessage = nil
        bridgeTokenPrompt = nil
        bridgeTokenErrorMessage = nil
        isBridgeActionPromptPresented = false
        isBridgeTokenPromptPresented = false
        isBridgeJarUiPresented = false
        bridgeJarUiSource = source
        bridgeJarUiTitle = "Android Jar 弹窗"
        bridgeJarUiResponse = BridgeJarUiResponse(actionResponse: response)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard self.bridgeJarUiResponse != nil else { return }
            self.isBridgeJarUiPresented = true
        }
    }

    private func presentBridgeTokenPrompt(_ prompt: BridgeTokenPrompt, source: SourceBean) {
        bridgeTokenSource = source
        bridgeTokenPrompt = prompt
        bridgeTokenErrorMessage = nil
        isBridgeTokenPromptPresented = true
    }
}
