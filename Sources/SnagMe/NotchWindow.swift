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
            contentViewCustom.setRevealed(false) { [weak self] in
                guard let self else { return }
                self.setFrame(self.collapsedFrame, display: true)
                self.ignoresMouseEvents = true
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
