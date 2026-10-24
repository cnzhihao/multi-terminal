import CoreGraphics

/// 网格排列算法：给定窗口数量和可用区域，算出每个窗口的 frame。
///
/// 思路：枚举行数 r（1...n），把 n 个窗口尽量平均地分到 r 行里，
/// 然后看"最挤的那一格"能放下多大的、宽高比为 aspect 的矩形——这个值最大的方案胜出。
/// 这样窗口既能铺满屏幕，又不会被切成又细又长、没法看的条。
enum GridLayout {
    static func frames(count n: Int, in area: CGRect, gap: CGFloat, aspect: CGFloat) -> [CGRect] {
        guard n > 0, area.width > 0, area.height > 0 else { return [] }

        var bestRows = 1
        var bestScore = -CGFloat.infinity
        for rows in 1...n {
            let maxCols = Int((Double(n) / Double(rows)).rounded(.up))
            let w = (area.width - gap * CGFloat(maxCols + 1)) / CGFloat(maxCols)
            let h = (area.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let score = min(w / aspect, h)
            if score > bestScore + 0.5 {   // 分数几乎相同时优先行数少（左右并排）
                bestScore = score
                bestRows = rows
            }
        }

        // 平均分配到每一行：前 extra 行多放一个
        let rows = bestRows
        let base = n / rows, extra = n % rows
        let h = (area.height - gap * CGFloat(rows + 1)) / CGFloat(rows)

        var result: [CGRect] = []
        for r in 0..<rows {
            let cols = base + (r < extra ? 1 : 0)
            let w = (area.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let y = area.minY + gap + CGFloat(r) * (h + gap)
            for c in 0..<cols {
                let x = area.minX + gap + CGFloat(c) * (w + gap)
                result.append(CGRect(x: x, y: y, width: w, height: h).integral)
            }
        }
        return result
    }
}
