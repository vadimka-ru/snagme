import AppKit

// Результат сохранения для UI.
enum SaveOutcome {
    case saved(url: URL, folder: String)
    case noFolder
    case failed(String)
}

// Сохранение рефов в выбранную папку (фаза 4).
// Sandbox/security-scoped bookmarks — фаза 6. Пока обычный путь в UserDefaults.
@MainActor
final class SaveManager {
    static let shared = SaveManager()

    private let defaultsKey = "destinationPath"

    var destination: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: defaultsKey)
        }
    }

    // Сброс выбранной папки (для тестов).
    func clearFolder() {
        destination = nil
    }

    // Подпапки корневой папки (1 уровень), для чипсов.
    func subfolders() -> [URL] {
        guard let dir = destination else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    @discardableResult
    func createFolder(named name: String) -> URL? {
        guard let dir = destination else { return nil }
        let url = dir.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch { return nil }
    }

    // Системный диалог: имя новой папки.
    func promptNewFolder() -> URL? {
        let alert = NSAlert()
        alert.messageText = "Новая папка"
        alert.informativeText = "Имя папки — реф сразу в неё"
        alert.addButton(withTitle: "Сохранить сюда")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "mobile"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return createFolder(named: name)
    }

    // Перенос файлов в подпапку. Возвращает новые URL.
    func move(_ urls: [URL], toFolderNamed name: String) -> [URL] {
        guard let dir = destination else { return urls }
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved: [URL] = []
        for u in urls {
            let target = uniqueURL(for: u.lastPathComponent, in: folder)
            do { try FileManager.default.moveItem(at: u, to: target); moved.append(target) }
            catch { moved.append(u) }
        }
        return moved
    }

    // Выбор папки через системный диалог.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Куда SnagMe будет сохранять рефы"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            destination = panel.url
        }
    }

    // Копирование готового файла.
    func save(fileAt source: URL) -> SaveOutcome {
        guard let dir = destination else { return .noFolder }
        let target = uniqueURL(for: source.lastPathComponent, in: dir)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return .saved(url: target, folder: dir.lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Сохранение сырого изображения как PNG.
    func save(image: NSImage, suggestedName: String = "ref") -> SaveOutcome {
        guard let dir = destination else { return .noFolder }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return .failed("не смог сконвертировать")
        }
        let target = uniqueURL(for: "\(suggestedName).png", in: dir)
        do {
            try png.write(to: target)
            return .saved(url: target, folder: dir.lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Не перезаписываем — при конфликте имени добавляем суффикс.
    private func uniqueURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
