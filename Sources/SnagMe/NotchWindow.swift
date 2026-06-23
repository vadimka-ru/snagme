import AppKit

// Геометрия челки текущего экрана.
struct NotchMetrics {
    let screenFrame: NSRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    @MainActor
    static func current() -> NotchMetrics {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let sf = screen.frame
        let top = screen.safeAreaInsets.top

        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchW = sf.width - left.width - right.width
            return NotchMetrics(screenFrame: sf, notchWidth: notchW, notchHeight: top, hasNotch: true)
        }
        return NotchMetrics(screenFrame: sf, notchWidth: 180, notchHeight: 32, hasNotch: false)
    }
}

@MainActor
final class NotchWindow: NSWindow {

    private let metrics: NotchMetrics
    private let contentViewCustom: NotchContentView

    private var isExpandedState = false
    private var isDragActive = false
    private var hoverTimer: Timer?

    // Свёрнуто: ширина чуть больше челки (чтобы плашка не уже челки в начале), высота — челка.
    private var collapsedSize: NSSize {
        NSSize(width: metrics.notchWidth + 34, height: metrics.notchHeight)
    }
    // Раскрыто: размер диктует контент (drop — широкий, saved — узкий/высокий).
    private var expandedSize: NSSize {
        contentViewCustom.desiredWindowSize
    }

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        self.contentViewCustom = NotchContentView(metrics: metrics)

        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 100, height: 100)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovable = false
        acceptsMouseMovedEvents = true // для hover-подсветки кнопки в панели

        contentView = contentViewCustom
        contentViewCustom.onDragActiveChange = { [weak self] active in
            self?.isDragActive = active
        }
        // Закрытие из контента (savedPoll / выбор папки) → свернуть окно.
        contentViewCustom.onRequestClose = { [weak self] in
            self?.setExpanded(false)
        }
        // Смена формы плашки (drop ↔ saved) — плавно переанимировать размер.
        contentViewCustom.onRequestResize = { [weak self] in
            guard let self, self.isExpandedState else { return }
            let target = self.expandedFrame
            if target.size != self.frame.size {
                self.animateFrame(to: target, duration: 0.42) {} // морфинг формы — чуть медленнее
            }
        }
    }

    func show() {
        setFrame(collapsedFrame, display: true)
        orderFrontRegardless()
        startHoverTracking()
    }

    // Захват из текущего драга по хоткею (⌥Space): читаем drag-pasteboard.
    func captureFromDrag() {
        let pb = NSPasteboard(name: .drag)
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]
        NSLog("SnagMe ⌥Space: drag pb → urls=\(urls.map { $0.lastPathComponent }), images=\(imgs?.count ?? 0)")

        if contentViewCustom.handlePasteboard(pb, fromHotkey: true) {
            cancelDrag() // отменяем драг — иначе отпустишь над браузером и он откроет картинку
            presentCapture()
        } else if let shot = latestScreenshot() {
            // Драг пуст, но недавно сделан скриншот — берём файл с диска.
            contentViewCustom.captureURLs([shot])
            presentCapture()
        }
    }

    // Отмена активного drag-and-drop (Escape). Требует Accessibility.
    private func cancelDrag() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let esc: CGKeyCode = 53
        CGEvent(keyboardEventSource: src, virtualKey: esc, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: esc, keyDown: false)?.post(tap: .cgSessionEventTap)
    }

    private func presentCapture() {
        contentViewCustom.holdOpen(6.0)
        let start = NSEvent.mouseLocation
        let notchPt = NSPoint(x: metrics.screenFrame.midX,
                              y: metrics.screenFrame.maxY - metrics.notchHeight / 2)
        if let img = contentViewCustom.savedPreview() {
            FlyAnimator.shared.fly(image: img, from: start, to: notchPt) { [weak self] in
                self?.presentAfterFly()
            }
        } else {
            presentAfterFly()
        }
    }

    // Новейший скриншот/картинка из папки скриншотов за последние 20с.
    private func latestScreenshot() -> URL? {
        let loc: URL = {
            if let p = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !p.isEmpty {
                return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        }()
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: loc, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return items
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                return (url, d)
            }
            .filter { Date().timeIntervalSince($0.1) < 20 }
            .max { $0.1 < $1.1 }?.0
    }

    private func presentAfterFly() {
        isExpandedState = true
        ignoresMouseEvents = false
        setFrame(expandedFrame, display: true)
        contentViewCustom.restartEntrance()
        contentViewCustom.setRevealed(true)
        contentViewCustom.startHoverTracking()
        contentViewCustom.holdOpen(4.0)
    }

    // MARK: - Hover через позицию курсора

    private func startHoverTracking() {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        if isExpandedState {
            if isDragActive { return }
            if !expandedFrame.contains(mouse) && !contentViewCustom.wantsKeepOpen {
                setExpanded(false)
            }
        } else {
            // Реальный файл-драг отличаем от клика: драг меняет changeCount drag-pasteboard.
            let dragCC = NSPasteboard(name: .drag).changeCount
            let pressed = NSEvent.pressedMouseButtons != 0
            if !pressed { dragBaselineCC = dragCC }
            let realDrag = pressed && dragCC != dragBaselineCC

            if realDrag {
                // Тащим файл → широкая зона, открываем сразу.
                hoverSince = nil
                if dragZoneFrame.contains(mouse) { setExpanded(true) }
            } else {
                // Просто курсор/клик → узкая зона (ровно челка) + задержка (dwell).
                if hoverZoneFrame.contains(mouse) {
                    if hoverSince == nil {
                        hoverSince = CACurrentMediaTime()
                    } else if CACurrentMediaTime() - hoverSince! >= 0.35 {
                        setExpanded(true)
                    }
                } else {
                    hoverSince = nil
                }
            }
        }
    }

    private var hoverSince: CFTimeInterval?
    private var dragBaselineCC = 0

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpandedState else { return }
        isExpandedState = expanded
        if expanded {
            // Мгновенно полный размер; элементы выпрыгивают pop-разлётом.
            ignoresMouseEvents = false
            setFrame(expandedFrame, display: true)
            contentViewCustom.openPanel()
        } else {
            // Контент уезжает в челку, затем сворачиваем окно.
            contentViewCustom.stopHoverTracking()
            contentViewCustom.startClose { [weak self] in
                guard let self else { return }
                self.setFrame(self.collapsedFrame, display: true)
                self.ignoresMouseEvents = true
                self.contentViewCustom.resetToIdle() // сброс уже после сворачивания — без вспышки
            }
        }
    }

    // MARK: - Своя плавная анимация рамки (обе оси), easeOutCubic.

    private var frameTimer: Timer?
    private var animFrom = NSRect.zero
    private var animTo = NSRect.zero
    private var animStart: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0.28

    private func animateFrame(to target: NSRect, duration: CFTimeInterval = 0.28,
                              completion: @escaping () -> Void) {
        frameTimer?.invalidate()
        animFrom = frame
        animTo = target
        animStart = CACurrentMediaTime()
        animDuration = duration
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, (CACurrentMediaTime() - self.animStart) / self.animDuration)
                let e = 1 - pow(1 - p, 3)
                let f = NSRect(
                    x: self.animFrom.minX + (self.animTo.minX - self.animFrom.minX) * e,
                    y: self.animFrom.minY + (self.animTo.minY - self.animFrom.minY) * e,
                    width: self.animFrom.width + (self.animTo.width - self.animFrom.width) * e,
                    height: self.animFrom.height + (self.animTo.height - self.animFrom.height) * e
                )
                self.setFrame(f, display: true)
                if p >= 1 {
                    self.frameTimer?.invalidate()
                    self.frameTimer = nil
                    completion()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    // MARK: - Геометрия

    private func frame(for size: NSSize) -> NSRect {
        let sf = metrics.screenFrame
        return NSRect(x: sf.midX - size.width / 2, y: sf.maxY - size.height,
                      width: size.width, height: size.height)
    }
    private var collapsedFrame: NSRect { frame(for: collapsedSize) }
    private var expandedFrame: NSRect { frame(for: expandedSize) }

    // Drag: широкая зона — раскрываем заранее при подходе файла снизу.
    private var dragZoneFrame: NSRect {
        let w = max(metrics.notchWidth + 140, 260)
        return frame(for: NSSize(width: w, height: metrics.notchHeight + 36))
    }

    // Просто курсор: зона = РОВНО вырез челки (без захода вниз), чтобы клик под
    // челкой (табы Figma/браузера) не открывал панель.
    private var hoverZoneFrame: NSRect {
        frame(for: NSSize(width: metrics.notchWidth, height: metrics.notchHeight))
    }
}
