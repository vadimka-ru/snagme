import AppKit
import ServiceManagement

// SnagMe — menu bar agent.
// Приложение живёт в строке меню, без иконки в доке.

@main
struct SnagMeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var notchWindow: NotchWindow?
    private var doubleShift: DoubleShift?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Без иконки в доке — фоновый agent.
        NSApp.setActivationPolicy(.accessory)

        // Оверлей челки.
        let window = NotchWindow(metrics: .current())
        window.show()
        self.notchWindow = window

        // Захват из драга — только двойной Shift (⌥Space убран: конфликтует с
        // неразрывным пробелом в Figma/тексте). Требует Accessibility для глоб. монитора.
        let ds = DoubleShift()
        ds.onTrigger = { [weak self] in self?.notchWindow?.captureFromDrag() }
        ds.start()
        self.doubleShift = ds

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let url = Bundle.module.url(forResource: "MenuIcon", withExtension: "svg"),
               let icon = NSImage(contentsOf: url) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true // macOS перекрасит под тему бара
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "tray.and.arrow.down",
                                       accessibilityDescription: "SnagMe")
            }
        }

        rebuildMenu(on: item)
        self.statusItem = item
    }

    private func rebuildMenu(on item: NSStatusItem) {
        let menu = NSMenu()

        let dest = SaveManager.shared.destination
        let folderTitle = dest.map { "Папка: \($0.lastPathComponent)" } ?? "Папка не выбрана"
        let folderInfo = menu.addItem(withTitle: folderTitle, action: nil, keyEquivalent: "")
        folderInfo.isEnabled = false

        menu.addItem(withTitle: "Выбрать папку…", action: #selector(chooseFolder), keyEquivalent: "")
        if dest != nil {
            menu.addItem(withTitle: "Сбросить папку", action: #selector(resetFolder), keyEquivalent: "")
        }
        menu.addItem(.separator())

        let launch = menu.addItem(withTitle: "Запускать при входе",
                                  action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func chooseFolder() {
        SaveManager.shared.chooseFolder()
        if let item = statusItem { rebuildMenu(on: item) }
    }

    @objc private func resetFolder() {
        SaveManager.shared.clearFolder()
        if let item = statusItem { rebuildMenu(on: item) }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("SnagMe launch-at-login error: \(error.localizedDescription)")
        }
        if let item = statusItem { rebuildMenu(on: item) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
