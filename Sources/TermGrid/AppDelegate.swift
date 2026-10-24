import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()
    private let tiles = TileManager.shared
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "TermGrid")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tiles.onChange = { [weak self] in self?.refreshBadge() }
        AX.setGlobalTimeout()
        watcher.start()

        // ⌃⌥F 所有终端置前，⌃⌥T 收纳/移出当前窗口，⌃⌥G 收纳全部终端，⌃⌥R 重新排列
        let mods = controlKey | optionKey
        HotKey.register(keyCode: kVK_ANSI_F, modifiers: mods) { [weak self] in self?.bringAllToFront() }
        HotKey.register(keyCode: kVK_ANSI_T, modifiers: mods) { [weak self] in self?.toggleFrontWindow() }
        HotKey.register(keyCode: kVK_ANSI_G, modifiers: mods) { [weak self] in self?.gatherAll() }
        HotKey.register(keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in self?.retile() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            TileManager.shared.screensChanged()
        }

        if !AX.isTrusted(prompt: true) {
            // 授权后自动生效，不用重启
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if AX.isTrusted(prompt: false) { t.invalidate(); self?.refreshBadge() }
            }
        }
        refreshBadge()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tiles.releaseAll()
    }

    private func refreshBadge() {
        let n = tiles.totalCount
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AX.isTrusted(prompt: false) {
            menu.addItem(item("⚠️ 需要“辅助功能”权限，点此打开设置", #selector(openAXSettings)))
            menu.addItem(.separator())
        }

        let n = tiles.totalCount
        let header = NSMenuItem(title: n == 0 ? "还没有收纳窗口——把终端拖到屏幕顶部的收纳区" : "已排列 \(n) 个窗口",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("所有终端置前", #selector(bringAllToFront), key: "f"))
        menu.addItem(item("收纳所有终端到当前屏幕", #selector(gatherAll), key: "g"))
        menu.addItem(item("收纳 / 移出当前窗口", #selector(toggleFrontWindow), key: "t"))
        menu.addItem(item("重新排列", #selector(retile), key: "r"))
        menu.addItem(item("全部释放（恢复原位置）", #selector(releaseAll)))
        menu.addItem(.separator())

        let gapMenu = NSMenu()
        for (title, v) in [("无", 0.0), ("细", 4.0), ("中", 8.0), ("宽", 16.0)] {
            let it = item(title, #selector(setGap(_:)))
            it.representedObject = v
            it.state = tiles.gap == CGFloat(v) ? .on : .off
            gapMenu.addItem(it)
        }
        menu.addItem(submenu("窗口间距", gapMenu))

        let aspectMenu = NSMenu()
        for (title, v) in [("偏高（适合看长输出）", 0.9), ("均衡", 1.4), ("偏宽（适合长命令行）", 2.2)] {
            let it = item(title, #selector(setAspect(_:)))
            it.representedObject = v
            it.state = abs(tiles.aspect - CGFloat(v)) < 0.01 ? .on : .off
            aspectMenu.addItem(it)
        }
        menu.addItem(submenu("格子形状", aspectMenu))

        let any = item("允许收纳任意 App 的窗口", #selector(toggleAnyWindow))
        any.state = tiles.allowAnyWindow ? .on : .off
        menu.addItem(any)

        menu.addItem(.separator())
        menu.addItem(item("使用说明", #selector(showHelp)))
        menu.addItem(item("退出 TermGrid", #selector(quit), key: "q", modifiers: [.command]))
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [.control, .option]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = modifiers
        it.target = self
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    // MARK: 动作

    @objc private func gatherAll() {
        tiles.gatherAllTerminals(to: NSScreen.underMouse.displayID)
    }

    @objc private func toggleFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let el = AX.focusedWindow(pid: app.processIdentifier) else { NSSound.beep(); return }
        let w = WindowRef(el)
        guard tiles.accepts(w) else { NSSound.beep(); return }
        tiles.toggle(w)
    }

    @objc private func retile() { tiles.retileAll() }
    @objc private func bringAllToFront() { tiles.bringAllToFront() }
    @objc private func releaseAll() { tiles.releaseAll() }

    @objc private func setGap(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { tiles.gap = CGFloat(v) }
    }

    @objc private func setAspect(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { tiles.aspect = CGFloat(v) }
    }

    @objc private func toggleAnyWindow() { tiles.allowAnyWindow.toggle() }

    @objc private func openAXSettings() {
        _ = AX.isTrusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "TermGrid 使用说明"
        alert.informativeText = """
        • 拖动任意终端窗口，屏幕顶部会出现收纳区，拖进去松手就会加入排列，所有收纳的窗口自动铺满屏幕。
        • 已排列的窗口再拖到收纳区 → 移出排列并恢复原位置。
        • 已排列的窗口拖到另一个窗口上 → 两者交换位置；拖到别处 → 弹回原格子。
        • 多块屏幕各自独立排列，拖到哪块屏幕的收纳区就排在哪块屏幕上。
        • 关闭或最小化窗口后会自动重新排列。

        快捷键：
        ⌃⌥F  所有终端置前
        ⌃⌥G  收纳所有终端到当前屏幕
        ⌃⌥T  收纳 / 移出当前窗口
        ⌃⌥R  重新排列
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
