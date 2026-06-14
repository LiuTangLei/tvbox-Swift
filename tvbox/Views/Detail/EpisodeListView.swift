import SwiftUI

/// 剧集列表组件 - 对应 Android 版 SeriesAdapter
struct EpisodeListView: View {
    /// 当前线路下的全部剧集。
    let episodes: [VodInfo.Episode]
    /// 外部传入的当前选中集索引（绝对索引）。
    let selectedIndex: Int
    /// 当前是否正在解析 Bridge 播放地址。
    let isResolving: Bool
    /// 正在解析的剧集索引。
    let resolvingIndex: Int?
    /// 点击某一集后的回调（返回绝对索引）。
    let onSelect: (Int) -> Void
    
    /// 当前分组索引（每 50 集一个分组，避免超长列表影响渲染与选择体验）。
    @State private var currentGroup = 0
    /// 每个分组展示的剧集数量。
    private let groupSize = 50
    /// 自适应列：根据可用宽度自动换行，避免集数过多时右侧被截断。
    private let gridColumns = [GridItem(.adaptive(minimum: 78), spacing: 10)]
    
    /// 分组总数，至少为 1，避免空数组时出现 0 组的边界问题。
    private var groupCount: Int {
        max(1, (episodes.count + groupSize - 1) / groupSize)
    }
    
    /// 当前分组对应的切片数据。
    private var currentEpisodes: [VodInfo.Episode] {
        let start = currentGroup * groupSize
        let end = min(start + groupSize, episodes.count)
        guard start < episodes.count else { return [] }
        return Array(episodes[start..<end])
    }

    private var selectedEpisode: VodInfo.Episode? {
        guard episodes.indices.contains(selectedIndex) else { return nil }
        return episodes[selectedIndex]
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // 分组选择
            if groupCount > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<groupCount, id: \.self) { group in
                            let start = group * groupSize + 1
                            let end = min((group + 1) * groupSize, episodes.count)
                            Button {
                                withAnimation {
                                    currentGroup = group
                                }
                            } label: {
                                Text("\(start)-\(end)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(currentGroup == group ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        ZStack {
                                            if currentGroup == group {
                                                Capsule().fill(Color.white.opacity(0.15))
                                            } else {
                                                Capsule().fill(Color.white.opacity(0.05))
                                            }
                                        }
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }

            if let selectedEpisode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前选集")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Text(selectedEpisode.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
            }
            
            // 剧集网格：自适应换行，避免横向裁切。
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                // 这里使用当前组内索引 + 组偏移，换算成全局索引以便外部状态一致。
                ForEach(Array(currentEpisodes.enumerated()), id: \.offset) { index, episode in
                    let actualIndex = currentGroup * groupSize + index
                    Button {
                        onSelect(actualIndex)
                    } label: {
                        ZStack {
                            Text(episode.name)
                                .font(.system(size: 13, weight: actualIndex == selectedIndex ? .bold : .medium))
                                .foregroundColor(actualIndex == selectedIndex ? .white : .white.opacity(0.7))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .opacity(isResolving && resolvingIndex == actualIndex ? 0 : 1)

                            if isResolving && resolvingIndex == actualIndex {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            ZStack {
                                if actualIndex == selectedIndex {
                                    AppTheme.accentGradient
                                } else {
                                    Color.white.opacity(0.05)
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(actualIndex == selectedIndex ? Color.clear : Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(episode.name)
                    .disabled(isResolving)
                }
            }
            .padding(.horizontal, 20)
        }
        .onAppear {
            syncGroupToSelection()
        }
        .onChange(of: selectedIndex) { _, _ in
            syncGroupToSelection()
        }
        .onChange(of: episodes.count) { _, _ in
            syncGroupToSelection()
        }
    }

    private func syncGroupToSelection() {
        guard selectedIndex >= 0, !episodes.isEmpty else {
            currentGroup = 0
            return
        }
        let targetGroup = min(max(selectedIndex / groupSize, 0), groupCount - 1)
        if currentGroup != targetGroup {
            currentGroup = targetGroup
        }
    }
}
