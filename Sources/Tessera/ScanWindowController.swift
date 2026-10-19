import AppKit
import QuartzCore
import TesseraCore

/// One treemap window: a session (scan or snapshot), its toolbar, filter and status bar.
@MainActor
final class ScanWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
                                  NSToolbarItemValidation, NSMenuItemValidation, TreemapHost {
    let session: ScanSession
    let treemap: TreemapView
    private let filterField = NSSearchField()
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private var settings: AppSettings
    private var dirty = true
    private var displayTimer: Timer?
    private var lastDisplay: CFTimeInterval = 0
    private var filterError: String?
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var exportWindow: ExportWindowController?

    /// Exports to run once the master scan finishes (command line).
    var pendingExports: [LaunchCommands.Export] = []
    var onClose: ((ScanWindowController) -> Void)?
    var onExportsDone: ((ScanWindowController, Bool) -> Void)?

    init(session: ScanSession) {
        let s = Preferences.shared.settings
        self.session = session
        settings = s
        treemap = TreemapView(session: session, settings: s)
        session.sizeMetric = s.sizeMetric
        session.logWarnings = s.logWarnings

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .automatic
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        buildToolbar(in: window)
        treemap.host = self

        session.onChange = { [weak self] in self?.dirty = true }
        session.onFinished = { [weak self] in self?.scanFinished() }
        session.onLog = { entry in AppDelegate.shared.log.append(entry) }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: .tesseraSettingsChanged, object: nil)
        restartDisplayTimer()
        refreshChrome()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        treemap.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(treemap)

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        for l in [statusLeft, statusRight] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            bar.addSubview(l)
        }
        statusRight.alignment = .right
        statusRight.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        bar.addSubview(progressBar)

        NSLayoutConstraint.activate([
            treemap.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            treemap.topAnchor.constraint(equalTo: content.topAnchor),
            treemap.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),

            statusLeft.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            statusLeft.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLeft.trailingAnchor.constraint(lessThanOrEqualTo: statusRight.leadingAnchor, constant: -16),

            statusRight.trailingAnchor.constraint(equalTo: progressBar.leadingAnchor, constant: -8),
            statusRight.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            progressBar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            progressBar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 120),
        ])
        window.contentView = content
        window.initialFirstResponder = treemap
    }

    private enum ID {
        static let newScan = NSToolbarItem.Identifier("new")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let up = NSToolbarItem.Identifier("up")
        static let home = NSToolbarItem.Identifier("home")
        static let scan = NSToolbarItem.Identifier("scan")
        static let subScan = NSToolbarItem.Identifier("subscan")
        static let less = NSToolbarItem.Identifier("less")
        static let more = NSToolbarItem.Identifier("more")
        static let classes = NSToolbarItem.Identifier("classes")
        static let free = NSToolbarItem.Identifier("free")
        static let unknown = NSToolbarItem.Identifier("unknown")
        static let export = NSToolbarItem.Identifier("export")
        static let filter = NSToolbarItem.Identifier("filter")
        static let filterHelp = NSToolbarItem.Identifier("filterHelp")
        static let settings = NSToolbarItem.Identifier("settings")
        static let log = NSToolbarItem.Identifier("log")
    }

    private func buildToolbar(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "ScanToolbar.v3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.newScan, ID.back, ID.forward, ID.up, ID.home, .space, ID.scan, ID.subScan, .space,
         ID.less, ID.more, ID.classes, ID.free, ID.unknown, .flexibleSpace, ID.filter, ID.filterHelp, ID.log, ID.export, ID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case ID.newScan: item = button(id, "plus.rectangle.on.folder", #selector(newScan(_:)))
        case ID.back: item = button(id, "chevron.left", #selector(goBack(_:)))
        case ID.forward: item = button(id, "chevron.right", #selector(goForward(_:)))
        case ID.up: item = button(id, "arrow.up", #selector(goUp(_:)))
        case ID.home: item = button(id, "house", #selector(goHome(_:)))
        case ID.scan: item = button(id, "arrow.clockwise", #selector(toggleScan(_:)))
        case ID.subScan: item = button(id, "scope", #selector(subScan(_:)))
        case ID.less: item = button(id, "minus.magnifyingglass", #selector(lessDetail(_:)))
        case ID.more: item = button(id, "plus.magnifyingglass", #selector(moreDetail(_:)))
        case ID.classes: item = button(id, "paintpalette", #selector(toggleClasses(_:)))
        case ID.free: item = button(id, "externaldrive", #selector(toggleFree(_:)))
        case ID.unknown: item = button(id, "questionmark.square.dashed", #selector(toggleUnknown(_:)))
        case ID.export: item = button(id, "square.and.arrow.up", #selector(showExport(_:)))
        case ID.filterHelp: item = button(id, "questionmark.circle", #selector(filterHelp(_:)))
        case ID.settings: item = button(id, "gearshape", #selector(openSettings(_:)))
        case ID.log: item = button(id, "list.bullet.rectangle", #selector(openLog(_:)))
        case ID.filter:
            let it = NSToolbarItem(itemIdentifier: id)
            it.label = tr("Filter", "Фильтр")
            it.paletteLabel = it.label
            filterField.placeholderString = tr("Filter: *.jpg; >100mb; >1year; :red", "Фильтр: *.jpg; >100mb; >1year; :red")
            filterField.sendsSearchStringImmediately = false
            filterField.sendsWholeSearchString = true
            filterField.target = self
            filterField.action = #selector(applyFilter(_:))
            filterField.delegate = self
            filterField.translatesAutoresizingMaskIntoConstraints = false
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            filterField.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
            it.view = filterField
            item = it
        default:
            return nil
        }
        toolbarItems[id] = item
        return item
    }

    /// Label and tooltip of a toolbar item in the current language.
    private func toolbarTexts(_ id: NSToolbarItem.Identifier) -> (String, String) {
        switch id {
        case ID.newScan: return (tr("New Scan", "Новый скан"), tr("Open another scan (⌘N)", "Открыть ещё одно сканирование (⌘N)"))
        case ID.back: return (tr("Back", "Назад"), tr("Back (⌫)", "Назад (⌫)"))
        case ID.forward: return (tr("Forward", "Вперёд"), tr("Forward (⇧⌫)", "Вперёд (⇧⌫)"))
        case ID.up: return (tr("Up", "Вверх"), tr("Up one level (⌘↑)", "На уровень вверх (⌘↑)"))
        case ID.home: return (tr("Top", "Наверх"), tr("Back to the top (⌘⇧↑)", "В самый верх (⌘⇧↑)"))
        case ID.scan:
            return session.masterToken != nil
                ? (tr("Stop", "Стоп"), tr("Stop scanning (⌘R)", "Остановить сканирование (⌘R)"))
                : (tr("Scan", "Скан"), tr("Rescan everything (⌘R)", "Пересканировать всё (⌘R)"))
        case ID.subScan: return (tr("Scan Here", "Скан здесь"), tr("Scan the zoomed folder first (⌥⌘R)", "Сначала просканировать открытую папку (⌥⌘R)"))
        case ID.less: return (tr("Less Detail", "Меньше"), tr("Show fewer levels (⌘−)", "Показывать меньше уровней (⌘−)"))
        case ID.more: return (tr("More Detail", "Больше"), tr("Show more levels (⌘+)", "Показывать больше уровней (⌘+)"))
        case ID.classes: return (tr("File Kinds", "Виды файлов"), tr("Colour files by kind (⌘T)", "Раскрасить файлы по видам (⌘T)"))
        case ID.free: return (tr("Free Space", "Свободно"), tr("Show free space (⌥⌘F)", "Показать свободное место (⌥⌘F)"))
        case ID.unknown: return (tr("Unseen Space", "Неизвестно"), tr("Show space not scanned or not readable (⌥⌘U)", "Показать непросканированное и недоступное место (⌥⌘U)"))
        case ID.export: return (tr("Export", "Экспорт"), tr("Export or save a snapshot (⌘E)", "Экспорт или сохранение снимка (⌘E)"))
        case ID.filterHelp: return (tr("Filter Help", "Справка"), tr("How to write filters", "Как писать фильтры"))
        case ID.settings: return (tr("Settings", "Настройки"), tr("Settings: language, Full Disk Access, colors… (⌘,)", "Настройки: язык, полный доступ к диску, цвета… (⌘,)"))
        case ID.log: return (tr("Log", "Лог"), tr("Scan problems: folders that couldn't be read (⌥⌘L)", "Проблемы сканирования: папки, которые не удалось прочитать (⌥⌘L)"))
        case ID.filter: return (tr("Filter", "Фильтр"), "")
        default: return ("", "")
        }
    }

    private func relabelToolbar() {
        for (id, it) in toolbarItems {
            let (label, tip) = toolbarTexts(id)
            it.label = label
            it.paletteLabel = label
            if !tip.isEmpty { it.toolTip = tip }
        }
        filterField.placeholderString = tr("Filter: *.jpg; >100mb; >1year; :red", "Фильтр: *.jpg; >100mb; >1year; :red")
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        let (label, tip) = toolbarTexts(id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = tip
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        it.target = self
        it.action = action
        it.isBordered = true
        return it
    }

    // MARK: Refresh

    private func restartDisplayTimer() {
        displayTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(displayTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    /// Redraws at the "smoothness" rate while the user works on the view, and slows down
    /// when they don't (so the scan gets the CPU) — "DynaSmooth".
    @objc private func displayTick(_ t: Timer) {
        guard dirty else { return }
        let now = CACurrentMediaTime()
        var fps = max(2, settings.smoothness)
        if settings.dynaSmooth && !treemap.mouseInside && Date().timeIntervalSince(treemap.lastInteraction) > 3 {
            fps = 2
        }
        guard now - lastDisplay >= 1 / fps else { return }
        lastDisplay = now
        dirty = false
        treemap.invalidateLayout()
        refreshChrome()
    }

    private func refreshChrome() {
        guard let window else { return }
        let dec = settings.decimalUnits
        window.title = session.isSnapshot ? tr("\(session.root.displayName) (snapshot)", "\(session.root.displayName) (снимок)") : titleName
        if !session.isSnapshot { window.representedURL = URL(fileURLWithPath: session.rootPath) }

        var sub: [String] = []
        if let v = session.volume { sub.append(tr("\(Format.size(v.free, decimal: dec)) free on \(v.name)", "свободно \(Format.size(v.free, decimal: dec)) на «\(v.name)»")) }
        if session.isScanning {
            if let p = session.progress { sub.append(tr("scanning \(Int(p * 100))%", "сканирование \(Int(p * 100))%")) } else { sub.append(tr("scanning…", "сканирование…")) }
        }
        window.subtitle = sub.joined(separator: " · ")

        var right: [String] = []
        let root = session.root
        right.append(countText(root.fileCount, en: "file", "files", ru: ("файл", "файла", "файлов")))
        right.append(tr("\(Format.size(root.diskSize, decimal: dec)) on disk", "\(Format.size(root.diskSize, decimal: dec)) на диске"))
        if root.purgeableSize > 0 {
            right.append(tr("\(Format.size(root.purgeableSize, decimal: dec)) purgeable", "очищаемых \(Format.size(root.purgeableSize, decimal: dec))"))
        }
        if session.filter != nil { right.append(tr("\(Format.size(root.filteredSize, decimal: dec)) match", "подходит \(Format.size(root.filteredSize, decimal: dec))")) }
        if session.deniedCount > 0 { right.append(tr("\(session.deniedCount) unreadable", "недоступно: \(session.deniedCount)")) }
        if session.isScanning {
            right.insert(session.subToken != nil ? tr("Scanning folder…", "Сканирую папку…") : tr("Scanning…", "Сканирую…"), at: 0)
        } else if let d = session.lastScanDuration, !session.isSnapshot {
            right.append(tr("scanned in \(Self.duration(d))", "просканировано за \(Self.duration(d))"))
        }
        statusRight.stringValue = right.joined(separator: " · ")

        if let p = session.progress, session.masterToken != nil {
            progressBar.isHidden = false
            progressBar.isIndeterminate = false
            progressBar.doubleValue = p
        } else if session.isScanning {
            progressBar.isHidden = false
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        } else {
            progressBar.stopAnimation(nil)
            progressBar.isHidden = true
        }

        updateStatusLeft(treemap.hoverNode)
        updateToolbarState()
    }

    private var titleName: String {
        if let v = session.volume, v.isVolumeRoot { return v.name }
        return session.root.displayName
    }

    static func duration(_ s: TimeInterval) -> String {
        if s < 1 { return tr("under a second", "меньше секунды") }
        if s < 60 { return tr("\(Int(s))s", "\(Int(s)) с") }
        return tr("\(Int(s) / 60)m \(Int(s) % 60)s", "\(Int(s) / 60) мин \(Int(s) % 60) с")
    }

    private func updateStatusLeft(_ hover: FileNode?) {
        if let e = filterError {
            statusLeft.stringValue = "⚠︎ " + e
            statusLeft.textColor = .systemOrange
            return
        }
        statusLeft.textColor = .secondaryLabelColor
        let dec = settings.decimalUnits
        if let n = hover ?? treemap.selection {
            if n.isSynthetic {
                statusLeft.stringValue = "\(n.name) — \(Format.size(n.diskSize, decimal: dec))"
            } else {
                statusLeft.stringValue = "\(n.path) — \(Format.size(session.weight(n), decimal: dec))"
            }
        } else {
            statusLeft.stringValue = tr("Showing \(treemap.zoomNode.path) · detail level \(treemap.detailLevel)", "Показано: \(treemap.zoomNode.path) · детализация \(treemap.detailLevel)")
        }
    }

    private func updateToolbarState() {
        if let it = toolbarItems[ID.scan] {
            let scanning = session.masterToken != nil
            let (label, tip) = toolbarTexts(ID.scan)
            it.image = NSImage(systemSymbolName: scanning ? "stop.fill" : "arrow.clockwise", accessibilityDescription: label)
            it.label = label
            it.toolTip = tip
        }
        if let it = toolbarItems[ID.subScan] {
            it.image = NSImage(systemSymbolName: session.subToken != nil ? "stop.circle" : "scope", accessibilityDescription: it.label)
        }
        toolbarItems[ID.classes]?.image = NSImage(systemSymbolName: treemap.style == .classes ? "paintpalette.fill" : "paintpalette", accessibilityDescription: toolbarTexts(ID.classes).0)
        toolbarItems[ID.free]?.image = NSImage(systemSymbolName: treemap.showFree ? "externaldrive.fill" : "externaldrive", accessibilityDescription: toolbarTexts(ID.free).0)
        toolbarItems[ID.unknown]?.image = NSImage(systemSymbolName: treemap.showUnknown ? "questionmark.square.fill" : "questionmark.square.dashed", accessibilityDescription: toolbarTexts(ID.unknown).0)
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: Host callbacks

    func treemapStateChanged() { refreshChrome() }
    func treemapHoverChanged(_ node: FileNode?) { updateStatusLeft(node) }
    func treemapDropped(urls: [URL]) { AppDelegate.shared.open(urls: urls) }
    func treemapRescan(_ node: FileNode) {
        session.startSubScan(node)
        refreshChrome()
    }

    private func scanFinished() {
        dirty = true
        refreshChrome()
        if settings.bounceWhenDone && !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        runPendingExports()
    }

    @objc private func settingsChanged(_ n: Notification) {
        settings = Preferences.shared.settings
        session.sizeMetric = settings.sizeMetric
        session.logWarnings = settings.logWarnings
        if session.filter != nil { applyFilterText(filterField.stringValue) }
        treemap.apply(settings: settings)
        relabelToolbar()
        exportWindow?.retitle()
        dirty = true
    }

    // MARK: Command line exports

    func setFilterFromCommandLine(_ text: String) {
        filterField.stringValue = text
        applyFilterText(text)
    }

    func runPendingExports() {
        guard !pendingExports.isEmpty else { return }
        let jobs = pendingExports
        pendingExports = []
        var ok = true
        for job in jobs {
            guard let config = Preferences.shared.exportConfig(named: job.config) else {
                AppDelegate.shared.log.append(LogEntry(path: job.path, message: tr("No export format named “\(job.config)”.", "Нет формата экспорта «\(job.config)».")))
                ok = false
                continue
            }
            do {
                try ExportWriter.write(config: config, session: session, root: session.root,
                                       url: URL(fileURLWithPath: job.path), decimal: settings.decimalUnits)
            } catch {
                AppDelegate.shared.log.append(LogEntry(path: job.path, message: tr("Export failed: \(error.localizedDescription)", "Экспорт не удался: \(error.localizedDescription)")))
                ok = false
            }
        }
        onExportsDone?(self, ok)
    }

    // MARK: Actions

    @objc func newScan(_ sender: Any?) { AppDelegate.shared.showStartWindow(nil) }
    @objc func goBack(_ sender: Any?) { treemap.goBack() }
    @objc func goForward(_ sender: Any?) { treemap.goForward() }
    @objc func goUp(_ sender: Any?) { treemap.goUp() }
    @objc func goHome(_ sender: Any?) { treemap.goHome() }
    @objc func lessDetail(_ sender: Any?) { treemap.lessDetail() }
    @objc func moreDetail(_ sender: Any?) { treemap.moreDetail() }

    @objc func toggleScan(_ sender: Any?) {
        if session.masterToken != nil {
            session.stopScan()
            if !pendingExports.isEmpty {
                pendingExports = []
                onExportsDone?(self, false)
            }
        } else {
            session.startMasterScan()
        }
        refreshChrome()
    }

    @objc func subScan(_ sender: Any?) {
        if session.subToken != nil {
            session.stopSubScan()
        } else {
            session.startSubScan(treemap.zoomNode)
        }
        refreshChrome()
    }

    @objc func toggleClasses(_ sender: Any?) {
        treemap.style = treemap.style == .classes ? .flat : .classes
        refreshChrome()
    }

    @objc func toggleFree(_ sender: Any?) {
        treemap.showFree.toggle()
        refreshChrome()
    }

    @objc func toggleUnknown(_ sender: Any?) {
        treemap.showUnknown.toggle()
        refreshChrome()
    }

    @objc func focusFilter(_ sender: Any?) {
        window?.makeFirstResponder(filterField)
    }

    @objc func openSettings(_ sender: Any?) { AppDelegate.shared.showSettings(nil) }
    @objc func openLog(_ sender: Any?) { AppDelegate.shared.showLog(nil) }
    @objc func deleteSnapshots(_ sender: Any?) { treemap.deleteLocalSnapshots() }

    @objc func filterHelp(_ sender: Any?) { AppDelegate.shared.showHelp(.filters) }

    @objc func applyFilter(_ sender: Any?) {
        applyFilterText(filterField.stringValue)
        if filterError == nil { window?.makeFirstResponder(treemap) }
    }

    private func applyFilterText(_ text: String) {
        do {
            let f = try FilterParser.parse(text, classes: settings.fileClasses, decimalUnits: settings.decimalUnits)
            filterError = nil
            session.setFilter(f)
        } catch let e as FilterError {
            filterError = e.message
            NSSound.beep()
        } catch {
            filterError = error.localizedDescription
        }
        treemap.invalidateLayout()
        refreshChrome()
    }

    @objc func showExport(_ sender: Any?) {
        if let w = exportWindow {
            w.showWindow(nil)
            return
        }
        let w = ExportWindowController(scan: self)
        exportWindow = w
        w.showWindow(nil)
    }

    @objc func tagRed(_ sender: Any?) { treemap.applyTag(.red) }
    @objc func tagYellow(_ sender: Any?) { treemap.applyTag(.yellow) }
    @objc func tagGreen(_ sender: Any?) { treemap.applyTag(.green) }
    @objc func tagBlue(_ sender: Any?) { treemap.applyTag(.blue) }
    @objc func clearTags(_ sender: Any?) { treemap.clearTagsInZoom() }

    @objc func revealSelection(_ sender: Any?) {
        guard let n = treemap.actionTarget else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)])
    }

    @objc func openSelection(_ sender: Any?) {
        guard let n = treemap.actionTarget else { NSSound.beep(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: n.path))
    }

    @objc func quickLookSelection(_ sender: Any?) { treemap.toggleQuickLook() }
    @objc func trashSelection(_ sender: Any?) { treemap.moveToTrash(treemap.actionTarget) }

    // MARK: Validation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        case #selector(toggleClasses(_:)): item.state = treemap.style == .classes ? .on : .off
        case #selector(toggleFree(_:)): item.state = treemap.showFree ? .on : .off
        case #selector(toggleUnknown(_:)): item.state = treemap.showUnknown ? .on : .off
        case #selector(toggleScan(_:)): item.title = session.masterToken != nil ? tr("Stop Scanning", "Остановить сканирование") : tr("Rescan Everything", "Пересканировать всё")
        case #selector(subScan(_:)): item.title = session.subToken != nil ? tr("Stop Scanning This Folder", "Остановить скан этой папки") : tr("Scan Zoomed Folder First", "Сначала сканировать открытую папку")
        default: break
        }
        return validate(item.action)
    }

    private func validate(_ selector: Selector?) -> Bool {
        guard let action = selector else { return true }
        let live = !session.isSnapshot
        switch action {
        case #selector(goBack(_:)): return treemap.canGoBack
        case #selector(goForward(_:)): return treemap.canGoForward
        case #selector(goUp(_:)), #selector(goHome(_:)): return treemap.canGoUp
        case #selector(toggleScan(_:)): return live
        case #selector(deleteSnapshots(_:)): return live && session.rootPath == "/"
        case #selector(subScan(_:)): return live && (treemap.canGoUp || session.subToken != nil)
        case #selector(lessDetail(_:)): return treemap.detailLevel > 0
        case #selector(toggleFree(_:)), #selector(toggleUnknown(_:)): return session.volume?.isVolumeRoot == true
        case #selector(revealSelection(_:)), #selector(openSelection(_:)), #selector(quickLookSelection(_:)), #selector(trashSelection(_:)):
            return live && treemap.actionTarget != nil
        case #selector(tagRed(_:)), #selector(tagYellow(_:)), #selector(tagGreen(_:)), #selector(tagBlue(_:)):
            return treemap.actionTarget != nil
        default: return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        displayTimer?.invalidate()
        displayTimer = nil
        treemap.stop()
        session.close()
        exportWindow?.close()
        NotificationCenter.default.removeObserver(self)
        if !pendingExports.isEmpty {
            pendingExports = []
            onExportsDone?(self, false)
        }
        onClose?(self)
    }
}
