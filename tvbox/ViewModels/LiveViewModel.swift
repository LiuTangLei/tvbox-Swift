import Foundation
import SwiftUI
import Combine

/// 直播 ViewModel
@MainActor
class LiveViewModel: ObservableObject {
    private static let favoriteGroupName = "收藏"

    /// 全部频道分组。
    @Published var channelGroups: [LiveChannelGroup] = []
    /// 当前选中分组索引。
    @Published var selectedGroupIndex: Int = 0
    /// 当前选中频道索引（相对于当前分组）。
    @Published var selectedChannelIndex: Int = 0
    /// 当前播放频道。
    @Published var currentChannel: LiveChannelItem?
    /// 当前频道节目单。
    @Published var epgList: [Epginfo] = []
    /// 当前回看播放覆盖；为空时播放实时直播。
    @Published private(set) var catchupPlayback: LiveCatchupPlayback?
    /// EPG 加载状态。
    @Published var isLoading = false
    /// EPG 加载错误，仅用于调试和轻量状态展示。
    @Published var epgErrorMessage: String?
    /// 是否显示频道列表（预留给 TV 遥控交互）。
    @Published var showChannelList = false
    
    /// 订阅配置更新，支持直播频道列表实时刷新。
    private var cancellables: Set<AnyCancellable> = []
    /// 当前 EPG 加载任务，切台时取消，避免旧频道节目单覆盖新频道。
    private var epgLoadTask: Task<Void, Never>?
    /// 原始直播分组，不包含 Swift 侧合成的收藏分组。
    private var baseChannelGroups: [LiveChannelGroup] = []
    /// 按收藏时间倒序存储频道名 key，模拟 Android Keep 的直播收藏合并。
    private var favoriteChannelKeys: [String] = []
    
    init() {
        favoriteChannelKeys = Self.loadFavoriteChannelKeys()
        bindLiveChannelGroups()
    }
    
    /// 加载直播频道
    func loadChannels() {
        applyChannelGroups(ApiConfig.shared.liveChannelGroupList)
    }
    
    /// 选择频道分组
    func selectGroup(_ index: Int) {
        guard index >= 0, index < channelGroups.count else { return }
        selectedGroupIndex = index
        selectedChannelIndex = 0
        if let first = channelGroups[index].channels.first {
            selectChannel(first)
        }
    }
    
    /// 选择频道
    func selectChannel(_ channel: LiveChannelItem) {
        setCurrentChannel(channel)
    }
    
    /// 上一个频道
    func previousChannel() {
        guard !channelGroups.isEmpty else { return }
        if selectedChannelIndex > 0 {
            selectedChannelIndex -= 1
        } else if selectedGroupIndex > 0 {
            selectedGroupIndex -= 1
            selectedChannelIndex = channelGroups[selectedGroupIndex].channels.count - 1
        }
        if let ch = channelGroups[selectedGroupIndex].channels[safe: selectedChannelIndex] {
            selectChannel(ch)
        }
    }
    
    /// 下一个频道
    func nextChannel() {
        guard !channelGroups.isEmpty else { return }
        let group = channelGroups[selectedGroupIndex]
        if selectedChannelIndex < group.channels.count - 1 {
            selectedChannelIndex += 1
        } else if selectedGroupIndex < channelGroups.count - 1 {
            selectedGroupIndex += 1
            selectedChannelIndex = 0
        }
        if let ch = channelGroups[selectedGroupIndex].channels[safe: selectedChannelIndex] {
            selectChannel(ch)
        }
    }
    
    /// 切换线路
    func switchSource() {
        catchupPlayback = nil
        // `currentChannel` 为值类型，调用 mutating 方法会触发 @Published 重新发布。
        currentChannel?.nextSource()
    }
    
    /// 当前频道列表
    var currentChannels: [LiveChannelItem] {
        guard selectedGroupIndex < channelGroups.count else { return [] }
        return channelGroups[selectedGroupIndex].channels
    }

    func isFavorite(_ channel: LiveChannelItem) -> Bool {
        favoriteChannelKeys.contains(Self.favoriteKey(for: channel))
    }

    func toggleFavorite(_ channel: LiveChannelItem) {
        let key = Self.favoriteKey(for: channel)
        guard !key.isEmpty else { return }

        if let index = favoriteChannelKeys.firstIndex(of: key) {
            favoriteChannelKeys.remove(at: index)
        } else {
            favoriteChannelKeys.removeAll { $0 == key }
            favoriteChannelKeys.insert(key, at: 0)
        }
        Self.saveFavoriteChannelKeys(favoriteChannelKeys)

        let preferredGroupName = selectedGroupIndex < channelGroups.count
            ? channelGroups[selectedGroupIndex].groupName
            : nil
        rebuildChannelGroups(selecting: currentChannel, preferredGroupName: preferredGroupName)
    }

    var currentEpg: Epginfo? {
        epgList.first(where: \.isLive)
    }

    var nextEpg: Epginfo? {
        if let currentEpg,
           let currentIndex = epgList.firstIndex(of: currentEpg),
           currentIndex + 1 < epgList.count {
            return epgList[currentIndex + 1]
        }
        let now = Date().timeIntervalSince1970
        return epgList.first { $0.startTimestamp > now }
    }

    var isPlayingCatchup: Bool {
        catchupPlayback != nil
    }

    var currentPlaybackURL: String? {
        catchupPlayback?.url ?? currentChannel?.currentUrl
    }

    var currentPlaybackHeaders: [String: String] {
        catchupPlayback?.headers ?? currentChannel?.currentHeaders ?? [:]
    }

    var currentPlaybackIdentifier: String {
        if let catchupPlayback {
            let headerKey = catchupPlayback.headers
                .map { ($0.key.lowercased(), $0.value) }
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0):\($0.1)" }
                .joined(separator: "\n")
            return ["catchup", catchupPlayback.url, headerKey, catchupPlayback.epg.id].joined(separator: "\n")
        }
        return currentChannel?.currentPlaybackIdentifier ?? ""
    }

    func canPlayCatchup(_ epg: Epginfo) -> Bool {
        currentChannel?.canPlayCatchup(epg) == true
    }

    func isPlayingCatchup(_ epg: Epginfo) -> Bool {
        catchupPlayback?.epg == epg
    }

    func playCatchup(_ epg: Epginfo) {
        guard let playback = currentChannel?.catchupPlayback(for: epg) else { return }
        catchupPlayback = playback
    }

    func returnToLive() {
        catchupPlayback = nil
    }
    
    /// 加载 EPG 节目单
    private func loadEPG(for channel: LiveChannelItem) {
        epgLoadTask?.cancel()
        epgList = []
        epgErrorMessage = nil

        guard channel.epgUrl.nilIfBlank != nil else {
            isLoading = false
            return
        }

        isLoading = true
        let channelId = channel.id

        epgLoadTask = Task { [weak self, channel] in
            do {
                let programs = try await XMLTVService.shared.loadTodayPrograms(for: channel)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self, self.currentChannel?.id == channelId else { return }
                    self.epgList = programs
                    self.isLoading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.currentChannel?.id == channelId else { return }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard let self, self.currentChannel?.id == channelId else { return }
                    self.epgList = []
                    self.epgErrorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func setCurrentChannel(_ channel: LiveChannelItem?) {
        catchupPlayback = nil
        currentChannel = channel
        if let channel {
            loadEPG(for: channel)
        } else {
            clearEPG()
        }
    }

    private func clearEPG() {
        epgLoadTask?.cancel()
        epgLoadTask = nil
        catchupPlayback = nil
        epgList = []
        epgErrorMessage = nil
        isLoading = false
    }
    
    private func bindLiveChannelGroups() {
        ApiConfig.shared.$liveChannelGroupList
            .sink { [weak self] groups in
                self?.applyChannelGroups(groups)
            }
            .store(in: &cancellables)
    }
    
    private func applyChannelGroups(_ groups: [LiveChannelGroup]) {
        let previousChannelId = currentChannel?.id
        let previousChannel = currentChannel
        let preferredGroupName = selectedGroupIndex < channelGroups.count
            ? channelGroups[selectedGroupIndex].groupName
            : nil
        baseChannelGroups = groups
        channelGroups = groupsWithFavorites(from: groups)
        
        guard !channelGroups.isEmpty else {
            selectedGroupIndex = 0
            selectedChannelIndex = 0
            setCurrentChannel(nil)
            return
        }

        if let previousChannel,
           let located = locateChannel(
                matching: previousChannel,
                in: channelGroups,
                preferredGroupName: preferredGroupName
           ) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            setCurrentChannel(channelGroups[located.groupIndex].channels[located.channelIndex])
            return
        }

        if let previousChannelId,
           let located = locateChannel(withId: previousChannelId, in: channelGroups) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            setCurrentChannel(channelGroups[located.groupIndex].channels[located.channelIndex])
            return
        }
        
        let clampedGroupIndex = min(max(0, selectedGroupIndex), channelGroups.count - 1)
        selectedGroupIndex = clampedGroupIndex
        
        let channels = channelGroups[clampedGroupIndex].channels
        guard !channels.isEmpty else {
            selectedChannelIndex = 0
            setCurrentChannel(nil)
            return
        }
        
        let clampedChannelIndex = min(max(0, selectedChannelIndex), channels.count - 1)
        selectedChannelIndex = clampedChannelIndex
        setCurrentChannel(channels[clampedChannelIndex])
    }

    private func rebuildChannelGroups(
        selecting channel: LiveChannelItem?,
        preferredGroupName: String?
    ) {
        channelGroups = groupsWithFavorites(from: baseChannelGroups)

        guard !channelGroups.isEmpty else {
            selectedGroupIndex = 0
            selectedChannelIndex = 0
            setCurrentChannel(nil)
            return
        }

        if let channel,
           let located = locateChannel(
                matching: channel,
                in: channelGroups,
                preferredGroupName: preferredGroupName
           ) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            setCurrentChannel(channelGroups[located.groupIndex].channels[located.channelIndex])
            return
        }

        selectedGroupIndex = min(max(0, selectedGroupIndex), channelGroups.count - 1)
        selectedChannelIndex = min(
            max(0, selectedChannelIndex),
            max(0, channelGroups[selectedGroupIndex].channels.count - 1)
        )
    }

    private func groupsWithFavorites(from groups: [LiveChannelGroup]) -> [LiveChannelGroup] {
        let reindexedBase = Self.reindexedGroups(groups)
        let favoriteChannels = favoriteChannelKeys.compactMap { key in
            reindexedBase
                .lazy
                .flatMap(\.channels)
                .first { Self.favoriteKey(for: $0) == key }
        }

        guard !favoriteChannels.isEmpty else { return reindexedBase }

        var favoriteGroup = LiveChannelGroup(groupName: Self.favoriteGroupName, groupIndex: 0)
        favoriteGroup.channels = favoriteChannels.enumerated().map { index, channel in
            var favoriteChannel = channel
            favoriteChannel.channelIndex = index
            return favoriteChannel
        }

        let shiftedGroups = reindexedBase.enumerated().map { offset, group in
            var shiftedGroup = group
            shiftedGroup.groupIndex = offset + 1
            return shiftedGroup
        }
        return [favoriteGroup] + shiftedGroups
    }
    
    private func locateChannel(
        withId channelId: String,
        in groups: [LiveChannelGroup]
    ) -> (groupIndex: Int, channelIndex: Int)? {
        for (groupIndex, group) in groups.enumerated() {
            if let channelIndex = group.channels.firstIndex(where: { $0.id == channelId }) {
                return (groupIndex, channelIndex)
            }
        }
        return nil
    }

    private func locateChannel(
        matching channel: LiveChannelItem,
        in groups: [LiveChannelGroup],
        preferredGroupName: String?
    ) -> (groupIndex: Int, channelIndex: Int)? {
        if let preferredGroupName,
           let preferredGroupIndex = groups.firstIndex(where: { $0.groupName == preferredGroupName }),
           let channelIndex = groups[preferredGroupIndex].channels.firstIndex(where: {
               Self.isSamePlaybackChannel($0, channel)
           }) {
            return (preferredGroupIndex, channelIndex)
        }

        for (groupIndex, group) in groups.enumerated() {
            if let channelIndex = group.channels.firstIndex(where: {
                Self.isSamePlaybackChannel($0, channel)
            }) {
                return (groupIndex, channelIndex)
            }
        }
        return nil
    }

    private static func isSamePlaybackChannel(
        _ lhs: LiveChannelItem,
        _ rhs: LiveChannelItem
    ) -> Bool {
        favoriteKey(for: lhs) == favoriteKey(for: rhs)
    }

    private static func reindexedGroups(_ groups: [LiveChannelGroup]) -> [LiveChannelGroup] {
        groups.enumerated().map { groupIndex, group in
            var reindexedGroup = group
            reindexedGroup.groupIndex = groupIndex
            reindexedGroup.channels = group.channels.enumerated().map { channelIndex, channel in
                var reindexedChannel = channel
                reindexedChannel.channelIndex = channelIndex
                return reindexedChannel
            }
            return reindexedGroup
        }
    }

    private static func favoriteKey(for channel: LiveChannelItem) -> String {
        channel.channelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func loadFavoriteChannelKeys() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: HawkConfig.LIVE_CHANNEL_FAVORITES) ?? []
        return uniqueFavoriteKeys(saved)
    }

    private static func saveFavoriteChannelKeys(_ keys: [String]) {
        UserDefaults.standard.set(uniqueFavoriteKeys(keys), forKey: HawkConfig.LIVE_CHANNEL_FAVORITES)
    }

    private static func uniqueFavoriteKeys(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for key in keys {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    deinit {
        epgLoadTask?.cancel()
    }
}

// 安全数组下标访问
extension Collection {
    /// 安全下标读取，越界时返回 `nil`。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
