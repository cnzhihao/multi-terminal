import AppKit

/// 开关打开后，新开的终端窗口自动加入它所在屏幕的排列。
/// 终端 App 新启动时也会监听上，并把它启动时打开的窗口一起收纳。
final class AutoGather {
    static let shared = AutoGather()

    private var launchToken: Any?
    private let tiles = TileManager.shared

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoGather") }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoGather")
            if newValue { start() }
        }
    }

    private init() {
        WindowEvents.shared.onWindowCreated = { [weak self] el in
            // 刚创建时窗口的位置、大小、subrole 可能还没就绪，稍等一下
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.handleNew(el) }
        }
    }

    /// App 启动时调用：恢复上次的开关状态
    func restore() {
        if isEnabled { start() }
    }

    /// 给正在运行的终端 App 挂上监听（已挂过的跳过）。
    /// 没有辅助功能权限时会失败，所以拿到权限后要再调一次。
    func attachToRunningTerminals() {
        guard isEnabled else { return }
        for app in NSWorkspace.shared.runningApplications where Self.isTerminal(app) {
            WindowEvents.shared.watch(pid: app.processIdentifier)
        }
    }

    private func start() {
        attachToRunningTerminals()
        guard launchToken == nil else { return }
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isEnabled,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isTerminal(app) else { return }
            let pid = app.processIdentifier
            WindowEvents.shared.watch(pid: pid)
            // 启动过程中打开的窗口可能早于监听挂上，补扫一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for el in AX.windows(pid: pid) { self.handleNew(el) }
            }
        }
    }

    private static func isTerminal(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(TileManager.terminalBundleIDs.contains) ?? false
    }

    private func handleNew(_ el: AXUIElement) {
        guard isEnabled,
              AX.role(el) == kAXWindowRole,
              AX.subrole(el) == kAXStandardWindowSubrole,
              !AX.isMinimized(el),
              AX.isResizable(el)            // 设置窗口之类不能调大小的跳过
        else { return }
        let w = WindowRef(el)
        guard tiles.accepts(w), !tiles.isManaged(w), let f = w.frame else { return }
        // 系统原生标签页（Terminal、Ghostty 的 ⌘T）也是一个"新窗口"，
        // 但它和所在窗口共用同一个 frame，收纳进来会和原窗口抢位置，跳过
        guard !tiles.hasManagedWindow(withFrame: f) else { return }
        let screen = NSScreen.containing(ax: CGPoint(x: f.midX, y: f.midY)) ?? NSScreen.underMouse
        tiles.add(w, to: screen.displayID)
    }
}
