import AppKit
import SwiftUI
import TesseraCore

/// Writes exports of a session's (zoomed, filtered) tree.
@MainActor
enum ExportWriter {
    static func include(_ session: ScanSession) -> (FileNode) -> Bool {
        guard session.filter != nil else { return { _ in true } }
        return { $0.filteredSize > 0 }
    }

    static func sizes(_ session: ScanSession) -> ((FileNode) -> (Int64, Int64))? {
        guard session.filter != nil else { return nil }
        return { ($0.filteredSize, $0.filteredSize) }
    }

    static func write(config: ExportConfig, session: ScanSession, root: FileNode, url: URL, decimal: Bool) throws {
        if config.isSnapshot {
            let payload = SnapshotIO.encode(root: root, rootPath: root.path,
                                            volume: root === session.root ? session.volume : nil,
                                            include: include(session))
            try SnapshotIO.write(payload: payload, to: url)
            return
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FilterError(message: tr("Can't create \(url.path).", "Не удалось создать \(url.path)."))
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try ExportRunner.run(config: config, root: root, include: include(session), sizes: sizes(session),
                             decimal: decimal) { chunk in
            handle.write(Data(chunk.utf8))
        }
    }

    static func preview(config: ExportConfig, session: ScanSession, root: FileNode, decimal: Bool) -> String {
        if config.isSnapshot {
            return tr("A Tessera snapshot keeps everything the window shows — sizes, dates, attributes and tags — "
                + "in a compact binary file. Open it later with File › Open Snapshot or by dropping it on Tessera.\n\n"
                + "Snapshots are not live: they don't follow changes on disk.",
                "Снимок Tessera сохраняет всё, что показывает окно — размеры, даты, атрибуты и теги — "
                + "в компактном двоичном файле. Откройте его позже через Файл › Открыть снимок или перетащив на Tessera.\n\n"
                + "Снимок не обновляется: изменения на диске в нём не отражаются.")
        }
        var out = ""
        do {
            try ExportRunner.run(config: config, root: root, include: include(session), sizes: sizes(session),
                                 decimal: decimal, limit: 150) { chunk in
                if out.count < 40_000 { out += chunk }
            }
        } catch let e as FilterError {
            return "⚠︎ " + e.message
        } catch {
            return "⚠︎ " + error.localizedDescription
        }
        return out
    }
}

@MainActor
final class ExportModel: NSObject, ObservableObject {
    weak var scan: ScanWindowController?
    @Published var selectedID: UUID = ExportConfig.builtIns[1].id
    @Published var designMode = false
    @Published var preview = ""
    @Published var status: String?
    @Published var warnings: [String] = []
    private var previewTimer: Timer?

    init(scan: ScanWindowController) {
        self.scan = scan
        super.init()
    }

    var prefs: Preferences { Preferences.shared }
    var selected: ExportConfig? { prefs.exportConfigs.first { $0.id == selectedID } }
    var isEditable: Bool { selected.map { !$0.isBuiltIn } ?? false }

    var scopeDescription: String {
        guard let scan else { return "" }
        let root = scan.treemap.zoomNode
        let filtered = scan.session.filter != nil
        if Lang.current == .ru {
            return "Экспорт \(root.path)\(filtered ? " — только то, что подходит под фильтр «\(scan.session.filter!.source)»" : ", всё содержимое")."
        }
        return "Exports \(root.path)\(filtered ? " — only what matches the filter “\(scan.session.filter!.source)”" : ", everything in it")."
    }

    func binding<T>(_ kp: WritableKeyPath<ExportConfig, T>, _ fallback: T) -> Binding<T> {
        let id = selectedID
        let prefs = self.prefs
        return Binding(
            get: { prefs.settings.exportConfigs.first(where: { $0.id == id })?[keyPath: kp] ?? fallback },
            set: { value in
                if let i = prefs.settings.exportConfigs.firstIndex(where: { $0.id == id }) {
                    prefs.settings.exportConfigs[i][keyPath: kp] = value
                }
            })
    }

    func toggleDesign() {
        if designMode {
            designMode = false
            return
        }
        if !isEditable { duplicate() }
        designMode = true
    }

    func duplicate() {
        var copy = selected ?? ExportConfig(name: tr("New export", "Новый экспорт"), detail: "<%pathfile%>{&tab}<%disksize%>{&br}")
        if copy.isSnapshot {
            copy = ExportConfig(name: tr("New export", "Новый экспорт"), detail: "<%pathfile%>{&tab}<%disksize%>{&br}")
        }
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = uniqueName(tr("\(copy.name) copy", "\(copy.name) (копия)"))
        prefs.settings.exportConfigs.append(copy)
        selectedID = copy.id
    }

    func newConfig() {
        var c = ExportConfig(name: uniqueName(tr("New export", "Новый экспорт")), detail: "{if{<%isfile%>}=={true}?{<%pathfile%>{&tab}<%disksize%>{&br}}}")
        c.isBuiltIn = false
        prefs.settings.exportConfigs.append(c)
        selectedID = c.id
        designMode = true
    }

    func deleteSelected() {
        guard isEditable else { return }
        let id = selectedID
        selectedID = ExportConfig.builtIns[1].id
        designMode = false
        prefs.settings.exportConfigs.removeAll { $0.id == id }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(prefs.exportConfigs.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Waits for typing to pause before rendering.
    func schedulePreview() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(previewTimerFired(_:)),
                                            userInfo: nil, repeats: false)
    }

    @objc private func previewTimerFired(_ t: Timer) {
        previewTimer = nil
        renderPreview()
    }

    func renderPreview() {
        guard let scan, let config = selected else { preview = ""; return }
        preview = ExportWriter.preview(config: config, session: scan.session, root: scan.treemap.zoomNode,
                                       decimal: prefs.settings.decimalUnits)
        warnings = []
        for text in [config.header, config.detail, config.footer] {
            if let s = try? ExportScript(text) { warnings += s.warnings }
        }
    }

    func export() {
        guard let scan, let config = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(config.fileName).\(config.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExportWriter.write(config: config, session: scan.session, root: scan.treemap.zoomNode, url: url,
                                   decimal: prefs.settings.decimalUnits)
            status = tr("Saved \(url.lastPathComponent).", "Сохранено: \(url.lastPathComponent).")
        } catch {
            status = tr("Export failed: \(error.localizedDescription)", "Экспорт не удался: \(error.localizedDescription)")
        }
    }
}

@MainActor
struct ExportView: View {
    @ObservedObject var model: ExportModel
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker(tr("Format", "Формат"), selection: $model.selectedID) {
                    ForEach(prefs.exportConfigs) { c in
                        Text(c.isBuiltIn ? c.name : tr("\(c.name) (custom)", "\(c.name) (свой)")).tag(c.id)
                    }
                }
                .frame(maxWidth: 380)
                Button {
                    model.toggleDesign()
                } label: {
                    Image(systemName: model.designMode ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                }
                .help(model.isEditable ? tr("Edit this export", "Изменить этот экспорт") : tr("Make an editable copy of this export", "Сделать редактируемую копию"))
                Spacer()
                Button(tr("Export…", "Экспорт…")) { model.export() }
                    .keyboardShortcut(.defaultAction)
            }
            Text(model.scopeDescription)
                .font(.callout)
                .foregroundColor(.secondary)

            if model.designMode && model.isEditable {
                DesignPane(model: model)
                    .frame(minHeight: 230)
            }

            GroupBox(tr("Preview (first elements only)", "Предпросмотр (только первые элементы)")) {
                ScrollView([.vertical, .horizontal]) {
                    Text(model.preview.isEmpty ? " " : model.preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(6)
                }
            }
            .frame(minHeight: 160)

            HStack {
                if !model.warnings.isEmpty {
                    Text(model.warnings.joined(separator: " · "))
                        .foregroundColor(.orange)
                        .font(.callout)
                }
                Spacer()
                if let s = model.status {
                    Text(s).font(.callout).foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { model.renderPreview() }
        .onChange(of: model.selectedID) { _ in model.schedulePreview() }
        .onChange(of: prefs.settings.exportConfigs) { _ in model.schedulePreview() }
    }
}

@MainActor
private struct DesignPane: View {
    @ObservedObject var model: ExportModel

    var body: some View {
        TabView {
            Form {
                TextField(tr("Name", "Название"), text: model.binding(\.name, ""))
                HStack {
                    TextField(tr("File name", "Имя файла"), text: model.binding(\.fileName, "report"))
                    TextField(tr("Extension", "Расширение"), text: model.binding(\.fileExtension, "txt"))
                        .frame(width: 90)
                }
                Picker(tr("Inside each folder", "Внутри каждой папки"), selection: model.binding(\.blockSort, .foldersFirst)) {
                    ForEach(ExportConfig.BlockSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    Picker(tr("Then sort by", "Затем сортировать по"), selection: model.binding(\.fineSort, .size)) {
                        ForEach(ExportConfig.FineSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle(tr("Descending", "По убыванию"), isOn: model.binding(\.descending, true))
                }
                HStack {
                    Button(tr("New", "Новый")) { model.newConfig() }
                    Button(tr("Duplicate", "Дублировать")) { model.duplicate() }
                    Button(tr("Delete", "Удалить"), role: .destructive) { model.deleteSelected() }
                }
            }
            .padding(8)
            .tabItem { Text(tr("General", "Основное")) }

            ScriptEditor(text: model.binding(\.header, ""), note: tr("Written once, at the top. Values are those of the exported folder.", "Пишется один раз, в начале. Значения — для экспортируемой папки."))
                .tabItem { Text(tr("Header", "Начало")) }
            ScriptEditor(text: model.binding(\.detail, ""), note: tr("Written for every folder and file, in order.", "Пишется для каждой папки и файла по порядку."))
                .tabItem { Text(tr("Detail", "Элементы")) }
            ScriptEditor(text: model.binding(\.footer, ""), note: tr("Written once, at the end.", "Пишется один раз, в конце."))
                .tabItem { Text(tr("Footer", "Конец")) }
        }
    }
}

@MainActor
private struct ScriptEditor: View {
    @Binding var text: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note).font(.caption).foregroundColor(.secondary)
                Spacer()
                Menu(tr("Insert Value", "Вставить значение")) {
                    ForEach(ExportScript.tags, id: \.self) { t in
                        Button("<%\(t)%>") { text += "<%\(t)%>" }
                    }
                }
                .frame(width: 130)
                Menu(tr("Insert Command", "Вставить команду")) {
                    ForEach(ExportScript.commands, id: \.self) { c in
                        Button(c) { text += c }
                    }
                }
                .frame(width: 150)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
        }
        .padding(8)
    }
}

@MainActor
final class ExportWindowController: NSWindowController {
    let model: ExportModel

    init(scan: ScanWindowController) {
        let m = ExportModel(scan: scan)
        model = m
        let host = NSHostingController(rootView: ExportView(model: m))
        let window = NSWindow(contentViewController: host)
        window.title = tr("Export — \(scan.window?.title ?? "Tessera")", "Экспорт — \(scan.window?.title ?? "Tessera")")
        scanWindow = scan
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 640))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private weak var scanWindow: ScanWindowController?

    func retitle() {
        window?.title = tr("Export — \(scanWindow?.window?.title ?? "Tessera")", "Экспорт — \(scanWindow?.window?.title ?? "Tessera")")
        model.renderPreview()
    }
}
