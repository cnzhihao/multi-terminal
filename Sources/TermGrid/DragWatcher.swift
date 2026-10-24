import AppKit

/// 监听全局鼠标事件，识别"正在拖动一个窗口"，并在松手时交给 TileManager 处理。
final class DragWatcher {
    private let zones = DropZoneController()
    private var monitors: [Any] = []

    private var window: WindowRef?
    private var startFrame: CGRect?
    private var isWindowDrag = false
    private var lastPoll: TimeInterval = 0

    func start() {
        let add = { (mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
    }

    private func reset() {
        window = nil
        startFrame = nil
        isWindowDrag = false
        if zones.isShowing { zones.hide() }
    }

    private func mouseDown() {
        reset()
        guard let el = AX.window(at: Coord.mouseAX) else { return }
        let w = WindowRef(el)
        guard TileManager.shared.accepts(w) else { return }
        window = w
        startFrame = w.frame
    }

    private func mouseDragged() {
        guard let window, let startFrame else { return }
        if isWindowDrag {
            zones.update(mouse: Coord.mouseAX)
            return
        }
        // 节流：查询窗口位置是跨进程调用
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPoll > 0.05 else { return }
        lastPoll = now
        guard let f = window.frame else { return }
        let moved = abs(f.minX - startFrame.minX) > 3 || abs(f.minY - startFrame.minY) > 3
        let resized = abs(f.width - startFrame.width) > 1 || abs(f.height - startFrame.height) > 1
        if moved && !resized {
            isWindowDrag = true
            zones.show(draggedFrom: TileManager.shared.display(of: window))
            zones.update(mouse: Coord.mouseAX)
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard let window, let startFrame else { return }
        let p = Coord.mouseAX
        if isWindowDrag {
            let zone = zones.zone(at: p)
            zones.hide()
            // 等窗口服务器把拖动收尾后再挪窗口，否则可能被覆盖
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                TileManager.shared.handleDrop(window, at: p, dropZone: zone)
            }
        } else if TileManager.shared.isManaged(window), let f = window.frame, f != startFrame {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                TileManager.shared.snapBack(window)
            }
        }
    }
}
