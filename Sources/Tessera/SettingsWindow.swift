import AppKit
import SwiftUI
import TesseraCore

private func hexBinding(_ b: Binding<String>) -> Binding<Color> {
    Binding(
        get: { Color(nsColor: NSColor(hex: b.wrappedValue)) },
        set: { b.wrappedValue = NSColor($0).hexString })
}

/// Full Disk Access state for the settings window (no @State: it builds with the
/// Command Line Tools, whose SwiftUI has no macro plugin).
@MainActor
final class FullDiskAccessStatus: ObservableObject {
    static let shared = FullDiskAccessStatus()
    @Published private(set) var granted = Privacy.hasFullDiskAccess
    @Published private(set) var checkedAt = Date()

    func check() {
        granted = Privacy.hasFullDiskAccess
        checkedAt = Date()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var access = FullDiskAccessStatus.shared

    var body: some View {
        TabView {
            general.tabItem { Label(tr("General", "Основные"), systemImage: "globe") }
            geometry.tabItem { Label(tr("Layout", "Карта"), systemImage: "square.grid.3x3") }
            animation.tabItem { Label(tr("Motion", "Анимация"), systemImage: "wind") }
            behavior.tabItem { Label(tr("Behavior", "Поведение"), systemImage: "gearshape") }
            look.tabItem { Label(tr("Look", "Вид"), systemImage: "eye") }
            colors.tabItem { Label(tr("Colors", "Цвета"), systemImage: "paintpalette") }
        }
        .padding(12)
        .frame(minWidth: 660, minHeight: 540)
    }

    // MARK: General: language and Full Disk Access

    private var general: some View {
        Form {
            Section(tr("Language", "Язык")) {
                Picker(tr("Interface language", "Язык интерфейса"), selection: $prefs.settings.language) {
                    Text(tr("Same as macOS", "Как в macOS")).tag(LanguageChoice.system)
                    Text("English").tag(LanguageChoice.en)
                    Text("Русский").tag(LanguageChoice.ru)
                }
                Text(tr("Menus, windows, tooltips and help switch right away.",
                        "Меню, окна, подсказки и справка переключаются сразу."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(tr("Full Disk Access", "Полный доступ к диску")) {
                HStack(spacing: 10) {
                    Image(systemName: access.granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 26))
                        .foregroundColor(access.granted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(access.granted
                             ? tr("Tessera has Full Disk Access.", "У Tessera есть полный доступ к диску.")
                             : tr("Tessera doesn't have Full Disk Access.", "У Tessera нет полного доступа к диску."))
                            .fontWeight(.semibold)
                        Text(tr("Checked at ", "Проверено в ") + timeString(access.checkedAt))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(tr("Check Again", "Проверить")) { access.check() }
                }
                if !access.granted {
                    Text(tr("""
                    Without it, Mail, Messages, Safari data, other users' folders and some of ~/Library show up as unseen space.
                    1. Click “Open System Settings”.
                    2. Turn on Tessera in the list, or add it with “+” (use “Show Tessera in Finder” to find it).
                    3. Quit Tessera and open it again, then click “Check Again”.
                    After rebuilding the app, remove Tessera from the list and add it again: macOS treats each new build as a new app.
                    """, """
                    Без него почта, сообщения, данные Safari, папки других пользователей и часть ~/Library видны как неизвестное место.
                    1. Нажмите «Открыть Системные настройки».
                    2. Включите Tessera в списке или добавьте её кнопкой «+» (найти поможет «Показать Tessera в Finder»).
                    3. Закройте Tessera и откройте снова, потом нажмите «Проверить».
                    После пересборки приложения удалите Tessera из списка и добавьте заново: macOS считает каждую новую сборку другим приложением.
                    """))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(tr("Open System Settings", "Открыть Системные настройки")) { access.openSystemSettings() }
                    Button(tr("Show Tessera in Finder", "Показать Tessera в Finder")) { access.revealApp() }
                }
                Text(tr("Even with Full Disk Access, some system folders stay closed: they belong to root or are protected by System Integrity Protection. That's normal.",
                        "Даже с полным доступом часть системных папок остаётся закрытой: они принадлежат root или защищены SIP. Это нормально."))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { access.check() }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.timeStyle = .medium
        f.dateStyle = .none
        return f.string(from: d)
    }

    // MARK: Layout

    private var geometry: some View {
        Form {
            Section {
                Stepper(tr("Label size: \(Int(prefs.settings.fontSize)) pt", "Размер подписей: \(Int(prefs.settings.fontSize)) пт"),
                        value: $prefs.settings.fontSize, in: 8...20)
                Stepper(tr("Smallest element drawn: \(Int(prefs.settings.minElementSize)) px", "Самый маленький элемент: \(Int(prefs.settings.minElementSize)) пикс."),
                        value: $prefs.settings.minElementSize, in: 2...40)
                VStack(alignment: .leading) {
                    Slider(value: $prefs.settings.proportion, in: 0.5...2.0) {
                        Text(tr("Element shape", "Форма элементов"))
                    } minimumValueLabel: {
                        Image(systemName: "rectangle.portrait")
                    } maximumValueLabel: {
                        Image(systemName: "rectangle")
                    }
                    Text(tr("Tessera tries to keep elements near this width : height ratio (1 = square).",
                            "Tessera старается держать элементы близко к этому соотношению ширины и высоты (1 = квадрат)."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Stepper(tr("Detail level for new windows: \(prefs.settings.initialDetail)", "Детализация для новых окон: \(prefs.settings.initialDetail)"),
                        value: $prefs.settings.initialDetail, in: 0...20)
                Toggle(tr("Biggest elements first (top left)", "Крупные элементы первыми (слева сверху)"), isOn: $prefs.settings.sortItems)
            }
            Section(tr("New windows on a whole drive", "Новые окна для целого диска")) {
                Toggle(tr("Show free space", "Показывать свободное место"), isOn: $prefs.settings.showFreeSpace)
                Toggle(tr("Show space not scanned or not readable", "Показывать непросканированное и недоступное место"), isOn: $prefs.settings.showUnknownSpace)
            }
            Section {
                Picker(tr("Element size means", "Размер элемента — это"), selection: $prefs.settings.sizeMetric) {
                    Text(tr("Space taken on disk", "Место на диске")).tag(SizeMetric.disk)
                    Text(tr("Size of the data", "Размер данных")).tag(SizeMetric.logical)
                }
                Toggle(tr("Count in thousands like Finder (1 KB = 1000 bytes)", "Считать тысячами, как Finder (1 КБ = 1000 байт)"),
                       isOn: $prefs.settings.decimalUnits)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Motion

    private var animation: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Slider(value: $prefs.settings.zoomDuration, in: 0...0.8) { Text(tr("Zoom animation", "Анимация зума")) }
                    Text(prefs.settings.zoomDuration < 0.02
                         ? tr("Off", "Выключена")
                         : String(format: tr("%.2f s", "%.2f с"), prefs.settings.zoomDuration))
                        .font(.caption).foregroundColor(.secondary)
                }
                VStack(alignment: .leading) {
                    Slider(value: $prefs.settings.smoothness, in: 2...60) { Text(tr("Redraws while scanning", "Перерисовка при сканировании")) }
                    Text(tr("\(Int(prefs.settings.smoothness)) per second. Faster looks smoother; slower leaves more time for the scan.",
                            "\(Int(prefs.settings.smoothness)) в секунду. Чаще — плавнее, реже — быстрее сканирование."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Toggle(tr("Slow down redraws when you're not using the window", "Реже перерисовывать, когда окно не используется"),
                       isOn: $prefs.settings.dynaSmooth)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Behavior

    private var behavior: some View {
        Form {
            Section(tr("Scanning", "Сканирование")) {
                Toggle(tr("Follow changes on disk (new windows)", "Следить за изменениями на диске (новые окна)"), isOn: $prefs.settings.watchChanges)
                Toggle(tr("Go into other volumes mounted inside the folder (new scans)", "Заходить в другие тома, подключённые внутри папки (новые сканы)"),
                       isOn: $prefs.settings.crossMountPoints)
                Toggle(tr("Bounce the Dock icon when a scan ends in the background", "Подпрыгивать в Dock, когда скан закончился в фоне"),
                       isOn: $prefs.settings.bounceWhenDone)
                Toggle(tr("Log folders that can't be read", "Записывать в лог недоступные папки"), isOn: $prefs.settings.logWarnings)
                Toggle(tr("Open the log when something goes wrong", "Открывать лог при проблемах"), isOn: $prefs.settings.popupLog)
            }
            Section(tr("Tooltip", "Подсказка")) {
                Toggle(tr("Keep the tooltip open while moving to the next element", "Не закрывать подсказку при переходе к соседнему элементу"),
                       isOn: $prefs.settings.keepTooltipOnMove)
                Toggle(tr("Show dates", "Показывать даты"), isOn: $prefs.settings.tooltipDates)
                Toggle(tr("Show ages (“3 months ago”)", "Показывать давность («3 месяца назад»)"), isOn: $prefs.settings.tooltipAges)
            }
            Section(tr("Files", "Файлы")) {
                Toggle(tr("Ask before moving to the Trash", "Спрашивать перед перемещением в Корзину"), isOn: $prefs.settings.confirmTrash)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Look

    private var look: some View {
        Form {
            Section {
                Slider(value: $prefs.settings.levelContrast, in: 0...1) {
                    Text(tr("Depth shading", "Затемнение по глубине"))
                } minimumValueLabel: { Text(tr("Flat", "Плоско")) } maximumValueLabel: { Text(tr("Deep", "Объёмно")) }
                Slider(value: $prefs.settings.borderContrast, in: 0...1) {
                    Text(tr("Borders", "Границы"))
                } minimumValueLabel: { Text(tr("Soft", "Мягкие")) } maximumValueLabel: { Text(tr("Hard", "Чёткие")) }
                Stepper(tr("Highlight \(prefs.settings.haloLevels) enclosing folder level\(prefs.settings.haloLevels == 1 ? "" : "s") on hover",
                           "Подсвечивать уровней родительских папок: \(prefs.settings.haloLevels)"),
                        value: $prefs.settings.haloLevels, in: 0...8)
                Toggle(tr("Highlight the element under the pointer", "Подсвечивать элемент под курсором"), isOn: $prefs.settings.hoverHighlight)
                Toggle(tr("Shadow under the selected element", "Тень под выбранным элементом"), isOn: $prefs.settings.dropShadow)
                Toggle(tr("Leave a fading trail behind the pointer", "Оставлять затухающий след за курсором"), isOn: $prefs.settings.mouseTrail)
            }
            Section {
                Button(tr("Restore All Settings to Defaults", "Сбросить все настройки")) { prefs.resetAll() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Colors

    private var colors: some View {
        Form {
            Section(tr("Flat colors", "Простые цвета")) {
                Picker(tr("New windows use", "Новые окна используют"), selection: $prefs.settings.defaultStyle) {
                    Text(tr("Flat colors", "Простые цвета")).tag(ViewStyle.flat)
                    Text(tr("Colors by file kind", "Цвета по видам файлов")).tag(ViewStyle.classes)
                }
                HStack(spacing: 18) {
                    ColorPicker(tr("Drive", "Диск"), selection: hexBinding($prefs.settings.colors.volume))
                    ColorPicker(tr("Folder", "Папка"), selection: hexBinding($prefs.settings.colors.folder))
                    ColorPicker(tr("File", "Файл"), selection: hexBinding($prefs.settings.colors.file))
                    ColorPicker(tr("Free", "Свободно"), selection: hexBinding($prefs.settings.colors.free))
                    ColorPicker(tr("Unseen", "Неизвестно"), selection: hexBinding($prefs.settings.colors.unknown))
                }
                Button(tr("Reset Flat Colors", "Сбросить цвета")) { prefs.settings.colors = FlatColors() }
            }
            Section {
                ForEach($prefs.settings.fileClasses) { $cls in
                    FileClassRow(cls: $cls) {
                        let id = cls.id
                        prefs.settings.fileClasses.removeAll { $0.id == id }
                    }
                }
                HStack {
                    Button(tr("Add Kind", "Добавить вид")) {
                        prefs.settings.fileClasses.append(FileClass(name: tr("New kind", "Новый вид"), extensions: [], color: "#C8A2C8"))
                    }
                    Button(tr("Reset Kinds", "Сбросить виды")) { prefs.settings.fileClasses = FileClassNames.localizedDefaults() }
                }
            } header: {
                Text(tr("File kinds", "Виды файлов"))
            } footer: {
                Text(tr("Used by the “File Kinds” colors and by filters like :class:Images. When an extension is in two kinds, the first one wins.",
                        "Используются для раскраски по видам файлов и в фильтрах вида :class:Изображения. Если расширение есть в двух видах, действует первый."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct FileClassRow: View {
    @Binding var cls: FileClass
    let onDelete: () -> Void

    /// Edits the list as text. A trailing separator is kept as an empty last item so
    /// typing "jpg;" doesn't snap back to "jpg" (empty items are ignored everywhere).
    private var extensionsText: Binding<String> {
        let cls = $cls
        return Binding(
            get: { cls.wrappedValue.extensionsText },
            set: { text in
                var list = FileClass.parseExtensions(text)
                if let last = text.last, last == ";" || last == "," || last == " " { list.append("") }
                cls.wrappedValue.extensions = list
            })
    }

    var body: some View {
        HStack {
            ColorPicker("", selection: hexBinding($cls.color))
                .labelsHidden()
                .frame(width: 40)
            TextField(tr("Name", "Название"), text: $cls.name)
                .frame(width: 190)
            TextField(tr("Extensions: jpg; png; heic", "Расширения: jpg; png; heic"), text: extensionsText)
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(tr("Remove this kind", "Удалить этот вид"))
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = tr("Tessera Settings", "Настройки Tessera")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 600))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func retitle() { window?.title = tr("Tessera Settings", "Настройки Tessera") }
}
