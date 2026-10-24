import AppKit

/// 拖动窗口时出现在每块屏幕顶部的"收纳区"。
final class DropZoneController {
    private var panels: [CGDirectDisplayID: DropZonePanel] = [:]
    private(set) var isShowing = false

    /// draggedFrom: 正在拖的窗口当前属于哪块屏幕的排列（nil = 未收纳）
    func show(draggedFrom: CGDirectDisplayID?) {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil }

        for screen in screens {
            let id = screen.displayID
            let panel = panels[id] ?? DropZonePanel()
            panels[id] = panel
            let n = TileManager.shared.count(on: id)
            if draggedFrom == id {
                panel.setText("松开 → 移出排列", sub: "恢复到原来的位置")
            } else {
                panel.setText("松开 → 加入排列", sub: n == 0 ? "这块屏幕还没有窗口" : "已有 \(n) 个，加入后自动重排")
            }
            let size = CGSize(width: 340, height: 84)
            let vf = screen.visibleFrame
            panel.setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
            panel.setHighlighted(false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        isShowing = true
    }

    func update(mouse p: CGPoint) {
        let hit = zone(at: p)
        for (id, panel) in panels { panel.setHighlighted(id == hit) }
    }

    /// AX 坐标点落在哪块屏幕的收纳区上（判定范围比面板本身大一圈，好放）
    func zone(at p: CGPoint) -> CGDirectDisplayID? {
        guard isShowing else { return nil }
        for (id, panel) in panels where panel.isVisible {
            if Coord.toAX(panel.frame).insetBy(dx: -30, dy: -30).contains(p) { return id }
        }
        return nil
    }

    func hide() {
        isShowing = false
        for panel in panels.values { panel.orderOut(nil) }
    }
}

final class DropZonePanel: NSPanel {
    private let box = NSVisualEffectView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 18
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 2
        contentView = box

        icon.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = .secondaryLabelColor

        let text = NSStackView(views: [titleLabel, subLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    func setText(_ t: String, sub: String) {
        titleLabel.stringValue = t
        subLabel.stringValue = sub
    }

    func setHighlighted(_ on: Bool) {
        box.layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.15)).cgColor
        box.layer?.backgroundColor = (on ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.clear).cgColor
        icon.contentTintColor = on ? .white : .controlAccentColor
    }
}
