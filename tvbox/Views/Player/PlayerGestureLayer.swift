#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Gesture Mode Enum

/// 手势模式枚举 - 表示当前激活的手势类型
enum PlayerGestureMode: Equatable {
    case none
    case seeking(offset: Double)
    case adjustingBrightness(delta: CGFloat)
    case adjustingVolume(delta: CGFloat)
    case fastForward
}

// MARK: - PlayerGestureLayer

/// 播放器手势交互层 - 覆盖在播放器上方的透明手势识别层
/// 支持水平滑动快进快退、左侧垂直滑动调节亮度、右侧垂直滑动调节音量、
/// 双击暂停/播放、捏合缩放
struct PlayerGestureLayer: View {
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Callbacks
    let onSeek: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onToggleControls: () -> Void
    let onZoomChanged: (CGFloat) -> Void
    let onBrightnessChanged: (CGFloat) -> Void
    let onVolumeChanged: (CGFloat) -> Void
    let onLongPressFastForwardChanged: (Bool) -> Void

    // MARK: - Properties
    let currentTime: Double
    let duration: Double
    let brightnessValue: CGFloat
    let volumeValue: CGFloat

    // MARK: - State
    @State private var gestureMode: PlayerGestureMode = .none
    @State private var zoomScale: CGFloat = 1.0
    @State private var showIndicator = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartBrightness: CGFloat = UIScreen.main.brightness
    @State private var dragStartVolume: CGFloat = 0.5
    @State private var displayedBrightness: CGFloat = UIScreen.main.brightness
    @State private var displayedVolume: CGFloat = 0.5
    @State private var didMoveDuringTouch = false
    @State private var isFastForwarding = false
    @State private var isTouchPressing = false
    @State private var longPressTask: Task<Void, Never>?

    // MARK: - Pure Computation Functions

    /// 根据起始位置和滑动方向确定手势类型
    static func classifyGesture(
        startX: CGFloat,
        containerWidth: CGFloat,
        translation: CGSize,
        threshold: CGFloat = 10
    ) -> PlayerGestureMode {
        let absH = abs(translation.width)
        let absV = abs(translation.height)

        // 水平优先判定（快进快退）
        if absH > absV && absH > threshold {
            // 根据滑动距离动态调整快进幅度，短距离精细，长距离快速
            let normalizedOffset = translation.width / containerWidth
            let offset = Double(normalizedOffset) * 120.0 // 滑满屏幕 = 120秒
            return .seeking(offset: offset)
        }

        // 垂直判定：左半区域 = 亮度，右半区域 = 音量
        if absV > threshold {
            let isLeftHalf = startX < containerWidth / 2
            let delta = -translation.height / 300.0 // 向上为正
            if isLeftHalf {
                return .adjustingBrightness(delta: delta)
            } else {
                return .adjustingVolume(delta: delta)
            }
        }

        return .none
    }

    /// 计算快进快退目标时间（带边界钳制）
    static func computeSeekTarget(
        currentTime: Double,
        offset: Double,
        duration: Double
    ) -> Double {
        let target = currentTime + offset
        return max(0, min(target, duration))
    }

    /// 钳制调节值到 [0, 1] 范围
    static func clampAdjustment(
        currentValue: CGFloat,
        delta: CGFloat
    ) -> CGFloat {
        return max(0.0, min(1.0, currentValue + delta))
    }

    /// 钳制缩放值到 [minZoom, maxZoom] 范围
    static func clampZoom(
        scale: CGFloat,
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 3.0
    ) -> CGFloat {
        return max(minZoom, min(maxZoom, scale))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(in: geometry))
                .simultaneousGesture(pinchGesture)
                .onLongPressGesture(
                    minimumDuration: 0.45,
                    maximumDistance: 10,
                    pressing: handleLongPressPressing(_:),
                    perform: {}
                )
                .onTapGesture(count: 2) {
                    HapticManager.shared.lightImpact()
                    onTogglePlayPause()
                }
                .onTapGesture(count: 1) {
                    onToggleControls()
                }
                .overlay { gestureIndicatorOverlay }
                .onAppear {
                    displayedBrightness = brightnessValue
                    displayedVolume = volumeValue
                }
                .onChange(of: brightnessValue) { _, newValue in
                    if case .adjustingBrightness = gestureMode { return }
                    displayedBrightness = newValue
                }
                .onChange(of: volumeValue) { _, newValue in
                    if case .adjustingVolume = gestureMode { return }
                    displayedVolume = newValue
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase != .active else { return }
                    resetGestureState()
                }
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if gestureMode == .none {
                    dragStartX = value.startLocation.x
                    dragStartBrightness = brightnessValue
                    dragStartVolume = volumeValue
                    HapticManager.shared.lightImpact()
                }

                let mode = Self.classifyGesture(
                    startX: dragStartX,
                    containerWidth: geometry.size.width,
                    translation: value.translation
                )

                if mode != .none {
                    didMoveDuringTouch = true
                    cancelPendingLongPress()
                    stopFastForward()
                    gestureMode = mode
                    applyAdjustment(for: mode)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showIndicator = true
                    }
                }
            }
            .onEnded { value in
                switch gestureMode {
                case .seeking(let offset):
                    let target = Self.computeSeekTarget(
                        currentTime: currentTime,
                        offset: offset,
                        duration: duration
                    )
                    onSeek(target - currentTime)
                case .adjustingBrightness, .adjustingVolume:
                    break
                case .none, .fastForward:
                    break
                }

                gestureMode = .none
                didMoveDuringTouch = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = false
                }
            }
    }

    private func handleLongPressPressing(_ isPressing: Bool) {
        isTouchPressing = isPressing
        if isPressing {
            longPressTask?.cancel()
            longPressTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled,
                      isTouchPressing,
                      !didMoveDuringTouch,
                      gestureMode == .none else { return }
                beginLongPressFastForward()
            }
        } else {
            cancelPendingLongPress()
            stopFastForward()
            didMoveDuringTouch = false
        }
    }

    private func beginLongPressFastForward() {
        guard !didMoveDuringTouch, gestureMode == .none else { return }
        HapticManager.shared.lightImpact()
        isFastForwarding = true
        gestureMode = .fastForward
        onLongPressFastForwardChanged(true)
        withAnimation(.easeInOut(duration: 0.2)) {
            showIndicator = true
        }
    }

    private func stopFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        onLongPressFastForwardChanged(false)
        if gestureMode == .fastForward {
            gestureMode = .none
            withAnimation(.easeInOut(duration: 0.2)) {
                showIndicator = false
            }
        }
    }

    private func resetGestureState() {
        isTouchPressing = false
        cancelPendingLongPress()
        stopFastForward()
        didMoveDuringTouch = false
        gestureMode = .none
        withAnimation(.easeInOut(duration: 0.2)) {
            showIndicator = false
        }
    }

    private func cancelPendingLongPress() {
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func applyAdjustment(for mode: PlayerGestureMode) {
        switch mode {
        case .adjustingBrightness(let delta):
            let value = Self.clampAdjustment(currentValue: dragStartBrightness, delta: delta)
            displayedBrightness = value
            onBrightnessChanged(value)
        case .adjustingVolume(let delta):
            let value = Self.clampAdjustment(currentValue: dragStartVolume, delta: delta)
            displayedVolume = value
            onVolumeChanged(value)
        case .none, .seeking, .fastForward:
            break
        }
    }

    // MARK: - Pinch Gesture

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = Self.clampZoom(scale: value.magnification * zoomScale)
                onZoomChanged(newScale)
                gestureMode = .none
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = true
                }
            }
            .onEnded { value in
                let finalScale = Self.clampZoom(scale: value.magnification * zoomScale)
                if finalScale < 1.0 {
                    zoomScale = 1.0
                } else {
                    zoomScale = finalScale
                }
                onZoomChanged(zoomScale)
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = false
                }
            }
    }

    // MARK: - Gesture Indicator Overlay

    @ViewBuilder
    private var gestureIndicatorOverlay: some View {
        if showIndicator {
            if case .fastForward = gestureMode {
                VStack {
                    HStack {
                        Spacer()
                        Text("2x播放")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.62))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.trailing, 18)
                .opacity(showIndicator ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showIndicator)
            } else {
                VStack(spacing: 8) {
                    indicatorIcon
                    indicatorText
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(showIndicator ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showIndicator)
            }
        }
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        switch gestureMode {
        case .seeking(let offset):
            Image(systemName: offset >= 0 ? "forward.fill" : "backward.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .adjustingBrightness:
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundColor(.yellow)
        case .adjustingVolume:
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .fastForward:
            Image(systemName: "forward.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicatorText: some View {
        switch gestureMode {
        case .seeking(let offset):
            let target = Self.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )
            Text(formatTime(target))
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingBrightness(let delta):
            let percentage = Int(Self.clampAdjustment(
                currentValue: dragStartBrightness,
                delta: delta
            ) * 100)
            Text("\(percentage)%")
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingVolume(let delta):
            let percentage = Int(Self.clampAdjustment(
                currentValue: dragStartVolume,
                delta: delta
            ) * 100)
            Text("\(percentage)%")
                .font(.caption)
                .foregroundColor(.white)
        case .fastForward:
            Text("2x")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(max(0, seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
#endif
