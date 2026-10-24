import AppKit

/// 管理"被收纳"的窗口：每块屏幕一组，按加入顺序排成网格。
final class TileManager {
    static let shared = TileManager()

    /// 常见终端 App 的 bundle id
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
        "dev.commandline.waveterm",
    ]

    private(set) var groups: [CGDirectDisplayID: [WindowRef]] = [:]
    /// 上次排列时每个窗口所在的格子（AX 坐标），用于拖动换位
    private var slots: [CGDirectDisplayID: [(WindowRef, CGRect)]] = [:]

    var onChange: (() -> Void)?

    private init() {
        // 只在窗口新建/关闭/最小化/恢复时检查一次
        WindowEvents.shared.onChange = { [weak self] in self?.scheduleReconcile() }
    }

    // MARK: 设置

    private let defaults = UserDefaults.standard

    var gap: CGFloat {
        get { defaults.object(forKey: "gap") as? CGFloat ?? 4 }
        set { defaults.set(newValue, forKey: "gap"); retileAll() }
    }

    /// 期望的窗口宽高比，越大越倾向于"宽而矮"的格子
    var aspect: CGFloat {
        get { defaults.object(forKey: "aspect") as? CGFloat ?? 1.4 }
        set { defaults.set(newValue, forKey: "aspect"); retileAll() }
    }

    /// 是否允许收纳非终端窗口
    var allowAnyWindow: Bool {
        get { defaults.bool(forKey: "allowAnyWindow") }
        set { defaults.set(newValue, forKey: "allowAnyWindow") }
    }

    // MARK: 查询

    var totalCount: Int { groups.values.reduce(0) { $0 + $1.count } }

    func display(of w: WindowRef) -> CGDirectDisplayID? {
        groups.first { $0.value.contains(w) }?.key
    }

    func isManaged(_ w: WindowRef) -> Bool { display(of: w) != nil }

    func count(on d: CGDirectDisplayID) -> Int { groups[d]?.count ?? 0 }

    /// 是否有已收纳的窗口和给定 frame 重合（用来识别原生标签页）
    func hasManagedWindow(withFrame f: CGRect) -> Bool {
        groups.values.joined().contains { $0.frame?.isClose(to: f) == true }
    }

    func accepts(_ w: WindowRef) -> Bool {
        if w.pid == ProcessInfo.processInfo.processIdentifier { return false }
        if isManaged(w) { return true }
        if allowAnyWindow { return true }
        return w.bundleID.map(Self.terminalBundleIDs.contains) ?? false
    }

    // MARK: 增删

    func add(_ w: WindowRef, to d: CGDirectDisplayID, at index: Int? = nil) {
        let old = display(of: w)
        if let old {
            groups[old]?.removeAll { $0 == w }
        } else {
            w.originalFrame = w.frame
        }
        var list = groups[d] ?? []
        if let index, index <= list.count { list.insert(w, at: index) } else { list.append(w) }
        groups[d] = list
        if let old, old != d { retile(old) }
        retile(d)
        WindowEvents.shared.watch(window: w)
        onChange?()
    }

    func remove(_ w: WindowRef, restore: Bool) {
        guard let d = display(of: w) else { return }
        groups[d]?.removeAll { $0 == w }
        if restore, let f = w.originalFrame, AX.isAlive(w.element) {
            AX.setFrame(w.element, f)
        }
        retile(d)
        onChange?()
    }

    func toggle(_ w: WindowRef) {
        if isManaged(w) {
            remove(w, restore: true)
        } else {
            let center = w.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? Coord.mouseAX
            let screen = NSScreen.containing(ax: center) ?? NSScreen.underMouse
            add(w, to: screen.displayID)
        }
    }

    func releaseAll() {
        for list in groups.values {
            for w in list where AX.isAlive(w.element) {
                if let f = w.originalFrame { AX.setFrame(w.element, f) }
            }
        }
        groups.removeAll()
        slots.removeAll()
        onChange?()
    }

    /// 把当前桌面上所有终端窗口收纳到指定屏幕
    func gatherAllTerminals(to d: CGDirectDisplayID) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return Self.terminalBundleIDs.contains(id)
        }
        var list = groups[d] ?? []
        for app in apps {
            for el in AX.windows(pid: app.processIdentifier) {
                guard AX.subrole(el) == kAXStandardWindowSubrole, !AX.isMinimized(el) else { continue }
                let w = WindowRef(el)
                if let old = display(of: w) {
                    if old == d { continue }
                    groups[old]?.removeAll { $0 == w }
                } else {
                    w.originalFrame = w.frame
                }
                list.append(w)
                WindowEvents.shared.watch(window: w)
            }
        }
        groups[d] = list
        retileAll()
        onChange?()
    }

    /// 把所有终端窗口（以及已收纳的窗口）提到最前面，最小化的也恢复出来
    func bringAllToFront() {
        var byApp: [pid_t: [WindowRef]] = [:]
        var seen = Set<WindowRef>()
        func collect(_ w: WindowRef) {
            guard seen.insert(w).inserted else { return }
            byApp[w.pid, default: []].append(w)
        }

        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, Self.terminalBundleIDs.contains(id) else { continue }
            for el in AX.windows(pid: app.processIdentifier) where AX.subrole(el) == kAXStandardWindowSubrole {
                collect(WindowRef(el))
            }
        }
        for list in groups.values {
            for w in list where AX.isAlive(w.element) { collect(w) }
        }
        guard !byApp.isEmpty else { NSSound.beep(); return }

        // 当前在前台的终端最后激活，这样键盘焦点还留在原来那个终端
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var pids = byApp.keys.filter { $0 != front }
        if let front, byApp[front] != nil { pids.append(front) }
        for pid in pids {
            let wins = byApp[pid]!
            for w in wins where AX.isMinimized(w.element) { AX.setMinimized(w.element, false) }
            for w in wins.reversed() { AX.raise(w.element) }
            AX.activate(pid: pid)
        }
    }

    // MARK: 拖放

    /// 拖动结束：dropZone 是松手时鼠标所在收纳区对应的屏幕（如果有的话）
    func handleDrop(_ w: WindowRef, at p: CGPoint, dropZone: CGDirectDisplayID?) {
        if let d = dropZone {
            if display(of: w) == d {
                remove(w, restore: true)
            } else if accepts(w) {
                add(w, to: d)
            }
            return
        }
        guard let current = display(of: w) else { return }
        // 已收纳的窗口被拖到另一个格子上：换位
        if let (targetDisplay, idx) = slot(at: p, excluding: w) {
            if targetDisplay == current, var list = groups[current], let from = list.firstIndex(of: w) {
                list.swapAt(from, idx)
                groups[current] = list
                retile(current)
            } else {
                add(w, to: targetDisplay, at: idx)
            }
        } else {
            retile(current) // 弹回原位
        }
    }

    /// 窗口被拉伸等操作后，弹回格子
    func snapBack(_ w: WindowRef) {
        if let d = display(of: w) { retile(d) }
    }

    private func slot(at p: CGPoint, excluding w: WindowRef) -> (CGDirectDisplayID, Int)? {
        for (d, list) in slots {
            for (other, rect) in list where other != w && rect.contains(p) {
                if let idx = groups[d]?.firstIndex(of: other) { return (d, idx) }
            }
        }
        return nil
    }

    // MARK: 排列

    func retileAll() {
        for d in groups.keys { retile(d) }
    }

    /// 最小化的窗口不占格子
    func retile(_ d: CGDirectDisplayID) {
        guard let screen = NSScreen.with(displayID: d) ?? NSScreen.main else { return }
        let visible = (groups[d] ?? []).filter { AX.isAlive($0.element) && !AX.isMinimized($0.element) }
        let frames = GridLayout.frames(count: visible.count, in: screen.axVisibleFrame, gap: gap, aspect: aspect)
        for (w, f) in zip(visible, frames) { AX.setFrame(w.element, f) }
        slots[d] = Array(zip(visible, frames))
        lastSignature[d] = signature(visible)
    }

    // MARK: 自动补位：窗口数量变化时重排一次（事件触发，不轮询）

    private var lastSignature: [CGDirectDisplayID: [Int]] = [:]
    private var pendingReconcile: DispatchWorkItem?

    private func signature(_ list: [WindowRef]) -> [Int] { list.map { $0.hashValue } }

    /// 事件常常一次来好几个，合并成一次检查
    private func scheduleReconcile() {
        guard !groups.isEmpty else { return }
        pendingReconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func reconcile() {
        var membershipChanged = false
        for (d, original) in groups {
            var list = original
            for i in list.indices.reversed() where !AX.isAlive(list[i].element) {
                if let tab = siblingTab(replacing: list[i], on: d) {
                    list[i] = tab
                } else {
                    list.remove(at: i)
                }
                membershipChanged = true
            }
            groups[d] = list
            // 占格子的窗口数量有变化才重排
            if signature(list.filter { !AX.isMinimized($0.element) }) != lastSignature[d] {
                retile(d)
            }
        }
        groups = groups.filter { !$0.value.isEmpty }
        if membershipChanged { onChange?() }
    }

    /// 系统原生标签页（Terminal、Ghostty）：关掉当前标签时，同一位置会露出同一 App 的
    /// 另一个标签窗口，位置大小完全一样。找到它就原地接替，不让格子空出来。
    private func siblingTab(replacing w: WindowRef, on d: CGDirectDisplayID) -> WindowRef? {
        guard let slot = slots[d]?.first(where: { $0.0 == w })?.1 else { return nil }
        guard let el = AX.windows(pid: w.pid).first(where: { AX.frame($0)?.isClose(to: slot) == true }) else { return nil }
        let tab = WindowRef(el)
        guard !isManaged(tab) else { return nil }
        tab.originalFrame = w.originalFrame
        WindowEvents.shared.watch(window: tab)
        return tab
    }

    /// 屏幕插拔后：消失的屏幕上的窗口挪到主屏
    func screensChanged() {
        let ids = Set(NSScreen.screens.map(\.displayID))
        let main = (NSScreen.main ?? NSScreen.screens[0]).displayID
        for (d, list) in groups where !ids.contains(d) {
            groups[main, default: []].append(contentsOf: list)
            groups[d] = nil
            slots[d] = nil
        }
        retileAll()
        onChange?()
    }
}
