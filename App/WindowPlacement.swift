import AppKit

/// 屏幕布局变化（拔掉外接屏、改分辨率或缩放）后，把已打开的窗口挪回能操作的位置（审查 09）。
@MainActor
enum WindowPlacement {
    /// 窗口至少这么多留在某块屏幕的可用区域里，并且标题栏一带能抓到，才算还能操作。
    static let minimumVisibleFraction: CGFloat = 0.5

    /// 窗口落在哪块屏幕上不够用时，把它整个挪进与它重叠最多的屏幕（没有就主屏）的可用区域，放不下就缩小。
    static func keepOnScreen(_ window: NSWindow) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let frame = window.frame
        let best = screens.max { area(frame.intersection($0.visibleFrame)) < area(frame.intersection($1.visibleFrame)) }
        let target = (best.flatMap { area(frame.intersection($0.visibleFrame)) > 0 ? $0 : nil } ?? NSScreen.main ?? screens[0]).visibleFrame
        guard !isUsable(frame, in: target) else { return }
        window.setFrame(clamped(frame, to: target), display: true)
    }

    static func isUsable(_ frame: NSRect, in visible: NSRect) -> Bool {
        let shown = area(frame.intersection(visible))
        // 顶部 24 点（标题栏或可拖动的上缘）要在屏幕里。
        let top = NSRect(x: frame.minX, y: frame.maxY - 24, width: frame.width, height: 24)
        return shown >= area(frame) * minimumVisibleFraction && area(top.intersection(visible)) >= area(top) * minimumVisibleFraction
    }

    static func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(frame.width, visible.width)
        result.size.height = min(frame.height, visible.height)
        result.origin.x = min(max(frame.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(frame.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
