import AppKit

/// 事件驱动的窗口变化监听（代替轮询）：给 App 挂 AXObserver，
/// 窗口新建/关闭/最小化/焦点切换/App 隐藏时回调，平时不占任何资源。
final class WindowEvents {
    static let shared = WindowEvents()

    /// 某个 App 的窗口可能增减了（关闭、最小化、焦点变化等）
    var onChange: (() -> Void)?
    /// 新建了窗口
    var onWindowCreated: ((AXUIElement) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,   // Ghostty 等"可撤销关闭"只是把窗口藏起来，但焦点一定会变
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(app.processIdentifier)
            self?.onChange?()
        }
    }

    /// 监听一个 App。没有辅助功能权限时会失败，拿到权限后再调一次即可（已挂上的会跳过）。
    @discardableResult
    func watch(pid: pid_t) -> AXObserver? {
        if let obs = observers[pid] { return obs }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            let events = WindowEvents.shared
            if notification as String == kAXWindowCreatedNotification {
                events.onWindowCreated?(element)
            }
            events.onChange?()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        let app = AXUIElementCreateApplication(pid)
        for n in Self.appNotifications { AXObserverAddNotification(obs, app, n as CFString, nil) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        return obs
    }

    /// 监听单个窗口的关闭和最小化
    func watch(window w: WindowRef) {
        guard let obs = watch(pid: w.pid) else { return }
        for n in Self.windowNotifications { AXObserverAddNotification(obs, w.element, n as CFString, nil) }
    }

    private func unwatch(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
}
