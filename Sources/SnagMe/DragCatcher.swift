import AppKit

// Полноэкранное прозрачное окно-«ловушка»: ловит отпускание драга после хоткей-захвата,
// чтобы файл не дропнулся в браузер/другое приложение. Без разрешений.
@MainActor
final class DragCatcher {
    static let shared = DragCatcher()
    private var win: NSWindow?
    private var timeout: Timer?

    func begin() {
        guard win == nil else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .statusBar
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let v = CatcherView()
        v.onEnd = { [weak self] in self?.end() }
        w.contentView = v
        w.orderFrontRegardless()
        win = w

        // Фолбэк: если drop не прилетел (отпустили вне/драг отменён) — закрыть через 6с.
        timeout?.invalidate()
        let t = Timer(timeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated { DragCatcher.shared.end() }
        }
        RunLoop.main.add(t, forMode: .common)
        timeout = t
    }

    func end() {
        timeout?.invalidate(); timeout = nil
        win?.orderOut(nil); win = nil
    }
}

@MainActor
private final class CatcherView: NSView {
    var onEnd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onEnd?(); return true // съедаем — уже захвачено хоткеем
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onEnd?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onEnd?() }
}
