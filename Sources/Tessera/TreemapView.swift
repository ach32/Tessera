import AppKit
import Quartz
import QuartzCore
import TesseraCore

@MainActor
protocol TreemapHost: AnyObject {
    /// Zoom, selection, detail or style changed.
    func treemapStateChanged()
    func treemapHoverChanged(_ node: FileNode?)
    func treemapDropped(urls: [URL])
    func treemapRescan(_ node: FileNode)
}

/// The treemap canvas: drawing, hit testing, navigation, selection and tags for one view.
@MainActor
final class TreemapView: NSView {
    let session: ScanSession
    weak var host: TreemapHost?

    // View state
    private(set) var zoomNode: FileNode
    private var backStack: [FileNode] = []
    private var forwardStack: [FileNode] = []
    private(set) var selection: FileNode?
    var detailLevel: Int { didSet { invalidateLayout() } }
    var style: ViewStyle { didSet { needsDisplay = true } }
    var showFree: Bool { didSet { invalidateLayout() } }
    var showUnknown: Bool { didSet { invalidateLayout() } }

    // Layout and drawing
    private var items: [LayoutItem] = []
    private var layoutDirty = true
    private var layoutSize: CGSize = .zero
    private var settings: AppSettings
    private var classColors: [String: NSColor] = [:]
    private var flat: (volume: NSColor, folder: NSColor, file: NSColor, free: NSColor, unknown: NSColor)

    // Mouse
    private(set) var hoverNode: FileNode?
    private var mousePoint: CGPoint?
    private(set) var mouseInside = false
    private(set) var lastInteraction = Date()
    private var tooltipVisible = false
    private var tooltipTimer: Timer?
    private var trail: [(node: FileNode, at: Double)] = []
    private var magnifyAccumulator: CGFloat = 0

    // Animation
    private struct ZoomAnimation {
        var image: NSImage
        var from: CGRect      // where the old picture starts (view coords)
        var to: CGRect        // where it ends
        var zoomingIn: Bool
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }
    private var zoomAnimation: ZoomAnimation?
    private var animationTimer: Timer?
    private var blinkTimer: Timer?

    private let quickLook = QuickLookSource()

    static let barWidth: CGFloat = 5

    init(session: ScanSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        zoomNode = session.root
        detailLevel = settings.initialDetail
        style = settings.defaultStyle
        showFree = settings.showFreeSpace
        showUnknown = settings.showUnknownSpace
        flat = (NSColor(hex: settings.colors.volume), NSColor(hex: settings.colors.folder), NSColor(hex: settings.colors.file),
                NSColor(hex: settings.colors.free), NSColor(hex: settings.colors.unknown))
        super.init(frame: .zero)
        rebuildClassColors()
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Treemap", "Карта диска"))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func apply(settings s: AppSettings) {
        settings = s
        flat = (NSColor(hex: s.colors.volume), NSColor(hex: s.colors.folder), NSColor(hex: s.colors.file),
                NSColor(hex: s.colors.free), NSColor(hex: s.colors.unknown))
        rebuildClassColors()
        invalidateLayout()
    }

    private func rebuildClassColors() {
        classColors = [:]
        for cls in settings.fileClasses {
            let color = NSColor(hex: cls.color)
            for ext in cls.extensions where !ext.isEmpty && classColors[ext] == nil { classColors[ext] = color }
        }
    }

    func invalidateLayout() {
        layoutDirty = true
        needsDisplay = true
    }

    func stop() {
        tooltipTimer?.invalidate()
        animationTimer?.invalidate()
        blinkTimer?.invalidate()
    }

    // MARK: Geometry

    private var mapRect: CGRect {
        var r = bounds
        r.origin.x += TreemapView.barWidth + 1
        r.size.width -= TreemapView.barWidth + 1
        if session.isSnapshot {
            r.origin.y += bannerHeight
            r.size.height -= bannerHeight
        }
        return r
    }

    private var bannerHeight: CGFloat { CGFloat(settings.fontSize) + 8 }

    private var lineHeight: CGFloat { CGFloat(settings.fontSize) + 3 }

    private func ensureLayout() {
        guard layoutDirty || layoutSize != bounds.size else { return }
        layoutDirty = false
        layoutSize = bounds.size
        if !zoomNode.isDescendant(of: session.root) { zoomNode = session.root }
        if let s = selection, !s.isSynthetic, !s.isDescendant(of: session.root) { selection = nil }

        var p = LayoutParams()
        p.detailLevel = detailLevel
        p.minElementSize = CGFloat(settings.minElementSize)
        p.headerHeight = lineHeight + 1
        p.padding = 2
        p.proportion = CGFloat(settings.proportion)
        p.sorted = settings.sortItems
        if let s = selection, s.isDescendant(of: zoomNode) {
            var set: Set<ObjectIdentifier> = []
            var n: FileNode? = s
            while let c = n, c !== zoomNode {
                if c.isContainer { set.insert(ObjectIdentifier(c)) }
                n = c.parent
            }
            p.alwaysExpand = set
        }
        let extras = zoomNode === session.root ? session.extras(showFree: showFree, showUnknown: showUnknown) : []
        let sess = session
        items = TreemapLayout.layout(root: zoomNode, in: mapRect, params: p, extras: extras) { sess.weight($0) }
        if let h = hoverNode, !items.contains(where: { $0.node === h }) { hoverNode = nil }
    }

    func item(at point: CGPoint) -> LayoutItem? {
        ensureLayout()
        return TreemapLayout.hitTest(items, point).map { items[$0] }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.canvas.setFill()
        bounds.fill()
        ensureLayout()

        let now = Date().timeIntervalSince1970
        let halo = haloSet()
        let trailMap = settings.mouseTrail ? trailStrength(now: now) : [:]
        var blinking = false
        let font = NSFont.systemFont(ofSize: CGFloat(settings.fontSize), weight: .medium)
        let bold = NSFont.systemFont(ofSize: CGFloat(settings.fontSize), weight: .bold)
        let filter = session.filter

        for item in items {
            let r = item.rect
            guard r.intersects(dirtyRect) else { continue }
            var fill = fillColor(for: item)
            if item.node === hoverNode && settings.hoverHighlight {
                fill = fill.lighter(0.22)
            } else if let level = halo[ObjectIdentifier(item.node)] {
                fill = fill.lighter(0.10 / CGFloat(level))
            }
            if let t = trailMap[ObjectIdentifier(item.node)] { fill = fill.lighter(0.18 * t) }

            fill.setFill()
            r.fill()
            if item.expanded && item.header != .zero {
                fill.darker(0.12).setFill()
                item.header.fill()
            }

            // border
            let alpha = CGFloat(settings.borderContrast) * 0.8
            if alpha > 0 && r.width > 2 && r.height > 2 {
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            }

            let textColor = Theme.text(on: fill)
            if item.expanded && item.header != .zero {
                drawHeader(item, font: (filter?.highlightsFolder(item.node.name) == true && item.parent >= 0) ? bold : font, color: textColor)
            } else if !item.expanded || item.node.isFile {
                drawLabel(item, font: font, color: textColor)
            }

            if item.node.tag != .none { drawTagBadge(r, item.node.tag) }

            let age = now - item.node.changedAt
            if item.node.changedAt > 0 && age < 2 {
                blinking = true
                let pulse = (0.5 + 0.5 * cos(age * .pi * 4)) * (1 - age / 2)
                Theme.accent.withAlphaComponent(CGFloat(0.7 * pulse)).setFill()
                r.insetBy(dx: 1, dy: 1).fill()
            }
        }

        drawSelection(ctx)
        drawViewableBar()
        if session.isSnapshot { drawBanner() }
        drawEmptyState()
        drawZoomAnimation()
        if tooltipVisible { drawTooltip() }

        if blinking || (settings.mouseTrail && !trailMap.isEmpty) {
            if blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(timeInterval: 1.0 / 20.0, target: self, selector: #selector(blinkTick(_:)), userInfo: nil, repeats: false)
            }
        }
    }

    @objc private func blinkTick(_ t: Timer) {
        blinkTimer = nil
        needsDisplay = true
    }

    private func fillColor(for item: LayoutItem) -> NSColor {
        let n = item.node
        var base: NSColor
        switch n.kind {
        case .volume: base = flat.volume
        case .folder: base = flat.folder
        case .mountPoint: base = flat.folder.mixed(with: flat.unknown, 0.5)
        case .file: base = style == .classes ? (classColors[n.fileExtension] ?? flat.file) : flat.file
        case .freeSpace: base = flat.free
        case .unknownSpace: base = flat.unknown
        case .purgeable: base = flat.free.mixed(with: flat.unknown, 0.45)
        }
        if n.isContainer && !n.isSynthetic {
            if n.state == .pending { base = base.mixed(with: Theme.canvas, 0.35) }
            if n.state == .denied { base = base.mixed(with: flat.unknown, 0.6) }
        }
        let k = min(0.65, CGFloat(settings.levelContrast) * 0.10 * CGFloat(item.depth))
        return base.darker(k)
    }

    private func attributes(_ font: NSFont, _ color: NSColor, align: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.alignment = align
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    private func drawHeader(_ item: LayoutItem, font: NSFont, color: NSColor) {
        let h = item.header.insetBy(dx: 4, dy: 0)
        guard h.width > 16 else { return }
        let sizeText = Format.size(session.weight(item.node), decimal: settings.decimalUnits) as NSString
        let sizeAttrs = attributes(font, color.withAlphaComponent(0.8), align: .right)
        let sizeWidth = sizeText.size(withAttributes: sizeAttrs).width
        let name = (item.parent < 0 ? displayTitle(item.node) : item.node.name) as NSString
        var nameRect = CGRect(x: h.minX, y: h.minY + 1, width: h.width, height: lineHeight)
        if h.width > sizeWidth + 60 {
            sizeText.draw(with: CGRect(x: h.minX, y: h.minY + 1, width: h.width, height: lineHeight),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: sizeAttrs)
            nameRect.size.width -= sizeWidth + 8
        }
        name.draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                  attributes: attributes(font, color, align: .left))
    }

    private func drawLabel(_ item: LayoutItem, font: NSFont, color: NSColor) {
        let r = item.rect.insetBy(dx: 3, dy: 2)
        guard r.width >= 28, r.height >= lineHeight else { return }
        let attrs = attributes(font, color, align: .center)
        let two = r.height >= lineHeight * 2 + 2
        let total = two ? lineHeight * 2 : lineHeight
        let y = r.midY - total / 2
        var name = item.node.name
        if item.node.kind == .mountPoint { name += tr(" (other volume)", " (другой том)") }
        if item.parent < 0 { name = displayTitle(item.node) }
        (name as NSString).draw(with: CGRect(x: r.minX, y: y, width: r.width, height: lineHeight),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        if two {
            let size = Format.size(session.weight(item.node), decimal: settings.decimalUnits)
            (size as NSString).draw(with: CGRect(x: r.minX, y: y + lineHeight, width: r.width, height: lineHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes(font, color.withAlphaComponent(0.8), align: .center))
        }
    }

    private func displayTitle(_ n: FileNode) -> String {
        if n === session.root {
            if let v = session.volume, v.isVolumeRoot { return v.name }
            return n.path
        }
        return n.path
    }

    private func drawTagBadge(_ r: CGRect, _ tag: Tag) {
        let s = min(9, r.width / 3, r.height / 3)
        guard s >= 3 else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: r.maxX - s, y: r.minY))
        path.line(to: CGPoint(x: r.maxX, y: r.minY))
        path.line(to: CGPoint(x: r.maxX, y: r.minY + s))
        path.close()
        Theme.tagColor(tag).setFill()
        path.fill()
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let sel = selection else { return }
        // The selection, or its closest ancestor that is on screen.
        var target: LayoutItem?
        var n: FileNode? = sel
        while let c = n, target == nil {
            target = items.first { $0.node === c }
            n = c.parent
        }
        guard let item = target else { return }
        let r = item.rect.insetBy(dx: 1, dy: 1)
        ctx.saveGState()
        if settings.dropShadow {
            ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: NSColor.black.withAlphaComponent(0.75).cgColor)
        }
        ctx.setStrokeColor(Theme.selectionOuter.cgColor)
        ctx.setLineWidth(4)
        ctx.stroke(r)
        ctx.restoreGState()
        ctx.setStrokeColor(Theme.accent.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r)
    }

    private func drawViewableBar() {
        let rootWeight = session.weight(session.root)
        guard rootWeight > 0 else { return }
        let ratio = zoomNode === session.root ? 1 : min(1, Double(session.weight(zoomNode)) / Double(rootWeight))
        let full = mapRect
        NSColor.white.withAlphaComponent(0.08).setFill()
        CGRect(x: 0, y: full.minY, width: TreemapView.barWidth, height: full.height).fill()
        let h = max(2, full.height * CGFloat(ratio))
        Theme.accent.setFill()
        CGRect(x: 0, y: full.maxY - h, width: TreemapView.barWidth, height: h).fill()
    }

    private func drawBanner() {
        let r = CGRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
        NSColor(hex: "#3A3F47").setFill()
        r.fill()
        let text = tr("Snapshot: \(session.snapshotName ?? "") — not live", "Снимок: \(session.snapshotName ?? "") — не обновляется") as NSString
        text.draw(with: r.insetBy(dx: 10, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                  attributes: attributes(.systemFont(ofSize: CGFloat(settings.fontSize), weight: .semibold), Theme.tooltipText, align: .left))
    }

    private func drawEmptyState() {
        guard session.weight(zoomNode) == 0 else { return }
        let message: String
        if session.filter != nil {
            message = tr("Nothing here matches the filter.", "Здесь ничего не подходит под фильтр.")
        } else if session.isScanning || zoomNode.state == .pending {
            message = tr("Scanning…", "Сканирую…")
        } else if zoomNode.state == .denied {
            message = tr("Tessera isn't allowed to read this folder.", "Tessera не может прочитать эту папку.")
        } else {
            message = tr("This folder is empty.", "Папка пуста.")
        }
        let attrs = attributes(.systemFont(ofSize: 15, weight: .medium), Theme.tooltipMuted, align: .center)
        let r = mapRect
        (message as NSString).draw(with: CGRect(x: r.minX, y: r.midY - 10, width: r.width, height: 22),
                                   options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // MARK: Zoom animation

    private func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func drawZoomAnimation() {
        guard let a = zoomAnimation else { return }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration)
        let e = CGFloat(1 - pow(1 - t, 3))   // ease out
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * e }
        let r = CGRect(x: lerp(a.from.minX, a.to.minX), y: lerp(a.from.minY, a.to.minY),
                       width: lerp(a.from.width, a.to.width), height: lerp(a.from.height, a.to.height))
        let alpha = a.zoomingIn ? 1 - e * 0.6 : 1 - e
        a.image.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    private func startZoomAnimation(from oldImage: NSImage?, oldZoomRect: CGRect?, zoomingIn: Bool) {
        guard settings.zoomDuration > 0.01, let img = oldImage else { return }
        let full = bounds
        let a: ZoomAnimation
        if zoomingIn, let src = oldZoomRect, src.width > 1, src.height > 1 {
            // Blow the old picture up so the clicked folder fills the view.
            let sx = full.width / src.width, sy = full.height / src.height
            let to = CGRect(x: full.minX - (src.minX - full.minX) * sx, y: full.minY - (src.minY - full.minY) * sy,
                            width: full.width * sx, height: full.height * sy)
            a = ZoomAnimation(image: img, from: full, to: to, zoomingIn: true, start: CACurrentMediaTime(), duration: settings.zoomDuration)
        } else if !zoomingIn, let dst = oldZoomRect {
            a = ZoomAnimation(image: img, from: full, to: dst, zoomingIn: false, start: CACurrentMediaTime(), duration: settings.zoomDuration)
        } else {
            return
        }
        zoomAnimation = a
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(animationTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    @objc private func animationTick(_ t: Timer) {
        guard let a = zoomAnimation else { t.invalidate(); return }
        if CACurrentMediaTime() - a.start >= a.duration {
            zoomAnimation = nil
            t.invalidate()
            animationTimer = nil
        }
        needsDisplay = true
    }

    // MARK: Navigation

    var canGoBack: Bool { backStack.contains { $0.isDescendant(of: session.root) } }
    var canGoForward: Bool { forwardStack.contains { $0.isDescendant(of: session.root) } }
    var canGoUp: Bool { zoomNode !== session.root }

    func zoom(into node: FileNode, recordHistory: Bool = true) {
        guard !node.isSynthetic else { return }
        let target = node.isContainer ? node : (node.parent ?? session.root)
        guard target !== zoomNode else { return }
        ensureLayout()
        let oldRect = items.first { $0.node === target }?.rect
        let zoomingIn = target.isDescendant(of: zoomNode)
        let previous = zoomNode
        let image = snapshotImage()
        if recordHistory {
            backStack.append(previous)
            forwardStack.removeAll()
        }
        zoomNode = target
        layoutDirty = true
        ensureLayout()
        if zoomingIn {
            startZoomAnimation(from: image, oldZoomRect: oldRect, zoomingIn: true)
        } else {
            let landing = items.first { $0.node === previous }?.rect
            startZoomAnimation(from: image, oldZoomRect: landing, zoomingIn: false)
        }
        noteInteraction()
        needsDisplay = true
        host?.treemapStateChanged()
    }

    func goBack() {
        while let n = backStack.popLast() {
            guard n.isDescendant(of: session.root) else { continue }
            forwardStack.append(zoomNode)
            zoom(into: n, recordHistory: false)
            return
        }
    }

    func goForward() {
        while let n = forwardStack.popLast() {
            guard n.isDescendant(of: session.root) else { continue }
            backStack.append(zoomNode)
            zoom(into: n, recordHistory: false)
            return
        }
    }

    func goUp() {
        guard let p = zoomNode.parent else { return }
        zoom(into: p)
    }

    func goHome() {
        guard zoomNode !== session.root else { return }
        zoom(into: session.root)
    }

    func select(_ node: FileNode?) {
        guard selection !== node else { return }
        selection = node
        invalidateLayout()
        host?.treemapStateChanged()
    }

    func lessDetail() { if detailLevel > 0 { detailLevel -= 1; host?.treemapStateChanged() } }
    func moreDetail() { if detailLevel < 30 { detailLevel += 1; host?.treemapStateChanged() } }

    /// Hovered element first (like the original), else the selection.
    var actionTarget: FileNode? {
        if let h = hoverNode, mouseInside, !h.isSynthetic { return h }
        if let s = selection, !s.isSynthetic { return s }
        return nil
    }

    func applyTag(_ tag: Tag) {
        guard let n = actionTarget else { NSSound.beep(); return }
        if tag == .none { session.toggleTag(n.tag, on: n) } else { session.toggleTag(tag, on: n) }
        invalidateLayout()
    }

    func clearTagsInZoom() {
        session.clearTags(under: zoomNode)
        invalidateLayout()
    }

    private func noteInteraction() { lastInteraction = Date() }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        mousePoint = nil
        setHover(nil)
        hideTooltip()
    }

    override func mouseMoved(with event: NSEvent) {
        mouseInside = true
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p
        noteInteraction()
        setHover(item(at: p)?.node)
        if tooltipVisible { needsDisplay = true }
    }

    private func setHover(_ node: FileNode?) {
        guard node !== hoverNode else { return }
        if let old = hoverNode, settings.mouseTrail {
            trail.append((old, Date().timeIntervalSince1970))
            if trail.count > 24 { trail.removeFirst(trail.count - 24) }
        }
        hoverNode = node
        needsDisplay = true
        host?.treemapHoverChanged(node)

        if tooltipVisible {
            if node == nil || !settings.keepTooltipOnMove { hideTooltip() }
        }
        if node != nil && !tooltipVisible {
            tooltipTimer?.invalidate()
            tooltipTimer = Timer.scheduledTimer(timeInterval: 0.6, target: self, selector: #selector(showTooltipNow(_:)), userInfo: nil, repeats: false)
        }
    }

    @objc private func showTooltipNow(_ t: Timer) {
        tooltipTimer = nil
        guard hoverNode != nil, mouseInside else { return }
        tooltipVisible = true
        needsDisplay = true
    }

    private func hideTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        if tooltipVisible {
            tooltipVisible = false
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        noteInteraction()
        hideTooltip()
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = item(at: p) else { return }
        if event.clickCount >= 2 {
            zoom(into: hit.node)
        } else {
            select(hit.node)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = item(at: p) else { return nil }
        hideTooltip()
        select(hit.node)
        return contextMenu(for: hit.node)
    }

    override func magnify(with event: NSEvent) {
        magnifyAccumulator += event.magnification
        if magnifyAccumulator > 0.35 {
            magnifyAccumulator = 0
            if let n = hoverNode ?? selection, n !== zoomNode {
                // zoom one level towards the pointer
                var step: FileNode = n
                while let p = step.parent, p !== zoomNode { step = p }
                if step.isContainer { zoom(into: step) }
            }
        } else if magnifyAccumulator < -0.35 {
            magnifyAccumulator = 0
            goUp()
        }
        if event.phase == .ended || event.phase == .cancelled { magnifyAccumulator = 0 }
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { goBack() } else if event.deltaX < 0 { goForward() }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        noteInteraction()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        switch event.keyCode {
        case 51: // delete / backspace
            if mods.contains(.command) { moveToTrash(actionTarget) }
            else if mods.contains(.shift) { goForward() }
            else { goBack() }
            return
        case 36, 76: // return, enter
            if let s = selection { zoom(into: s) }
            return
        case 53: // escape
            select(nil)
            return
        case 49: // space
            toggleQuickLook()
            return
        case 115: // home
            goHome()
            return
        case 126 where mods.contains(.command): // cmd-up
            goUp()
            return
        default:
            break
        }
        if mods.isDisjoint(with: [.command, .option]), let c = chars.first {
            switch c {
            case "1": applyTag(.red); return
            case "2": applyTag(.yellow); return
            case "3": applyTag(.green); return
            case "4": applyTag(.blue); return
            case "0":
                if mods.contains(.control) { clearTagsInZoom() } else { applyTag(.none) }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// ⌘C copies the selected element's path.
    @objc func copy(_ sender: Any?) {
        guard let n = selection, !n.isSynthetic else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.path, forType: .string)
    }

    // MARK: Context menu and file actions

    func contextMenu(for node: FileNode) -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "\(node.parent == nil ? displayTitle(node) : node.name) — \(Format.size(node.diskSize, decimal: settings.decimalUnits))", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if node.kind == .unknownSpace {
            menu.addItem(.separator())
            let logItem = NSMenuItem(title: tr("Open Log (unreadable folders)", "Открыть лог (недоступные папки)"),
                                     action: #selector(AppDelegate.showLog(_:)), keyEquivalent: "")
            logItem.target = AppDelegate.shared
            menu.addItem(logItem)
        }
        if node.kind == .purgeable && !session.isSnapshot {
            menu.addItem(.separator())
            menu.addItem(item(tr("Delete Local Time Machine Snapshots…", "Удалить локальные снимки Time Machine…"),
                              #selector(menuDeleteSnapshots(_:)), node))
        }
        guard !node.isSynthetic else { return menu }
        let live = !session.isSnapshot
        menu.addItem(.separator())
        if live {
            menu.addItem(item(tr("Open", "Открыть"), #selector(menuOpen(_:)), node))
            menu.addItem(item(tr("Reveal in Finder", "Показать в Finder"), #selector(menuReveal(_:)), node))
            menu.addItem(item(tr("Quick Look", "Быстрый просмотр"), #selector(menuQuickLook(_:)), node))
        }
        menu.addItem(item(tr("Copy Path", "Скопировать путь"), #selector(menuCopyPath(_:)), node))
        menu.addItem(.separator())
        if node.isContainer && node !== zoomNode {
            menu.addItem(item(tr("Zoom In", "Открыть"), #selector(menuZoom(_:)), node))
        } else if node.isFile, let p = node.parent, p !== zoomNode {
            menu.addItem(item(tr("Zoom to Enclosing Folder", "Открыть родительскую папку"), #selector(menuZoom(_:)), node))
        }
        if live && node.isContainer && node.kind != .mountPoint {
            menu.addItem(item(tr("Rescan This Folder", "Пересканировать папку"), #selector(menuRescan(_:)), node))
        }
        let tagMenu = NSMenu()
        for t in Tag.allCases {
            let it = item(t == .none ? tr("No Tag", "Без тега") : t.name, #selector(menuTag(_:)), node)
            it.tag = Int(t.rawValue)
            it.state = node.tag == t ? .on : .off
            if t != .none {
                it.image = swatch(Theme.tagColor(t))
                it.keyEquivalent = String(t.rawValue)
                it.keyEquivalentModifierMask = [.control]
            }
            tagMenu.addItem(it)
        }
        let tagItem = NSMenuItem(title: tr("Tag", "Тег"), action: nil, keyEquivalent: "")
        tagItem.submenu = tagMenu
        menu.addItem(tagItem)
        if live {
            menu.addItem(.separator())
            menu.addItem(item(tr("Move to Trash…", "Переместить в Корзину…"), #selector(menuTrash(_:)), node))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ node: FileNode) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = node
        return i
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func node(_ sender: NSMenuItem) -> FileNode? { sender.representedObject as? FileNode }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: n.path))
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)])
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        if let n = node(sender) { select(n) }
        toggleQuickLook()
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.path, forType: .string)
    }

    @objc private func menuZoom(_ sender: NSMenuItem) {
        if let n = node(sender) { zoom(into: n) }
    }

    @objc private func menuRescan(_ sender: NSMenuItem) {
        if let n = node(sender) { host?.treemapRescan(n) }
    }

    @objc private func menuTag(_ sender: NSMenuItem) {
        guard let n = node(sender), let t = Tag(rawValue: UInt8(sender.tag)) else { return }
        if t == .none { if n.tag != .none { session.toggleTag(n.tag, on: n) } }
        else { session.toggleTag(t, on: n) }
        invalidateLayout()
    }

    @objc private func menuDeleteSnapshots(_ sender: NSMenuItem) {
        deleteLocalSnapshots()
    }

    func deleteLocalSnapshots() {
        // Snapshots hold the purgeable space that isn't on the map — the same number the
        // "Purgeable" block shows (purgeable files the scan found are not in snapshots).
        let total = session.volume?.purgeable ?? 0
        let purgeable = session.purgeableNode.diskSize > 0
            ? session.purgeableNode.diskSize
            : max(0, total - session.root.purgeableSize)
        LocalSnapshots.confirmAndDelete(volume: "/", purgeable: purgeable, decimal: settings.decimalUnits) { [weak self] in
            self?.invalidateLayout()
        }
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        moveToTrash(node(sender))
    }

    func moveToTrash(_ target: FileNode?) {
        guard let n = target, !n.isSynthetic, !session.isSnapshot else { NSSound.beep(); return }
        guard n !== session.root else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: n.path)
        if settings.confirmTrash {
            let alert = NSAlert()
            alert.messageText = tr("Move “\(n.name)” to the Trash?", "Переместить «\(n.name)» в Корзину?")
            var info = tr("\(Format.size(n.diskSize, decimal: settings.decimalUnits)) on disk", "\(Format.size(n.diskSize, decimal: settings.decimalUnits)) на диске")
            if n.isContainer { info += ", " + countText(n.fileCount, en: "file", "files", ru: ("файл", "файла", "файлов")) }
            info += "."
            if n.isContainer && session.filter != nil {
                info += tr("\n\nThe filter hides part of this folder. Everything inside it goes to the Trash, not only what you see.", "\n\nФильтр скрывает часть этой папки. В Корзину отправится всё её содержимое, а не только видимое.")
            }
            alert.informativeText = info
            alert.alertStyle = .warning
            alert.addButton(withTitle: tr("Move to Trash", "Переместить в Корзину"))
            alert.addButton(withTitle: tr("Cancel", "Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            let parent = n.parent
            if selection === n { selection = parent }
            session.remove(n)
            if let parent { session.refresh(parent) }
            invalidateLayout()
            host?.treemapStateChanged()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard let n = actionTarget ?? selection, !n.isSynthetic, !session.isSnapshot else { NSSound.beep(); return }
            quickLook.urls = [URL(fileURLWithPath: n.path)]
            window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    // Declared on NSObject by QuickLookUI without an actor; AppKit calls them on the main thread.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if quickLook.urls.isEmpty, let n = selection, !n.isSynthetic {
                quickLook.urls = [URL(fileURLWithPath: n.path)]
            }
            panel.dataSource = quickLook
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        host?.treemapDropped(urls: urls)
        return true
    }

    // MARK: Tooltip

    private func tooltipLines(_ n: FileNode) -> [(String, Bool)] {
        let dec = settings.decimalUnits
        var lines: [(String, Bool)] = []
        lines.append((n.parent == nil ? displayTitle(n) : n.name, true))
        if !n.isSynthetic { lines.append((n.path, false)) }
        switch n.kind {
        case .freeSpace:
            lines.append((tr("Free space on \(session.volume?.name ?? "the volume"): \(Format.size(n.diskSize, decimal: dec))",
                             "Свободно на «\(session.volume?.name ?? "томе")»: \(Format.size(n.diskSize, decimal: dec))"), false))
            return lines
        case .purgeable:
            lines.append((tr("\(Format.size(n.diskSize, decimal: dec)) that macOS counts as used but frees by itself when space runs low:",
                             "\(Format.size(n.diskSize, decimal: dec)) macOS считает занятыми, но освобождает сама, когда места мало:"), false))
            lines.append((tr("Not on the map: local Time Machine snapshots and other hidden purgeable data.",
                             "Этого нет на карте: локальные снимки Time Machine и другие скрытые очищаемые данные."), false))
            if session.root.purgeableSize > 0 {
                lines.append((tr("Purgeable files found on the map: \(Format.size(session.root.purgeableSize, decimal: dec)) (filter :attr:purgeable).",
                                 "Очищаемые файлы на самой карте: \(Format.size(session.root.purgeableSize, decimal: dec)) (фильтр :attr:purgeable)."), false))
            }
            lines.append((tr("Finder counts it as available.", "Finder считает это место доступным."), false))
            lines.append((tr("Right-click to delete local Time Machine snapshots now.",
                             "Правый щелчок — удалить локальные снимки Time Machine сейчас."), false))
            return lines
        case .unknownSpace:
            lines.append((tr("\(Format.size(n.diskSize, decimal: dec)) used on the volume but not seen by the scan. Usually:",
                             "\(Format.size(n.diskSize, decimal: dec)) занято на томе, но не найдено сканированием. Обычно это:"), false))
            if session.isScanning {
                lines.append((tr("• folders not scanned yet (the scan is still running)", "• ещё не просканированные папки (скан идёт)"), false))
            }
            if session.deniedCount > 0 {
                lines.append((tr("• \(session.deniedCount) folders that can't be read (right-click › Open Log)",
                                 "• \(session.deniedCount) недоступных папок (правый щелчок › Открыть лог)"), false))
            }
            lines.append((tr("• APFS snapshots that aren't purgeable (system update, backup software)",
                             "• снимки APFS, которые macOS не считает очищаемыми (обновления системы, программы резервного копирования)"), false))
            lines.append((tr("• other volumes in the same APFS container (another macOS, a second Data volume)",
                             "• другие тома в том же контейнере APFS (вторая macOS, ещё один том данных)"), false))
            lines.append((tr("Check in Terminal: diskutil apfs list   and   tmutil listlocalsnapshots /",
                             "Проверить в Терминале: diskutil apfs list   и   tmutil listlocalsnapshots /"), false))
            return lines
        default:
            break
        }
        lines.append((tr("\(Format.size(n.diskSize, decimal: dec)) on disk · \(Format.size(n.logicalSize, decimal: dec)) of data", "\(Format.size(n.diskSize, decimal: dec)) на диске · \(Format.size(n.logicalSize, decimal: dec)) данных"), false))
        if session.filter != nil {
            lines.append((tr("Matching the filter: \(Format.size(n.filteredSize, decimal: dec))", "Подходит под фильтр: \(Format.size(n.filteredSize, decimal: dec))"), false))
        }
        if n.isContainer, let consumed = session.volumeConsumed[n.path], n.diskSize > consumed {
            lines.append((tr("APFS volume: macOS counts \(Format.size(consumed, decimal: dec)) used. The files add up to more because they share blocks (APFS clones).",
                             "Том APFS: macOS считает занятым \(Format.size(consumed, decimal: dec)). Сумма файлов больше, потому что файлы делят общие блоки (клоны APFS)."), false))
        }
        if n.isContainer && n.purgeableSize > 0 {
            lines.append((tr("of which purgeable files: \(Format.size(n.purgeableSize, decimal: dec)) (macOS frees them when needed)",
                             "из них очищаемые файлы: \(Format.size(n.purgeableSize, decimal: dec)) (macOS освободит их сама)"), false))
        }
        if n.isContainer {
            lines.append((tr("\(Format.count(n.fileCount)) files inside · \(Format.count(n.children.count)) items at the first level",
                             "Файлов внутри: \(Format.count(n.fileCount)) · на первом уровне: \(Format.count(n.children.count))"), false))
        }
        let now = Date().timeIntervalSince1970
        if n.isFile {
            if settings.tooltipDates || settings.tooltipAges {
                for (label, t) in [(tr("Modified", "Изменён"), n.modified), (tr("Created", "Создан"), n.created), (tr("Opened", "Открыт"), n.accessed)] where t > 0 {
                    var parts: [String] = []
                    if settings.tooltipDates { parts.append(Format.date(t)) }
                    if settings.tooltipAges {
                        parts.append(Format.ago(seconds: now - t))
                    }
                    lines.append(("\(label): " + parts.joined(separator: " · "), false))
                }
            }
            var flags: [String] = []
            if n.attributes.contains(.hidden) { flags.append(tr("hidden", "скрытый")) }
            if n.attributes.contains(.locked) { flags.append(tr("locked", "защищён")) }
            if n.attributes.contains(.compressed) { flags.append(tr("compressed", "сжат")) }
            if n.attributes.contains(.dataless) { flags.append(tr("in iCloud only", "только в iCloud")) }
            if n.attributes.contains(.hardLink) { flags.append(tr("hard link", "жёсткая ссылка")) }
            if n.attributes.contains(.purgeable) {
                flags.append(tr("purgeable (macOS may delete it when space runs low)", "очищаемый (macOS может удалить его, когда мало места)"))
            }
            if n.attributes.contains(.clone) {
                flags.append(tr("APFS clone (shared blocks counted once)", "клон APFS (общие блоки посчитаны один раз)"))
            }
            if n.attributes.contains(.symlink) { flags.append(tr("symbolic link", "символическая ссылка")) }
            if !flags.isEmpty { lines.append((flags.joined(separator: ", ").capitalizedFirst, false)) }
        }
        switch n.state {
        case .pending where n.isContainer: lines.append((tr("Not scanned yet", "Ещё не просканировано"), false))
        case .denied: lines.append((tr("Not allowed to read this folder", "Нет доступа к этой папке"), false))
        default: break
        }
        if n.kind == .mountPoint { lines.append((tr("Another volume — not scanned from here", "Другой том — отсюда не сканируется"), false)) }
        if n.tag != .none { lines.append((tr("Tag: \(n.tag.name)", "Тег: \(n.tag.name)"), false)) }
        return lines
    }

    private func drawTooltip() {
        guard let n = hoverNode, let p = mousePoint else { return }
        let lines = tooltipLines(n)
        let size = CGFloat(settings.fontSize) + 1
        func style(_ weight: NSFont.Weight, _ color: NSColor, wrap: Bool) -> [NSAttributedString.Key: Any] {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingMiddle
            return [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para]
        }
        let normal = style(.regular, Theme.tooltipText, wrap: true)
        let muted = style(.regular, Theme.tooltipMuted, wrap: false)   // the path: one line, middle cut
        let strong = style(.semibold, Theme.tooltipText, wrap: true)
        let maxText = min(560, max(200, bounds.width - 40))

        // Measure every line at the maximum width; long lines wrap instead of being cut.
        var measured: [(String, [NSAttributedString.Key: Any], CGSize)] = []
        var width: CGFloat = 0
        for (i, l) in lines.enumerated() {
            let a = l.1 ? strong : (i == 1 ? muted : normal)
            let wrap = !(i == 1 && !l.1)
            let one = (l.0 as NSString).size(withAttributes: a)
            var box = CGSize(width: min(ceil(one.width), maxText), height: ceil(one.height))
            if wrap && one.width > maxText {
                let r = (l.0 as NSString).boundingRect(with: CGSize(width: maxText, height: 10_000),
                                                      options: [.usesLineFragmentOrigin], attributes: a)
                box = CGSize(width: maxText, height: ceil(r.height))
            }
            measured.append((l.0, a, box))
            width = max(width, box.width)
        }
        let gap: CGFloat = 3
        let textHeight = measured.reduce(0) { $0 + $1.2.height } + gap * CGFloat(max(0, measured.count - 1))
        let boxWidth = width + 20
        let boxHeight = textHeight + 14
        var r = CGRect(x: p.x + 14, y: p.y + 18, width: boxWidth, height: boxHeight)
        if r.maxX > bounds.maxX - 4 { r.origin.x = max(4, p.x - boxWidth - 8) }
        if r.maxY > bounds.maxY - 4 { r.origin.y = max(4, p.y - boxHeight - 8) }
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        Theme.tooltipBackground.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.stroke()
        var y = r.minY + 7
        for (text, a, box) in measured {
            (text as NSString).draw(with: CGRect(x: r.minX + 10, y: y, width: width, height: box.height),
                                    options: [.usesLineFragmentOrigin], attributes: a)
            y += box.height + gap
        }
    }

    // MARK: Halo and trail

    private func haloSet() -> [ObjectIdentifier: Int] {
        guard settings.hoverHighlight, settings.haloLevels > 0, let h = hoverNode else { return [:] }
        var out: [ObjectIdentifier: Int] = [:]
        var n = h.parent
        var level = 1
        while let c = n, level <= settings.haloLevels {
            out[ObjectIdentifier(c)] = level
            if c === zoomNode { break }
            n = c.parent
            level += 1
        }
        return out
    }

    private func trailStrength(now: Double) -> [ObjectIdentifier: CGFloat] {
        trail.removeAll { now - $0.at > 0.6 }
        var out: [ObjectIdentifier: CGFloat] = [:]
        for t in trail { out[ObjectIdentifier(t.node)] = CGFloat(1 - (now - t.at) / 0.6) }
        return out
    }
}

/// Quick Look data source, kept outside the view so its protocol has no actor ties.
final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
