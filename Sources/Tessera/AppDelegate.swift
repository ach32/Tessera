import AppKit
import SwiftUI
import TesseraCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    let log = LogStore()
    private var scanWindows: [ScanWindowController] = []
    private var startWindow: StartWindowController?
    private var settingsWindow: SettingsWindowController?
    private var logWindow: HostingWindowController?
    private var helpWindows: [HelpTopic: HostingWindowController] = [:]

    // Command line
    private var autoclose = false
    private var exportsLeft = 0
    private var openedAtLaunch = false

    // MARK: Launch

    private var menuLanguage: Lang.Code = Lang.current

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Preferences.shared   // loads settings and sets the language
        menuLanguage = Lang.current
        buildMenus()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: .tesseraSettingsChanged, object: nil)
        log.onNewEntry = { [weak self] in self?.logChanged() }

        let args = Array(CommandLine.arguments.dropFirst())
        do {
            let commands = try LaunchCommands.parse(args)
            if commands.help {
                print(LaunchCommands.helpText)
                showHelp(.commandLine)
            }
            run(commands)
        } catch {
            let message = (error as? FilterError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("tessera: \(message)\n".utf8))
            let alert = NSAlert()
            alert.messageText = tr("Tessera didn't understand the command line", "Tessera не поняла командную строку")
            alert.informativeText = message + tr("\n\nSee Help › Command Line.", "\n\nСм. Справка › Командная строка.")
            alert.runModal()
        }

        DispatchQueue.main.async {
            if self.scanWindows.isEmpty && !self.openedAtLaunch {
                self.showStartWindow(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Switches menus and window titles when the interface language changes.
    @objc private func settingsChanged(_ n: Notification) {
        guard Lang.current != menuLanguage else { return }
        menuLanguage = Lang.current
        buildMenus()
        startWindow?.retitle()
        settingsWindow?.retitle()
        logWindow?.window?.title = tr("Tessera Log", "Лог Tessera")
        for (topic, w) in helpWindows {
            w.window?.title = tr("Tessera Help — \(topic.title)", "Справка Tessera — \(topic.title)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStartWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Folders and snapshots dropped on the Dock icon or opened with Tessera.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        open(urls: urls)
    }

    func open(urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && url.pathExtension != SnapshotIO.fileExtension {
                openScan(path: url.path)
            } else {
                openSnapshot(path: url.path)
            }
        }
    }

    private func run(_ commands: LaunchCommands) {
        guard !commands.jobs.isEmpty else { return }
        openedAtLaunch = true
        autoclose = commands.autoclose
        for job in commands.jobs {
            let controller: ScanWindowController?
            switch job.source {
            case .scan(let p): controller = openScan(path: p)
            case .load(let p): controller = openSnapshot(path: p)
            }
            guard let c = controller else { continue }
            if let f = job.filter { c.setFilterFromCommandLine(f) }
            if !job.exports.isEmpty {
                exportsLeft += 1
                c.pendingExports = job.exports
                c.onExportsDone = { [weak self] _, ok in self?.exportFinished(ok) }
                if c.session.isSnapshot { c.runPendingExports() }
            }
        }
        if autoclose && exportsLeft == 0 { autoclose = false }
    }

    private func exportFinished(_ ok: Bool) {
        exportsLeft -= 1
        if !ok { autoclose = false }
        if autoclose && exportsLeft <= 0 {
            NSApp.terminate(nil)
        }
    }

    // MARK: Windows

    @discardableResult
    func openScan(path: String) -> ScanWindowController? {
        let settings = Preferences.shared.settings
        let clean = ScanSession.normalize(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clean, isDirectory: &isDir), isDir.boolValue else {
            let alert = NSAlert()
            alert.messageText = tr("“\(path)” isn't a folder Tessera can open.", "«\(path)» — не папка, которую может открыть Tessera.")
            alert.runModal()
            return nil
        }
        let options = ScanOptions.forRoot(clean, crossMountPoints: settings.crossMountPoints)
        let session = ScanSession(path: clean, options: options, watchChanges: settings.watchChanges)
        let controller = present(session)
        session.startMasterScan()
        return controller
    }

    @discardableResult
    func openSnapshot(path: String) -> ScanWindowController? {
        let url = URL(fileURLWithPath: path)
        do {
            let session: ScanSession
            if url.pathExtension.lowercased() == SnapshotIO.fileExtension {
                let loaded = try SnapshotIO.read(url: url)
                session = ScanSession(snapshotRoot: loaded.root, name: url.lastPathComponent, volume: loaded.volume)
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                let root = try DuImporter.read(text: text)
                session = ScanSession(snapshotRoot: root, name: url.lastPathComponent, volume: nil)
            }
            return present(session)
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Couldn't open “\(url.lastPathComponent)”", "Не удалось открыть «\(url.lastPathComponent)»")
            alert.informativeText = (error as? FilterError)?.message ?? error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    private func present(_ session: ScanSession) -> ScanWindowController {
        let c = ScanWindowController(session: session)
        c.onClose = { [weak self] closed in
            self?.scanWindows.removeAll { $0 === closed }
        }
        if let last = scanWindows.last?.window, let w = c.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            c.window?.center()
        }
        scanWindows.append(c)
        c.showWindow(nil)
        startWindow?.close()
        return c
    }

    @objc func showStartWindow(_ sender: Any?) {
        if startWindow == nil {
            let w = StartWindowController()
            w.model.onScan = { [weak self] paths in
                for p in paths { self?.openScan(path: p) }
            }
            w.model.onLoad = { [weak self] paths in
                for p in paths { self?.openSnapshot(path: p) }
            }
            w.model.onCancel = { [weak self] in self?.startWindow?.close() }
            w.model.onSettings = { [weak self] in self?.showSettings(nil) }
            startWindow = w
        }
        startWindow?.model.reload()
        startWindow?.model.error = nil
        startWindow?.showWindow(nil)
        startWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openSnapshotPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = tr("Choose a Tessera snapshot (.tessera) or du output", "Выберите снимок Tessera (.tessera) или вывод du")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openSnapshot(path: url.path) }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
    }

    @objc func showLog(_ sender: Any?) {
        if logWindow == nil {
            logWindow = HostingWindowController(title: tr("Tessera Log", "Лог Tessera"), size: NSSize(width: 680, height: 380), view: LogView(store: log))
        }
        logWindow?.showWindow(nil)
    }

    private func logChanged() {
        guard Preferences.shared.settings.popupLog, !log.muted else { return }
        if logWindow?.window?.isVisible != true {
            if logWindow == nil {
                logWindow = HostingWindowController(title: tr("Tessera Log", "Лог Tessera"), size: NSSize(width: 680, height: 380), view: LogView(store: log))
            }
            // Show without stealing focus from the treemap.
            logWindow?.window?.orderFront(nil)
        }
    }

    func showHelp(_ topic: HelpTopic) {
        if helpWindows[topic] == nil {
            helpWindows[topic] = HostingWindowController(title: tr("Tessera Help — \(topic.title)", "Справка Tessera — \(topic.title)"),
                                                         size: NSSize(width: 700, height: 560), view: HelpView(topic: topic))
        }
        helpWindows[topic]?.showWindow(nil)
    }

    @objc func showFilterHelp(_ sender: Any?) { showHelp(.filters) }
    @objc func showTagHelp(_ sender: Any?) { showHelp(.tags) }
    @objc func showCommandLineHelp(_ sender: Any?) { showHelp(.commandLine) }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: tr("See where your disk space went.\nA native macOS treemap disk analyzer.", "Посмотрите, куда ушло место на диске.\nНативный анализатор диска для macOS в виде карты."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("About Tessera", "О программе Tessera"), action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Settings…", "Настройки…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: tr("Services", "Службы"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Hide Tessera", "Скрыть Tessera"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: tr("Hide Others", "Скрыть остальные"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: tr("Show All", "Показать все"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Quit Tessera", "Завершить Tessera"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Tessera", to: main)

        // File
        let file = NSMenu(title: tr("File", "Файл"))
        file.addItem(withTitle: tr("New Scan…", "Новое сканирование…"), action: #selector(showStartWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: tr("Open Snapshot…", "Открыть снимок…"), action: #selector(openSnapshotPanel(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: tr("Export…", "Экспорт…"), action: #selector(ScanWindowController.showExport(_:)), keyEquivalent: "e")
        file.addItem(.separator())
        file.addItem(withTitle: tr("Close", "Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: tr("File", "Файл"), to: main)

        // Edit
        let edit = NSMenu(title: tr("Edit", "Правка"))
        edit.addItem(withTitle: tr("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Redo", "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copy", "Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Select All", "Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Filter…", "Фильтр…"), action: #selector(ScanWindowController.focusFilter(_:)), keyEquivalent: "f")
        add(edit, title: tr("Edit", "Правка"), to: main)

        // View
        let view = NSMenu(title: tr("View", "Вид"))
        view.addItem(withTitle: tr("Back", "Назад"), action: #selector(ScanWindowController.goBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: tr("Forward", "Вперёд"), action: #selector(ScanWindowController.goForward(_:)), keyEquivalent: "]")
        let up = view.addItem(withTitle: tr("Up One Level", "На уровень вверх"), action: #selector(ScanWindowController.goUp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        up.keyEquivalentModifierMask = [.command]
        let home = view.addItem(withTitle: tr("Back to the Top", "В самый верх"), action: #selector(ScanWindowController.goHome(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        home.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: tr("Less Detail", "Меньше деталей"), action: #selector(ScanWindowController.lessDetail(_:)), keyEquivalent: "-")
        view.addItem(withTitle: tr("More Detail", "Больше деталей"), action: #selector(ScanWindowController.moreDetail(_:)), keyEquivalent: "=")
        view.addItem(.separator())
        view.addItem(withTitle: tr("Colors by File Kind", "Цвета по видам файлов"), action: #selector(ScanWindowController.toggleClasses(_:)), keyEquivalent: "t")
        let free = view.addItem(withTitle: tr("Show Free Space", "Показать свободное место"), action: #selector(ScanWindowController.toggleFree(_:)), keyEquivalent: "f")
        free.keyEquivalentModifierMask = [.command, .option]
        let unknown = view.addItem(withTitle: tr("Show Unseen Space", "Показать неизвестное место"), action: #selector(ScanWindowController.toggleUnknown(_:)), keyEquivalent: "u")
        unknown.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: tr("Rescan Everything", "Пересканировать всё"), action: #selector(ScanWindowController.toggleScan(_:)), keyEquivalent: "r")
        let sub = view.addItem(withTitle: tr("Scan Zoomed Folder First", "Сначала сканировать открытую папку"), action: #selector(ScanWindowController.subScan(_:)), keyEquivalent: "r")
        sub.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: tr("Enter Full Screen", "Полноэкранный режим"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(view, title: tr("View", "Вид"), to: main)

        // Element
        let element = NSMenu(title: tr("Element", "Элемент"))
        element.addItem(withTitle: tr("Open", "Открыть"), action: #selector(ScanWindowController.openSelection(_:)), keyEquivalent: "")
        let reveal = element.addItem(withTitle: tr("Reveal in Finder", "Показать в Finder"), action: #selector(ScanWindowController.revealSelection(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        let ql = element.addItem(withTitle: tr("Quick Look", "Быстрый просмотр"), action: #selector(ScanWindowController.quickLookSelection(_:)), keyEquivalent: "y")
        ql.keyEquivalentModifierMask = [.command]
        element.addItem(.separator())
        for (title, sel, key) in [(tr("Tag Red", "Тег: красный"), #selector(ScanWindowController.tagRed(_:)), "1"),
                                  (tr("Tag Yellow", "Тег: жёлтый"), #selector(ScanWindowController.tagYellow(_:)), "2"),
                                  (tr("Tag Green", "Тег: зелёный"), #selector(ScanWindowController.tagGreen(_:)), "3"),
                                  (tr("Tag Blue", "Тег: синий"), #selector(ScanWindowController.tagBlue(_:)), "4"),
                                  (tr("Clear Tags in View", "Снять теги в области"), #selector(ScanWindowController.clearTags(_:)), "0")] {
            let it = element.addItem(withTitle: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = [.control]
        }
        element.addItem(.separator())
        element.addItem(withTitle: tr("Delete Local Time Machine Snapshots…", "Удалить локальные снимки Time Machine…"),
                        action: #selector(ScanWindowController.deleteSnapshots(_:)), keyEquivalent: "")
        element.addItem(.separator())
        let trash = element.addItem(withTitle: tr("Move to Trash…", "Переместить в Корзину…"), action: #selector(ScanWindowController.trashSelection(_:)), keyEquivalent: String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
        trash.keyEquivalentModifierMask = [.command]
        add(element, title: tr("Element", "Элемент"), to: main)

        // Window
        let window = NSMenu(title: tr("Window", "Окно"))
        window.addItem(withTitle: tr("Minimize", "Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: tr("Zoom", "Изменить масштаб"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let logItem = window.addItem(withTitle: tr("Log", "Лог"), action: #selector(showLog(_:)), keyEquivalent: "l")
        logItem.keyEquivalentModifierMask = [.command, .option]
        window.addItem(.separator())
        window.addItem(withTitle: tr("Bring All to Front", "Все окна — на передний план"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, title: tr("Window", "Окно"), to: main)
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: tr("Help", "Справка"))
        help.addItem(withTitle: tr("Filtering", "Фильтры"), action: #selector(showFilterHelp(_:)), keyEquivalent: "?")
        help.addItem(withTitle: tr("Tags", "Теги"), action: #selector(showTagHelp(_:)), keyEquivalent: "")
        help.addItem(withTitle: tr("Command Line", "Командная строка"), action: #selector(showCommandLineHelp(_:)), keyEquivalent: "")
        add(help, title: tr("Help", "Справка"), to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }
}
