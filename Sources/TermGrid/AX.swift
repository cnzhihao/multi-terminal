import AppKit
import ApplicationServices

/// 对一个外部窗口（AXUIElement）的引用。用 CFEqual 判断是否为同一窗口。
final class WindowRef: Hashable {
    let element: AXUIElement
    let pid: pid_t
    /// 加入排列前的位置，释放时恢复
    var originalFrame: CGRect?

    init(_ element: AXUIElement) {
        self.element = element
        var p: pid_t = 0
        AXUIElementGetPid(element, &p)
        self.pid = p
    }

    static func == (a: WindowRef, b: WindowRef) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }

    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    var frame: CGRect? { AX.frame(element) }
}

/// 辅助功能 API 的薄封装。所有坐标都是 AX/CG 全局坐标：主屏左上角为原点，y 向下。
enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func setGlobalTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    private static func copy(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { copy(e, name) as? String }
    static func bool(_ e: AXUIElement, _ name: String) -> Bool { (copy(e, name) as? Bool) ?? false }

    static func role(_ e: AXUIElement) -> String? { string(e, kAXRoleAttribute) }
    static func subrole(_ e: AXUIElement) -> String? { string(e, kAXSubroleAttribute) }
    static func isMinimized(_ e: AXUIElement) -> Bool { bool(e, kAXMinimizedAttribute) }

    /// 窗口是否还存在（关闭后会返回 invalidUIElement）
    static func isAlive(_ e: AXUIElement) -> Bool {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
        return err != .invalidUIElement
    }

    /// 鼠标位置下方的窗口
    static func window(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
              let el else { return nil }
        if role(el) == kAXWindowRole { return el }
        return element(copy(el, kAXWindowAttribute))
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        element(copy(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute))
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        guard let arr = copy(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AnyObject] else { return [] }
        return arr.compactMap { element($0) }
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = copy(e, kAXPositionAttribute), let sv = copy(e, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ e: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return }
        // 先改大小再挪位置再改一次大小：跨屏移动时避免被旧屏幕边界裁掉
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sv)
    }

    static func raise(_ e: AXUIElement) {
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
    }

    static func setMinimized(_ e: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, on as CFBoolean)
    }

    /// 把 App 切到前台。NSRunningApplication.activate 在后台调用时可能被系统拒绝，
    /// 所以同时通过 AX 设置 frontmost，这条路在有辅助功能权限时总是生效。
    static func activate(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

// MARK: - 坐标转换（AppKit 左下原点 <-> AX 左上原点）

enum Coord {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAX(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    static var mouseAX: CGPoint { toAX(NSEvent.mouseLocation) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var axFrame: CGRect { Coord.toAX(frame) }
    var axVisibleFrame: CGRect { Coord.toAX(visibleFrame) }

    static func with(displayID id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }

    /// AX 坐标点所在的屏幕
    static func containing(ax p: CGPoint) -> NSScreen? {
        screens.first { $0.axFrame.contains(p) }
    }

    static var underMouse: NSScreen {
        containing(ax: Coord.mouseAX) ?? NSScreen.main ?? screens[0]
    }
}
