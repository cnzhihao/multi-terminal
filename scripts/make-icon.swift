// 生成 App 图标：swift scripts/make-icon.swift <输出 1024px PNG 路径>
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// 翻转成左上原点，方便按"从上到下"画
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

// macOS 图标规范：1024 画布里主体 824x824，四周留白放阴影
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x141826))
ctx.fillPath()
ctx.restoreGState()

// 背景渐变
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2A3150), rgb(0x0F121C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
// 顶部一点高光
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// 2x2 的小终端窗口
let pad: CGFloat = 92, gap: CGFloat = 40
let tile = (body.width - pad * 2 - gap) / 2
let accents: [UInt32] = [0x5EE6A0, 0x5AC8FA, 0xFFC857, 0xFF6B9A]

for i in 0..<4 {
    let r = CGRect(x: body.minX + pad + CGFloat(i % 2) * (tile + gap),
                   y: body.minY + pad + CGFloat(i / 2) * (tile + gap),
                   width: tile, height: tile)
    let path = CGPath(roundedRect: r, cornerWidth: 44, cornerHeight: 44, transform: nil)
    let accent = accents[i]

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: rgb(0x000000, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x0B0E16))
    ctx.fillPath()
    ctx.restoreGState()

    // 标题栏
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(rgb(0x1E2436))
    ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 58))
    ctx.restoreGState()

    // 三个红绿灯
    for (j, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(rgb(UInt32(c)))
        ctx.fillEllipse(in: CGRect(x: r.minX + 30 + CGFloat(j) * 32, y: r.minY + 20, width: 19, height: 19))
    }

    // 提示符 ">" 和光标
    let px = r.minX + 40, py = r.minY + 108
    ctx.setStrokeColor(rgb(accent))
    ctx.setLineWidth(17)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: px, y: py))
    ctx.addLine(to: CGPoint(x: px + 34, y: py + 30))
    ctx.addLine(to: CGPoint(x: px, y: py + 60))
    ctx.strokePath()
    ctx.setFillColor(rgb(accent))
    ctx.fill(CGRect(x: px + 58, y: py + 50, width: 50, height: 14))

    // 几行"输出"
    let widths: [CGFloat] = [[0.78, 0.55], [0.62, 0.80], [0.70, 0.45], [0.50, 0.72]][i]
    for (k, w) in widths.enumerated() {
        ctx.setFillColor(rgb(0xFFFFFF, 0.22))
        let line = CGRect(x: px, y: py + 100 + CGFloat(k) * 34, width: (r.width - 80) * w, height: 14)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
    }

    // 细描边
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
