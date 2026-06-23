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

        guard contentViewCustom.handlePasteboard(pb, fromHotkey: true) else { return }
        contentViewCustom.holdOpen(6.0) // не сворачивать во время полёта + после

        // Полёт миниатюры от курсора в челку → затем раскрытие панели.
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
            // Кнопка зажата = тащим файл → широкая зона. Просто курсор → узкая (у самой челки),
            // чтобы не мешать кликать по менюбару рядом.
            let dragging = NSEvent.pressedMouseButtons != 0
            let zone = dragging ? dragZoneFrame : hoverZoneFrame
            if zone.contains(mouse) { setExpanded(true) }
        }
    }

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

    // Просто курсор: узкая зона у самой челки — не мешает кликать менюбар рядом.
    private var hoverZoneFrame: NSRect {
        frame(for: NSSize(width: metrics.notchWidth + 8, height: metrics.notchHeight + 4))
    }
}
