import SwiftUI
import SwiftData
import Combine

/// 应用入口。
/// 负责初始化 SwiftData 容器，并将全局状态 `AppState` 注入到根视图。
@main
struct tvboxApp: App {
    /// 全局运行时状态（配置加载状态、当前源、分栏布局状态等）。
    @StateObject private var appState = AppState()
    /// 网络状态监控。
    @StateObject private var networkMonitor = NetworkMonitor.shared
    
    /// 全局共享的 SwiftData 容器。
    /// 这里显式声明 Schema，确保收藏/历史/缓存三类数据使用同一持久化存储。
    var sharedModelContainer: ModelContainer = Self.makeModelContainer()

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            VodCollect.self,
            VodRecord.self,
            CacheItem.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("Could not create persistent ModelContainer, falling back to in-memory store: \(error)")
            do {
                let fallbackConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [fallbackConfiguration])
            } catch {
                preconditionFailure("Could not create fallback ModelContainer: \(error)")
            }
        }
    }
    
    /// 应用窗口与根视图。
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(networkMonitor)
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}

/// 应用级状态容器。
/// 统一管理配置加载与页面共享状态，避免在各页面重复拉取配置。
@MainActor
class AppState: ObservableObject {
    /// 解析后的配置单例，提供给所有页面与 ViewModel 使用。
    @Published var apiConfig = ApiConfig.shared
    /// 配置是否已经成功加载。控制 `ContentView` 显示主界面或首次配置页。
    @Published var isConfigLoaded = false
    /// 当前首页选中的视频源 key（用于跨页面同步）。
    @Published var currentSourceKey: String = ""
    /// 当前主标签/侧栏索引。
    @Published var selectedMainTab: Int = 0
    /// 外部页面请求搜索页打开的关键词。
    @Published private(set) var pendingSearchKeyword: String?
    /// 配置加载错误信息，供 UI 展示。
    @Published var configLoadError: String?
    /// 是否正在重试加载配置。
    @Published var isRetryingConfig = false
    
    #if os(macOS)
    /// macOS 三栏布局可见性（侧栏/内容/详情）。
    @Published var splitViewVisibility: NavigationSplitViewVisibility = .all
    /// 进入播放器全屏前的分栏状态快照，用于退出全屏后恢复。
    private var splitViewVisibilityBeforePlayerFullScreen: NavigationSplitViewVisibility?
    #endif
    
    /// 上次尝试加载的配置地址（用于自动重试）。
    private var lastVodUrl: String = ""
    private var lastLiveUrl: String = ""
    private var networkRestoredCancellable: AnyCancellable?
    private var networkPathChangedCancellable: AnyCancellable?
    
    init() {
        setupNetworkRestoredAutoRetry()
        setupBridgeEndpointRecovery()
    }

    /// 切到搜索页并让搜索页消费关键词执行搜索。
    func openSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearchKeyword = trimmed
        selectedMainTab = 2
        #if os(macOS)
        splitViewVisibility = .all
        #endif
    }

    func consumePendingSearchKeyword() -> String? {
        let keyword = pendingSearchKeyword
        pendingSearchKeyword = nil
        return keyword
    }
    
    /// 仅提供点播地址时的快捷加载入口（直播地址默认与点播一致）。
    func loadConfig(url: String) async {
        await loadConfig(vodUrl: url, liveUrl: nil)
    }
    
    /// 加载点播与直播配置。
    /// - Parameters:
    ///   - vodUrl: 点播配置地址
    ///   - liveUrl: 直播配置地址；为空时自动回退到点播地址
    func loadConfig(vodUrl: String, liveUrl: String?) async {
        let trimmedVod = vodUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = (liveUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else { return }
        let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
        
        lastVodUrl = trimmedVod
        lastLiveUrl = resolvedLive
        configLoadError = nil
        
        do {
            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            applyLoadedConfigState()
        } catch {
            if !(error is CancellationError) {
                configLoadError = error.localizedDescription
            }
        }
    }
    
    /// 将"配置已加载"的统一状态写回全局。
    /// 该方法会在设置页和启动自动加载两个入口中复用。
    func applyLoadedConfigState() {
        isConfigLoaded = true
        configLoadError = nil
        currentSourceKey = ApiConfig.shared.homeSourceBean?.key ?? ""
        if ApiConfig.shared.liveChannelGroupList.isEmpty, selectedMainTab == 1 {
            selectedMainTab = 0
        }
    }
    
    /// 网络恢复时，若配置未成功加载过，自动重试一次。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                BridgeClient.shared.checkPrimaryInBackgroundAfterNetworkChange()
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isConfigLoaded, !self.lastVodUrl.isEmpty else { return }
                    self.isRetryingConfig = true
                    await self.loadConfig(vodUrl: self.lastVodUrl, liveUrl: self.lastLiveUrl)
                    self.isRetryingConfig = false
                }
            }
    }

    /// 网络路径变化后，后台探测 Bridge 主地址，若局域网主地址恢复则无感切回。
    private func setupBridgeEndpointRecovery() {
        networkPathChangedCancellable = NetworkMonitor.shared.networkPathChangedPublisher
            .sink {
                BridgeClient.shared.checkPrimaryInBackgroundAfterNetworkChange()
            }
    }
    
    #if os(macOS)
    /// 进入播放器全屏时隐藏侧栏，减少播放器可视区域干扰。
    func enterPlayerFullScreen() {
        if splitViewVisibilityBeforePlayerFullScreen == nil {
            splitViewVisibilityBeforePlayerFullScreen = splitViewVisibility
        }
        splitViewVisibility = .detailOnly
    }
    
    /// 退出播放器全屏时恢复之前的分栏状态。
    func exitPlayerFullScreen() {
        guard let previous = splitViewVisibilityBeforePlayerFullScreen else { return }
        splitViewVisibility = previous
        splitViewVisibilityBeforePlayerFullScreen = nil
    }
    #endif
}
