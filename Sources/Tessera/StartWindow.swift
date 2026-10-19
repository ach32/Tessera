import AppKit
import SwiftUI
import TesseraCore

struct VolumeEntry: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let icon: NSImage
    let total: Int64
    let free: Int64
    let detail: String

    @MainActor
    static func load() -> [VolumeEntry] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsBrowsableKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeEntry] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            var kind = tr("Disk", "Диск")
            if v.volumeIsLocal == false { kind = tr("Network", "Сеть") } else if v.volumeIsRemovable == true { kind = tr("Removable", "Съёмный") }
            out.append(VolumeEntry(path: url.path, name: v.volumeName ?? url.lastPathComponent,
                                   icon: NSWorkspace.shared.icon(forFile: url.path),
                                   total: total, free: Int64(v.volumeAvailableCapacity ?? 0), detail: kind))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        out.append(VolumeEntry(path: home, name: tr("Home", "Дом"), icon: NSWorkspace.shared.icon(forFile: home),
                               total: 0, free: 0, detail: tr("Your home folder", "Ваша домашняя папка")))
        return out
    }
}

@MainActor
final class StartModel: ObservableObject {
    @Published var tab = 0
    @Published var paths = ""
    @Published var snapshotPath = ""
    @Published var error: String?
    @Published var volumes: [VolumeEntry] = VolumeEntry.load()
    @Published var selected: String?

    var onScan: ([String]) -> Void = { _ in }
    var onLoad: ([String]) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onSettings: () -> Void = {}

    func reload() { volumes = VolumeEntry.load() }

    func splitPaths(_ text: String) -> [String] {
        text.split(separator: ";").map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
    }

    func startScan() {
        let list = splitPaths(paths)
        guard !list.isEmpty else { error = tr("Pick a drive or type a folder path.", "Выберите диск или введите путь к папке."); return }
        for p in list {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: p, isDirectory: &isDir) || !isDir.boolValue {
                error = tr("“\(p)” doesn't exist or isn't a folder.", "«\(p)» не существует или это не папка.")
                return
            }
        }
        error = nil
        onScan(list)
    }

    func startLoad() {
        let list = splitPaths(snapshotPath)
        guard !list.isEmpty else { error = tr("Choose a snapshot file.", "Выберите файл снимка."); return }
        for p in list where !FileManager.default.fileExists(atPath: p) {
            error = tr("“\(p)” doesn't exist.", "«\(p)» не существует.")
            return
        }
        error = nil
        onLoad(list)
    }

    func browseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = tr("Choose", "Выбрать")
        panel.message = tr("Choose one or more folders to scan", "Выберите одну или несколько папок для сканирования")
        guard panel.runModal() == .OK else { return }
        paths = panel.urls.map(\.path).joined(separator: "; ")
        selected = nil
        error = nil
    }

    func browseSnapshot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = tr("Choose a Tessera snapshot (.tessera) or du output", "Выберите снимок Tessera (.tessera) или вывод du")
        guard panel.runModal() == .OK else { return }
        snapshotPath = panel.urls.map(\.path).joined(separator: "; ")
        error = nil
    }

    func dropped(_ urls: [URL]) {
        let folders = urls.filter { $0.hasDirectoryPath }
        let files = urls.filter { !$0.hasDirectoryPath }
        if !folders.isEmpty {
            tab = 0
            paths = folders.map(\.path).joined(separator: "; ")
        } else if !files.isEmpty {
            tab = 1
            snapshotPath = files.map(\.path).joined(separator: "; ")
        }
        error = nil
    }
}

@MainActor
struct StartView: View {
    @ObservedObject var model: StartModel
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.tab) {
                Text(tr("Drives & Folders", "Диски и папки")).tag(0)
                Text(tr("Snapshot", "Снимок")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)

            if model.tab == 0 { drives } else { snapshot }

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.callout)
            }

            HStack {
                Button {
                    model.onSettings()
                } label: {
                    Label(tr("Settings…", "Настройки…"), systemImage: "gearshape")
                }
                .help(tr("Language, Full Disk Access, colors…", "Язык, полный доступ к диску, цвета…"))
                Spacer()
                Button(tr("Cancel", "Отмена")) { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                if model.tab == 0 {
                    Button(tr("Scan", "Сканировать")) { model.startScan() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(tr("Open", "Открыть")) { model.startLoad() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 640, height: 470)
        .dropDestination(for: URL.self) { urls, _ in
            model.dropped(urls)
            return !urls.isEmpty
        }
    }

    private var drives: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Pick what to look at. Double-click to start right away, or drop folders here.", "Выберите, что смотреть. Двойной щелчок — сразу начать, или перетащите папки сюда."))
                .font(.callout)
                .foregroundColor(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(model.volumes) { v in
                        VolumeTile(volume: v, selected: model.selected == v.path)
                            .onTapGesture(count: 2) {
                                model.paths = v.path
                                model.selected = v.path
                                model.startScan()
                            }
                            .onTapGesture {
                                model.paths = v.path
                                model.selected = v.path
                                model.error = nil
                            }
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text(tr("Path:", "Путь:"))
                TextField(tr("One or more folders, separated by ;", "Одна или несколько папок через ;"), text: $model.paths)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.startScan() }
                Button(tr("Choose…", "Выбрать…")) { model.browseFolders() }
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(tr("Refresh the list of drives", "Обновить список дисков"))
            }
        }
    }

    private var snapshot: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Open a scan saved earlier (File › Export › Tessera snapshot), or the output of du.", "Откройте сохранённое сканирование (Файл › Экспорт › Снимок Tessera) или вывод du."))
                .font(.callout)
                .foregroundColor(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundColor(.secondary.opacity(0.6))
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text(tr("Drop a .tessera snapshot or a du file here", "Перетащите сюда снимок .tessera или файл du"))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text(tr("File:", "Файл:"))
                TextField(tr("Snapshot file", "Файл снимка"), text: $model.snapshotPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.startLoad() }
                Button(tr("Choose…", "Выбрать…")) { model.browseSnapshot() }
            }
            Text(tr("Making a du file on another Mac or Linux box: du -ak /some/folder > scan.du", "Как сделать файл du на другом Mac или Linux: du -ak /папка > scan.du"))
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

@MainActor
private struct VolumeTile: View {
    let volume: VolumeEntry
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: volume.icon)
                .resizable()
                .frame(width: 48, height: 48)
            Text(volume.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if volume.total > 0 {
                ProgressView(value: Double(volume.total - volume.free), total: Double(volume.total))
                    .progressViewStyle(.linear)
                Text(tr("\(Format.size(volume.free)) free of \(Format.size(volume.total))", "свободно \(Format.size(volume.free)) из \(Format.size(volume.total))"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(volume.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

@MainActor
final class StartWindowController: NSWindowController {
    let model: StartModel

    init() {
        let m = StartModel()
        model = m
        let host = NSHostingController(rootView: StartView(model: m))
        let window = NSWindow(contentViewController: host)
        window.title = tr("New Scan", "Новое сканирование")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func retitle() {
        window?.title = tr("New Scan", "Новое сканирование")
        model.reload()
    }
}
