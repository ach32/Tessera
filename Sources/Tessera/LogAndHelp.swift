import AppKit
import SwiftUI
import TesseraCore

// MARK: Log console

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    /// "Don't pop up again" until the app restarts.
    @Published var muted = false
    /// Show the expected system-folder entries one by one.
    @Published var showExpected = false
    var onNewEntry: (() -> Void)?

    var problems: [LogEntry] { entries.filter { !$0.expected } }
    var expectedCount: Int { entries.reduce(0) { $0 + ($1.expected ? 1 : 0) } }

    func append(_ e: LogEntry) {
        entries.append(e)
        if entries.count > 5000 { entries.removeFirst(entries.count - 5000) }
        // System folders nobody can read are normal: count them, don't pop up.
        if !e.expected { onNewEntry?() }
    }

    func clear() { entries.removeAll() }

    /// Plain-text report: system facts, a summary by kind of error, then every entry.
    func reportText() -> String {
        var out = "Tessera log — \(Date())\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "App: \(Bundle.main.bundlePath)\n"
        out += "Executable: \(Bundle.main.executablePath ?? "?")\n"
        out += "Full Disk Access (self-check): \(Privacy.hasFullDiskAccess ? "yes" : "NO")\n"
        out += "Running as user: \(NSUserName()) (uid \(getuid()))\n"
        var kinds: [String: Int] = [:]
        for e in entries { kinds[e.message, default: 0] += 1 }
        out += "\nSummary (\(entries.count) entries):\n"
        for (k, n) in kinds.sorted(by: { $0.value > $1.value }) { out += "  \(n)× \(k)\n" }
        out += "\nEntries:\n"
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        out += "  (\(expectedCount) of them are expected system folders)\n"
        for e in entries {
            out += "\(f.string(from: e.date))  \(e.expected ? "[system] " : "")\(e.message)  \(e.path)\n"
        }
        return out
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText(), forType: .string)
    }

    func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tessera-log.txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try reportText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

enum Privacy {
    /// The TCC database is readable only by processes that have Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

@MainActor
struct LogView: View {
    @ObservedObject var store: LogStore
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(countText(store.problems.count, en: "problem", "problems", ru: ("проблема", "проблемы", "проблем")))
                    .foregroundColor(.secondary)
                Text(Privacy.hasFullDiskAccess ? tr("Full Disk Access: on", "Полный доступ: есть") : tr("Full Disk Access: OFF", "Полный доступ: НЕТ"))
                    .font(.caption)
                    .foregroundColor(Privacy.hasFullDiskAccess ? .green : .orange)
                    .help(tr("Checked by trying to read the system privacy database, which needs Full Disk Access", "Проверяется попыткой прочитать системную базу конфиденциальности, для этого нужен полный доступ к диску"))
                Spacer()
                Button(tr("Copy All", "Копировать всё")) { store.copyReport() }
                    .help(tr("Copy the whole log with system details, to paste it somewhere", "Скопировать весь лог со сведениями о системе, чтобы вставить куда-нибудь"))
                Button(tr("Save…", "Сохранить…")) { store.saveReport() }
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("Full Disk Access…", "Полный доступ к диску…"), systemImage: "lock.open")
                }
                .help(tr("Open System Settings › Privacy & Security › Full Disk Access", "Открыть Системные настройки › Конфиденциальность и безопасность › Полный доступ к диску"))
                Toggle(isOn: $store.muted) {
                    Label(tr("Don't pop up", "Не всплывать"), systemImage: store.muted ? "bolt.slash.fill" : "bolt.fill")
                }
                .toggleStyle(.button)
                .help(tr("Stop opening this window on every new problem (until Tessera restarts)", "Не открывать это окно при каждой новой проблеме (до перезапуска Tessera)"))
                Button(tr("Clear", "Очистить")) { store.clear() }
            }
            .padding(10)
            Divider()
            if store.expectedCount > 0 {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundColor(.secondary)
                    Text(tr("\(store.expectedCount) system folders can't be read. They belong to macOS or to root, or System Integrity Protection guards them, so no app can open them without administrator rights. This is normal: their space is shown as Unseen Space.", "Системных папок, которые нельзя прочитать: \(store.expectedCount). Они принадлежат macOS или root либо защищены SIP, поэтому без прав администратора их не открыть ни одному приложению. Это нормально: их место показано как неизвестное."))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Toggle(tr("Show", "Показать"), isOn: $store.showExpected)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(10)
                Divider()
            }
            let shown = store.showExpected ? store.entries : store.problems
            if shown.isEmpty {
                Spacer()
                Text(tr("Nothing to report.", "Сообщать не о чем."))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(shown.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.message).fontWeight(.medium)
                            Spacer()
                            Text(e.date, style: .time).foregroundColor(.secondary).font(.caption)
                        }
                        Text(e.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        if let hint = e.hint {
                            Text(hint).font(.caption).foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 300)
    }
}

// MARK: Help

enum HelpTopic: String, CaseIterable {
    case filters, tags, commandLine

    var title: String {
        switch self {
        case .filters: return tr("Filtering", "Фильтры")
        case .tags: return tr("Tags", "Теги")
        case .commandLine: return tr("Command Line", "Командная строка")
        }
    }

    var text: String {
        switch self {
        case .filters:
            if Lang.current == .ru { return HelpTopic.filtersRu }
            return """
            Type a filter in the toolbar and press Return. Separate conditions with ;
            Names, tags and kinds are combined with OR. Everything else must all be true.
            A leading | turns any condition around (exclude instead of include).

            NAMES
              *.jpg              files ending in .jpg   (* = anything, ? = one character)
              backup             files with “backup” anywhere in the name
              |*.dmg             everything except .dmg files

            FOLDERS
              \\cache             only files inside a folder whose name contains “cache”, at any depth
              \\node_modules;>1mb big files inside node_modules
              |\\.git             leave out everything inside .git folders
              Matching folders show their name in bold.

            SIZE      (b, kb, mb, gb, tb — 1000 or 1024 per Settings › Layout)
              >100mb             bigger than 100 MB (space on disk)
              size > 10 mb       data size instead of space on disk
              disksize<4kb       keywords: disksize / disk, size / logical. Short forms work: dsk, sz

            AGE       (s, min, h, d, w, months, y)
              >1year             not modified for more than a year
              <2weeks            modified in the last two weeks
              created<1d         created today-ish     accessed>6months  not opened for 6 months
              Short forms work too: c<1d, a>6months

            TAGS
              :red  :2  :g  :all  |:blue      short form
              :tag:red+green-blue            red or green, but not blue
              Tags on a folder count for everything inside it.

            ATTRIBUTES
              :attr:hidden   :attr:locked   :attr:compressed   :attr:cloud (in iCloud only)
              :attr:hardlink :attr:symlink  :attr:executable   :attr:system
              :attr:purgeable                files macOS may delete by itself when space runs low
              :attr:clone                    APFS clones (shared blocks counted once)
              :attr:hidden-locked            hidden but not locked

            KINDS (Settings › Colors › File kinds)
              :class:Video          |:class:Images

            EXAMPLES
              *.mov;*.mp4;>500mb;>6months     big old videos
              :class:Archives;|\\Downloads     archives that aren't in Downloads
              |:red                           tag something red and it disappears
            """
        case .tags:
            if Lang.current == .ru { return HelpTopic.tagsRu }
            return """
            Tags are four colored bookmarks you put on files and folders while you explore.
            They live as long as the window (or in a snapshot you export).

              Point at an element and press 1, 2, 3 or 4 (red, yellow, green, blue).
              ⌃1 … ⌃4 work even while you are typing a filter.
              Press the same number again to remove the tag. 0 removes any tag.
              ⌃0 clears every tag in the zoomed area, including elements hidden by the filter.

            Tags on a folder apply to everything inside it when filtering, but only the
            folder itself shows the colored corner.

            IDEAS
              Hide things you've dealt with:   filter |:red, then tag things red as you go.
              A shopping cart:                 two windows on the same folder; one filtered |:g,
                                               the other :g. Tag green in the first, the items move to the second.
                                               Export the second (File › Export) for a list.
            """
        case .commandLine:
            return LaunchCommands.helpText
        }
    }
}

@MainActor
struct HelpView: View {
    let topic: HelpTopic
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        ScrollView {
            Text(topic.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

@MainActor
final class HostingWindowController: NSWindowController {
    init<V: View>(title: String, size: NSSize, view: V) {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension HelpTopic {
    static let filtersRu = """
    Введите фильтр в поле на панели инструментов и нажмите Return. Условия разделяются ;
    Имена, теги и виды файлов объединяются через ИЛИ. Все остальные условия должны выполняться вместе.
    | в начале любого условия переворачивает его (исключить вместо включить).

    ИМЕНА
      *.jpg              файлы, оканчивающиеся на .jpg   (* = что угодно, ? = один символ)
      backup             файлы со словом «backup» в любом месте имени
      |*.dmg             всё, кроме файлов .dmg

    ПАПКИ
      \\cache             только файлы внутри папок, в имени которых есть «cache», на любой глубине
      \\node_modules;>1mb большие файлы внутри node_modules
      |\\.git             исключить всё внутри папок .git
      Совпавшие папки показываются жирным шрифтом.

    РАЗМЕР    (b, kb, mb, gb, tb — по 1000 или 1024, см. Настройки › Карта)
      >100mb             больше 100 МБ (место на диске)
      size > 10 mb       размер данных вместо места на диске
      disksize<4kb       ключевые слова: disksize / disk, size / logical. Сокращения тоже работают: dsk, sz

    ВОЗРАСТ   (s, min, h, d, w, months, y)
      >1year             не изменялся больше года
      <2weeks            изменён за последние две недели
      created<1d         создан примерно сегодня     accessed>6months  не открывался полгода
      Сокращения работают: c<1d, a>6months

    ТЕГИ
      :red  :2  :g  :all  |:blue      короткая запись
      :tag:red+green-blue            красный или зелёный, но не синий
      Тег на папке действует на всё внутри неё.

    АТРИБУТЫ
      :attr:hidden   :attr:locked   :attr:compressed   :attr:cloud (только в iCloud)
      :attr:hardlink :attr:symlink  :attr:executable   :attr:system
      :attr:purgeable                файлы, которые macOS может удалить сама, когда мало места
      :attr:clone                    клоны APFS (общие блоки посчитаны один раз)
      :attr:hidden-locked            скрытые, но не защищённые

    ВИДЫ ФАЙЛОВ (Настройки › Цвета › Виды файлов)
      :class:Видео          |:class:Изображения

    ПРИМЕРЫ
      *.mov;*.mp4;>500mb;>6months     большие старые видео
      :class:Архивы;|\\Downloads       архивы не из папки Загрузки
      |:red                           пометьте что-то красным — и оно исчезнет
    """

    static let tagsRu = """
    Теги — четыре цветные закладки, которые вы ставите на файлы и папки, пока исследуете диск.
    Они живут, пока открыто окно (или в снимке, который вы экспортируете).

      Наведите курсор на элемент и нажмите 1, 2, 3 или 4 (красный, жёлтый, зелёный, синий).
      ⌃1 … ⌃4 работают, даже пока вы вводите фильтр.
      Повторное нажатие той же цифры снимает тег. 0 снимает любой тег.
      ⌃0 очищает все теги в текущей области, включая скрытые фильтром элементы.

    Тег на папке при фильтрации действует на всё внутри неё, но цветной уголок
    показывается только у самой папки.

    ИДЕИ
      Прятать разобранное:   фильтр |:red, затем помечайте красным то, с чем закончили.
      Корзина покупок:       два окна на одной папке; в одном фильтр |:g, в другом :g.
                             Помечайте зелёным в первом — элементы переедут во второе.
                             Экспортируйте второе (Файл › Экспорт), чтобы получить список.
    """
}
