import AppKit

/// 用到时才建、关掉就放的窗口控制器（轻量化）：设置、帮助、引导窗口关闭后，SwiftUI 视图和控制器都不再常驻内存，
/// 下次打开重新建一个。窗口位置靠各自的 frame autosave 记住，不受影响。
@MainActor
final class OnDemandWindow<Controller: NSWindowController> {
    private let make: () -> Controller
    private(set) var current: Controller?
    private var closeObserver: NSObjectProtocol?

    init(_ make: @escaping () -> Controller) {
        self.make = make
    }

    /// 现有的那个；没有就新建一个，并在它关闭后放掉。
    var controller: Controller {
        if let current { return current }
        let controller = make()
        current = controller
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window,
                                                               queue: .main) { [weak self] _ in
            // 关闭回调还在这个窗口的调用栈里，下一轮再放。
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.release(controller) } }
        }
        return controller
    }

    private func release(_ controller: Controller) {
        guard current === controller, controller.window?.isVisible != true else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        current = nil
    }
}
