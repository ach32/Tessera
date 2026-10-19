import Foundation
import CoreGraphics

public struct LayoutParams {
    /// How many folder levels below the zoom root show their contents.
    public var detailLevel: Int = 3
    /// Elements smaller than this in either direction are not drawn (still counted).
    public var minElementSize: CGFloat = 4
    /// Height of a folder's name strip.
    public var headerHeight: CGFloat = 15
    /// Gap between a folder's edge and its children.
    public var padding: CGFloat = 2
    /// Preferred element proportions: 1 = square, 2 = twice as wide as tall.
    public var proportion: CGFloat = 1
    /// Biggest first, from the top-left.
    public var sorted: Bool = true
    /// Folders that always show their children (the path to the selection).
    public var alwaysExpand: Set<ObjectIdentifier> = []

    public init() {}
}

public struct LayoutItem {
    public let node: FileNode
    public let rect: CGRect
    public let depth: Int
    /// Children were laid out inside it.
    public let expanded: Bool
    /// Rect of the name strip (zero when there is none).
    public let header: CGRect
    public let parent: Int
}

public enum TreemapLayout {
    /// Lays out `root` and its visible descendants inside `rect`.
    /// `size` gives the area weight of a node (filtered or plain). `extras` are synthetic
    /// siblings for the root's children (free space, unknown space).
    public static func layout(root: FileNode,
                              in rect: CGRect,
                              params: LayoutParams,
                              extras: [(FileNode, Int64)] = [],
                              size: (FileNode) -> Int64) -> [LayoutItem] {
        var items: [LayoutItem] = []
        items.reserveCapacity(512)
        guard rect.width >= 1, rect.height >= 1 else { return items }
        place(root, rect: rect, depth: 0, parent: -1, extras: extras, params: params, size: size, items: &items)
        return items
    }

    private static func place(_ node: FileNode, rect: CGRect, depth: Int, parent: Int,
                              extras: [(FileNode, Int64)], params: LayoutParams,
                              size: (FileNode) -> Int64, items: inout [LayoutItem]) {
        let canHaveChildren = node.isContainer && (!node.children.isEmpty || !extras.isEmpty)
        let wantsChildren = canHaveChildren &&
            (depth < params.detailLevel || params.alwaysExpand.contains(ObjectIdentifier(node)) || depth == 0)

        var header = CGRect.zero
        var inner = rect
        if node.isContainer && rect.height >= params.headerHeight * 2 && rect.width >= 24 {
            header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: params.headerHeight)
            inner = CGRect(x: rect.minX + params.padding,
                           y: rect.minY + params.headerHeight,
                           width: rect.width - params.padding * 2,
                           height: rect.height - params.headerHeight - params.padding)
        } else if node.isContainer {
            inner = rect.insetBy(dx: params.padding, dy: params.padding)
        }
        let roomy = inner.width >= params.minElementSize * 2 && inner.height >= params.minElementSize * 2
        let expand = wantsChildren && roomy

        let index = items.count
        items.append(LayoutItem(node: node, rect: rect, depth: depth, expanded: expand, header: header, parent: parent))
        guard expand else { return }

        var kids: [(FileNode, Double)] = []
        kids.reserveCapacity(node.children.count + extras.count)
        for c in node.children {
            let s = size(c)
            if s > 0 { kids.append((c, Double(s))) }
        }
        for (n, s) in extras where s > 0 { kids.append((n, Double(s))) }
        guard !kids.isEmpty else { return }

        if params.sorted {
            kids.sort { $0.1 > $1.1 }
        }
        let total = kids.reduce(0) { $0 + $1.1 }
        let area = Double(inner.width * inner.height)
        guard total > 0, area > 0 else { return }

        // Drop what would be smaller than the minimum element in area; it stays counted
        // in `total`, so the space it would take is left empty.
        let minArea = Double(params.minElementSize * params.minElementSize)
        let scale = area / total
        let shown = kids.filter { $0.1 * scale >= minArea }
        if shown.isEmpty { return }

        let areas = shown.map { $0.1 * scale }
        let rects = squarify(areas: areas, in: inner, proportion: Double(params.proportion), fill: total * scale)
        for (i, r) in rects.enumerated() {
            guard r.width >= params.minElementSize, r.height >= params.minElementSize else { continue }
            place(shown[i].0, rect: r.integralish, depth: depth + 1, parent: index,
                  extras: [], params: params, size: size, items: &items)
        }
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). `areas` are in px², in the order given.
    /// With `proportion` != 1 the layout is computed in a stretched space so elements tend
    /// towards that width:height ratio.
    public static func squarify(areas: [Double], in rect: CGRect, proportion: Double = 1, fill: Double? = nil) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: areas.count)
        guard !areas.isEmpty, rect.width > 0, rect.height > 0 else { return out }
        let p = max(0.2, min(5, proportion))

        // Work in a space where the width is divided by p.
        var x = 0.0, y = 0.0
        var w = Double(rect.width) / p
        var h = Double(rect.height)
        let areaScale = 1 / p
        // If the shown areas do not fill the rect (small items dropped), shrink the space
        // along the long side so the gap ends up at the end, not spread out.
        let shownTotal = areas.reduce(0, +) * areaScale
        let fullTotal = (fill ?? areas.reduce(0, +)) * areaScale
        if fullTotal > 0 && shownTotal < fullTotal * 0.999 {
            let k = shownTotal / fullTotal
            if w >= h { w *= k } else { h *= k }
        }

        var i = 0
        let n = areas.count
        while i < n {
            let short = min(w, h)
            guard short > 0 else { break }
            var rowSum = areas[i] * areaScale
            var rowMin = rowSum, rowMax = rowSum
            var best = worst(sum: rowSum, min: rowMin, max: rowMax, side: short)
            var j = i + 1
            while j < n {
                let a = areas[j] * areaScale
                let s = rowSum + a
                let mn = Swift.min(rowMin, a), mx = Swift.max(rowMax, a)
                let r = worst(sum: s, min: mn, max: mx, side: short)
                if r > best { break }
                rowSum = s; rowMin = mn; rowMax = mx; best = r
                j += 1
            }
            if w >= h {
                // A column on the left.
                let colW = h > 0 ? rowSum / h : 0
                var yy = y
                for k in i..<j {
                    let hh = colW > 0 ? areas[k] * areaScale / colW : 0
                    out[k] = CGRect(x: x, y: yy, width: colW, height: hh)
                    yy += hh
                }
                x += colW; w -= colW
            } else {
                // A row on top.
                let rowH = w > 0 ? rowSum / w : 0
                var xx = x
                for k in i..<j {
                    let ww = rowH > 0 ? areas[k] * areaScale / rowH : 0
                    out[k] = CGRect(x: xx, y: y, width: ww, height: rowH)
                    xx += ww
                }
                y += rowH; h -= rowH
            }
            i = j
        }
        // Back to real space.
        return out.map { r in
            CGRect(x: rect.minX + r.minX * p, y: rect.minY + r.minY, width: r.width * p, height: r.height)
        }
    }

    @inline(__always)
    private static func worst(sum: Double, min: Double, max: Double, side: Double) -> Double {
        guard sum > 0, min > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }

    /// Index of the deepest item containing the point.
    public static func hitTest(_ items: [LayoutItem], _ point: CGPoint) -> Int? {
        var i = items.count - 1
        while i >= 0 {
            if items[i].rect.contains(point) { return i }
            i -= 1
        }
        return nil
    }
}

extension CGRect {
    /// Snaps edges to whole pixels so neighbours share an edge without gaps or overlap.
    var integralish: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        let x1 = maxX.rounded(), y1 = maxY.rounded()
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
