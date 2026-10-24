import AppKit

/// 开关打开后，新开的终端窗口自动加入它所在屏幕的排列。
/// 终端 App 新启动时也会监听上，并把它启动时打开的窗口一起收纳。
final class AutoGather {
    static let shared = AutoGather()

    private var launchToken: Any?
    /// 每个 App 最近两次获得焦点的窗口（当前、上一个）。新窗口出现时焦点已经切到它身上，
    /// 所以要靠"上一个"找到是从哪个窗口按 ⌘N 开出来的。
    private var focusHistory: [pid_t: (current: WindowRef, previous: WindowRef?)] = [:]
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
        WindowEvents.shared.onFocusChanged = { [weak self] el in self?.recordFocus(el) }
    }

    private func recordFocus(_ el: AXUIElement) {
        guard AX.role(el) == kAXWindowRole else { return }
        let w = WindowRef(el)
        if let last = focusHistory[w.pid]?.current, last == w { return }
        focusHistory[w.pid] = (w, focusHistory[w.pid]?.current)
    }

    /// 新窗口是从哪个窗口开出来的：同一 App 在它之前获得焦点的那个窗口
    private func sourceWindow(of w: WindowRef) -> WindowRef? {
        guard let h = focusHistory[w.pid] else { return nil }
        let src = h.current == w ? h.previous : h.current
        return src.flatMap { AX.isAlive($0.element) ? $0 : nil }
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
            let pid = app.processIdentifier
            WindowEvents.shared.watch(pid: pid)
            // 记下现在的焦点窗口，否则在用户切换窗口之前没有"上一个"可用
            if focusHistory[pid] == nil, let el = AX.focusedWindow(pid: pid) { recordFocus(el) }
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
        // 屏幕铺满时，终端按惯例把新窗口错开一点放，常常被系统挤到另一块屏幕上。
        // 所以优先跟着开出它的那个窗口走，找不到再看新窗口自己落在哪。
        if let src = sourceWindow(of: w) {
            if let d = tiles.display(of: src) { return tiles.add(w, to: d) }
            if let sf = src.frame, let screen = NSScreen.containing(ax: CGPoint(x: sf.midX, y: sf.midY)) {
                return tiles.add(w, to: screen.displayID)
            }
        }
        let screen = NSScreen.containing(ax: CGPoint(x: f.midX, y: f.midY)) ?? NSScreen.underMouse
        tiles.add(w, to: screen.displayID)
    }
}
