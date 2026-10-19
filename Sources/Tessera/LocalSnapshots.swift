import AppKit
import TesseraCore

/// Local Time Machine snapshots: list them, and delete them with the administrator password.
@MainActor
enum LocalSnapshots {
    /// Snapshot dates like "2026-09-16-071635" on the given volume.
    static func list(volume: String = "/") -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshotdates", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil }
    }

    /// "16 сентября 2026, 07:16" from "2026-09-16-071635".
    static func pretty(_ stamp: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let date = parse.date(from: stamp) else { return stamp }
        let out = DateFormatter()
        out.locale = Lang.locale
        out.dateStyle = .long
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// Asks, then deletes every local snapshot of `volume`. Calls `done` when something was deleted.
    static func confirmAndDelete(volume: String = "/", purgeable: Int64, decimal: Bool, done: @escaping () -> Void) {
        let snapshots = list(volume: volume)
        guard !snapshots.isEmpty else {
            let alert = NSAlert()
            alert.messageText = tr("There are no local Time Machine snapshots.", "Локальных снимков Time Machine нет.")
            alert.informativeText = tr(
                "The purgeable space is held by something else (iCloud files kept on this Mac, caches). macOS frees it by itself when space runs low.",
                "Очищаемое место занято чем-то другим (файлы iCloud на этом Mac, кэши). macOS освободит его сама, когда места станет мало.")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Delete \(snapshots.count) local Time Machine snapshots?",
                               "Удалить локальные снимки Time Machine (\(snapshots.count))?")
        let listText = snapshots.map { "• " + pretty($0) }.joined(separator: "\n")
        alert.informativeText = tr("""
            \(listText)

            They keep old versions of files, including ones you deleted, and together hold about \(Format.size(purgeable, decimal: decimal)) (macOS doesn't report the exact size of each snapshot).
            Your backups on the Time Machine drive are not touched. Time Machine makes new local snapshots as it goes.
            You'll be asked for an administrator password.
            """, """
            \(listText)

            Они хранят старые версии файлов, в том числе удалённых, и вместе занимают около \(Format.size(purgeable, decimal: decimal)) (точный размер каждого снимка macOS не сообщает).
            Резервные копии на диске Time Machine не затрагиваются. Time Machine будет создавать новые локальные снимки как обычно.
            Понадобится пароль администратора.
            """)
        alert.addButton(withTitle: tr("Delete Snapshots", "Удалить снимки"))
        alert.addButton(withTitle: tr("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // One privileged shell command per snapshot date (dates are validated above).
        let commands = snapshots.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
        let prompt = tr("Tessera wants to delete local Time Machine snapshots.",
                        "Tessera хочет удалить локальные снимки Time Machine.")
        let source = "do shell script \"\(commands)\" with administrator privileges with prompt \"\(prompt)\""
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { return }   // the user cancelled the password prompt
            let fail = NSAlert()
            fail.messageText = tr("Couldn't delete the snapshots", "Не удалось удалить снимки")
            fail.informativeText = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            fail.runModal()
            return
        }

        let left = list(volume: volume)
        let ok = NSAlert()
        ok.messageText = left.isEmpty
            ? tr("Snapshots deleted.", "Снимки удалены.")
            : tr("Deleted \(snapshots.count - left.count) of \(snapshots.count) snapshots.",
                 "Удалено снимков: \(snapshots.count - left.count) из \(snapshots.count).")
        ok.informativeText = tr("APFS frees the space in the background; the free space in Tessera's title updates within a minute.",
                                "APFS освобождает место в фоне; свободное место в заголовке Tessera обновится в течение минуты.")
        ok.runModal()
        done()
    }
}
