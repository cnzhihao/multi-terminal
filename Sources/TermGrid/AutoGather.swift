import AppKit

/// 开关打开后，新开的终端窗口自动加入它所在屏幕的排列。
/// 对每个终端 App 挂一个 AXObserver 监听 kAXWindowCreatedNotification；
/// 终端 App 新启动时也会挂上，并把它启动时打开的窗口一起收纳。
final class AutoGather {
    static let shared = AutoGather()

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [Any] = []
    private let tiles = TileManager.shared

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoGather") }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoGather")
            newValue ? start() : stop()
        }
    }

    /// App 启动时调用：恢复上次的开关状态
    func restore() {
        if isEnabled { start() }
    }

    /// 给正在运行的终端 App 挂上监听（已挂过的跳过）。
    /// 没有辅助功能权限时 AXObserverCreate 会失败，所以拿到权限后要再调一次。
    func attachToRunningTerminals() {
        guard isEnabled else { return }
        for app in NSWorkspace.shared.runningApplications where Self.isTerminal(app) {
            observe(app.processIdentifier)
        }
    }

    private func start() {
        attachToRunningTerminals()
        guard workspaceTokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                              object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isTerminal(app) else { return }
            let pid = app.processIdentifier
            self.observe(pid)
            // 启动过程中打开的窗口可能早于 observer 挂上，补扫一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for el in AX.windows(pid: pid) { self.handleNew(el) }
            }
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                              object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unobserve(app.processIdentifier)
        })
    }

    private func stop() {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        for pid in Array(observers.keys) { unobserve(pid) }
    }

    private static func isTerminal(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(TileManager.terminalBundleIDs.contains) ?? false
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AutoGather>.fromOpaque(refcon).takeUnretainedValue()
            // 刚创建时窗口的位置、大小、subrole 可能还没就绪，稍等一下
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { me.handleNew(element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func unobserve(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func handleNew(_ el: AXUIElement) {
        guard isEnabled,
              AX.role(el) == kAXWindowRole,
              AX.subrole(el) == kAXStandardWindowSubrole,
              !AX.isMinimized(el),
              AX.isResizable(el)            // 设置窗口之类不能调大小的跳过
        else { return }
        let w = WindowRef(el)
        guard !tiles.isManaged(w), let f = w.frame else { return }
        // 系统原生标签页（Terminal、Ghostty 的 ⌘T）也是一个"新窗口"，
        // 但它和所在窗口共用同一个 frame，收纳进来会和原窗口抢位置，跳过
        guard !tiles.hasManagedWindow(withFrame: f) else { return }
        let screen = NSScreen.containing(ax: CGPoint(x: f.midX, y: f.midY)) ?? NSScreen.underMouse
        tiles.add(w, to: screen.displayID)
    }
}
