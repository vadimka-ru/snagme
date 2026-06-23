import AppKit
import QuickLookThumbnailing

// Отрисовка оверлея по макету Figma + приём drag-and-drop.
@MainActor
final class NotchContentView: NSView {

    private let metrics: NotchMetrics

    private struct SavedInfo {
        let count: Int
        let name: String        // имя файла или "N images"
        let ext: String         // для одиночного; пусто для нескольких
        let size: String        // размер файла или суммарный
        let folder: String
    }

    // Превью текущего saved (до 3). Видео/PDF подгружаются асинхронно (QuickLook).
    private var currentPreviews: [NSImage] = []
    private var savedGeneration = 0

    // Чипсы папок (saved): что сохранили, список папок, скролл, хит-зоны.
    private var currentSavedURLs: [URL] = []
    private var folders: [URL] = []
    private var chipScrollOffset: CGFloat = 0
    private var chipMaxScroll: CGFloat = 0
    private var plusChipRect: NSRect?
    private var folderChipRects: [(rect: NSRect, name: String)] = []
    private var movedFolder: String?            // чип, куда перенесли (показывает check)
    private var chipCheckProgress: CGFloat = 0
    private var chipCheckTimer: Timer?
    private var isModalActive = false           // открыт системный диалог — не закрывать панель
    private var savedPollTimer: Timer?          // надёжное отслеживание курсора в saved
    private var savedOutsideSince: CFTimeInterval?
    private var savedHoldUntil: CFTimeInterval = 0  // держать открытой до (для хоткей-захвата)

    func holdOpen(_ seconds: CFTimeInterval) {
        savedHoldUntil = CACurrentMediaTime() + seconds
    }

    func savedPreview() -> NSImage? { currentPreviews.first }
    func restartEntrance() { startSavedEntrance() }
    func captureURLs(_ urls: [URL]) { handleSaved(sources: urls) }

    // Анимация «разлёта» элементов saved.
    private var savedEntranceStart: CFTimeInterval = 0
    private var savedEntranceTimer: Timer?
    private let savedEntranceDur: CGFloat = 0.34
    private let entranceSpread: CGFloat = 0.3   // разброс стаггера (для реверса при закрытии)

    // Зеркальное закрытие (обратный pop-разлёт).
    private var isClosing = false
    private var closeStart: CFTimeInterval = 0
    private let closeDur: CGFloat = 0.24
    private var closeTimer: Timer?
    private var closeCompletion: (() -> Void)?

    // Вращение лоадер-иконки в пилле пути.
    private var loaderAngle: CGFloat = 0
    private var loaderTimer: Timer?

    // Ховер кликабельных элементов + курсор-pointer.
    enum HoverKind: Equatable { case none, path, plus, folder(String) }
    private var hoveredKind: HoverKind = .none
    private var hoverTimer: Timer?

    private func pillBg(_ hovered: Bool) -> NSColor {
        hovered ? NSColor(white: 0.22, alpha: 0.92) : pillDark
    }

    func startHoverTracking() {
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHover() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if hoveredKind != .none { hoveredKind = .none; needsDisplay = true }
        NSCursor.arrow.set()
    }

    private func tickHover() {
        guard let win = window else { return }
        let m = NSEvent.mouseLocation
        let p = convert(NSPoint(x: m.x - win.frame.minX, y: m.y - win.frame.minY), from: nil)
        var kind: HoverKind = .none
        if let r = chooseButtonRect, r.contains(p) { kind = .path }
        else if let r = plusChipRect, r.contains(p) { kind = .plus }
        else { for c in folderChipRects where c.rect.contains(p) { kind = .folder(c.name); break } }

        if kind != hoveredKind { hoveredKind = kind; needsDisplay = true }
        (kind == .none ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    // Появление панели «из челки» (scale из точки челки + fade).
    private var revealProgress: CGFloat = 0
    private var revealTimer: Timer?
    private var revealFrom: CGFloat = 0
    private var revealTo: CGFloat = 0
    private var revealStart: CFTimeInterval = 0
    private let revealDur: CGFloat = 0.3
    private var revealDone: (() -> Void)?

    // Открытие: мгновенно показываем (reveal=1) и играем pop-разлёт элементов.
    func openPanel() {
        isClosing = false
        closeTimer?.invalidate(); closeTimer = nil
        setRevealed(true)        // плавный выезд полосы-челки (revealProgress 0→1)
        startSavedEntrance()     // pop-разлёт контента ниже
        startHoverTracking()
    }

    func setRevealed(_ shown: Bool, completion: (() -> Void)? = nil) {
        revealTimer?.invalidate()
        revealFrom = revealProgress
        revealTo = shown ? 1 : 0
        revealStart = CACurrentMediaTime()
        revealDone = completion
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, CGFloat((CACurrentMediaTime() - self.revealStart) / Double(self.revealDur)))
                let e = 1 - pow(1 - p, 3)
                self.revealProgress = self.revealFrom + (self.revealTo - self.revealFrom) * e
                self.needsDisplay = true
                if p >= 1 {
                    self.revealTimer?.invalidate(); self.revealTimer = nil
                    let d = self.revealDone; self.revealDone = nil; d?()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        revealTimer = t
    }

    private enum State {
        case idle
        case targeted
        case saved(SavedInfo)
        case error(String)
    }
    private var state: State = .idle {
        didSet {
            needsDisplay = true
            if case .targeted = state { startDashAnimation() } else { stopDashAnimation() }
            if case .saved = state { startSavedPoll(); stopLoaderSpin() } else { startLoaderSpin() }
            window?.invalidateCursorRects(for: self)
            onRequestResize?() // форма плашки зависит от состояния
        }
    }

    // Надёжное закрытие saved: поллим позицию курсора против рамки окна.
    private func startSavedPoll() {
        savedPollTimer?.invalidate()
        savedOutsideSince = nil
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSavedPoll() }
        }
        RunLoop.main.add(t, forMode: .common)
        savedPollTimer = t
    }

    private func stopSavedPoll() {
        savedPollTimer?.invalidate()
        savedPollTimer = nil
        savedOutsideSince = nil
    }

    private func tickSavedPoll() {
        guard case .saved = state else { stopSavedPoll(); return }
        // Папка выбрана → закрытие жёстко по таймеру 0.5с (scheduleRevert), поллинг не вмешивается.
        if movedFolder != nil { return }
        // Открыт системный диалог — держим открытой.
        if isModalActive { savedOutsideSince = nil; return }
        // Hold-период после хоткей-захвата — держим открытой.
        if CACurrentMediaTime() < savedHoldUntil { savedOutsideSince = nil; return }

        let mouse = NSEvent.mouseLocation
        let inside = window?.frame.contains(mouse) ?? false
        if inside {
            savedOutsideSince = nil
        } else {
            if savedOutsideSince == nil {
                savedOutsideSince = CACurrentMediaTime()
            } else if CACurrentMediaTime() - savedOutsideSince! >= 1.2 {
                requestClose()
            }
        }
    }

    var onDragActiveChange: ((Bool) -> Void)?
    var onRequestResize: (() -> Void)? // просим окно переанимировать размер при смене формы

    // Желаемый размер окна по состоянию: saved — узкий/высокий, остальное — широкий.
    var desiredWindowSize: NSSize {
        if case .saved = state {
            let previewW: CGFloat = 240
            let previewH = previewW * previewAspect
            let panelContentH = 8 + previewH + 8
            let n = folders.count
            let folderColH: CGFloat = n > 0 ? 8 + CGFloat(n) * 32 + CGFloat(n - 1) * 8 : 0
            let maxFolderW = folders.map { folderPillWidth($0.lastPathComponent) }.max() ?? 0
            // Ширина: полоса-челка 360 ИЛИ превью+＋+колонка папок.
            let halfW = max(180, previewW / 2 + sideGap + 32, previewW / 2 + sideGap + maxFolderW)
            return NSSize(width: 2 * halfW, height: metrics.notchHeight + max(panelContentH, folderColH))
        }
        // idle / targeted / error — полоса 360 + дроп-плашка 240(80): gap8+плашка80+pad8.
        return NSSize(width: 360 + 32, height: metrics.notchHeight + 96)
    }

    // Зона кнопки «Выбрать папку» (idle без папки) для клика.
    private var chooseButtonRect: NSRect? {
        didSet {
            if chooseButtonRect != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }
    private var buttonHovered = false

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = chooseButtonRect, r.contains(p) {
            SaveManager.shared.chooseFolder()
            needsDisplay = true
            return
        }
        // Чипсы (saved): ＋ новая папка / тык по папке = перенос.
        if case .saved = state {
            if let plus = plusChipRect, plus.contains(p) {
                revertWork?.cancel()
                isModalActive = true
                let newFolder = SaveManager.shared.promptNewFolder()
                isModalActive = false
                if let newFolder {
                    let name = newFolder.lastPathComponent
                    folders = SaveManager.shared.subfolders()
                    currentSavedURLs = SaveManager.shared.move(currentSavedURLs, toFolderNamed: name)
                    movedFolder = name
                    startChipCheck()
                    scheduleRevert(after: 0.5) // создал+сохранил — закрываем быстро
                }
                // Cancel → savedPoll закроет сам (1.2с после ухода курсора).
                needsDisplay = true
                return
            }
            for chip in folderChipRects where chip.rect.contains(p) {
                currentSavedURLs = SaveManager.shared.move(currentSavedURLs, toFolderNamed: chip.name)
                movedFolder = chip.name
                startChipCheck()
                scheduleRevert(after: 0.5) // действие завершено — закрываем быстро
                return
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard case .saved = state else { return }
        chipScrollOffset = max(chipMaxScroll, min(0, chipScrollOffset + event.scrollingDeltaX))
        revertWork?.cancel()
        needsDisplay = true
    }

    private func prepareChips(savedURLs: [URL]) {
        currentSavedURLs = savedURLs
        folders = SaveManager.shared.subfolders()
        chipScrollOffset = 0
        movedFolder = nil
        chipCheckTimer?.invalidate(); chipCheckTimer = nil
        chipCheckProgress = 0
    }

    private func startChipCheck() {
        chipCheckTimer?.invalidate()
        chipCheckProgress = 0
        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.chipCheckProgress = min(1, CGFloat((CACurrentMediaTime() - start) / 0.42))
                self.needsDisplay = true
                if self.chipCheckProgress >= 1 { self.chipCheckTimer?.invalidate(); self.chipCheckTimer = nil }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        chipCheckTimer = t
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // Курсор-pointer над кнопкой (канонический механизм AppKit).
    override func resetCursorRects() {
        super.resetCursorRects()
        if case .idle = state, SaveManager.shared.destination == nil, let r = chooseButtonRect {
            addCursorRect(r, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let over = chooseButtonRect?.contains(p) ?? false
        if over != buttonHovered {
            buttonHovered = over
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if buttonHovered { buttonHovered = false; needsDisplay = true }
    }

    var wantsKeepOpen: Bool {
        switch state {
        case .targeted, .saved, .error: return true
        case .idle: return false
        }
    }

    private var dashPhase: CGFloat = 0
    private var dashTimer: Timer?
    private var revertWork: DispatchWorkItem?

    // Анимация галочки при сохранении (0→1).
    private var checkProgress: CGFloat = 0
    private var checkTimer: Timer?
    private var checkStart: CFTimeInterval = 0
    private let checkDuration: CFTimeInterval = 0.42

    // Иконка-галочка из ресурсов (.app). В debug-сборке без бандла — nil.
    private lazy var checkImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Check", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    // Иконка «добавить папку» для кнопки выбора.
    private lazy var addFolderImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AddFolder", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()
    private lazy var folderImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Folder", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()
    private lazy var approveFolderImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ApproveFolder", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()
    private lazy var approveFolderGreen: NSImage? = approveFolderImage?.tinting(with: savedGreen)
    private lazy var loaderImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Loader", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    // MARK: - Палитра из макета
    private let panelTop = NSColor(white: 0.0, alpha: 0.86)
    private let panelBottom = NSColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 0.86)
    private let mint = NSColor(red: 0x91/255, green: 0xff/255, blue: 0xce/255, alpha: 1)
    private let savedGreen = NSColor(red: 0x1e/255, green: 0xc7/255, blue: 0x7b/255, alpha: 1)
    private let white12 = NSColor(white: 1, alpha: 0.12)
    private let white24 = NSColor(white: 1, alpha: 0.24)
    private let white56 = NSColor(white: 1, alpha: 0.56)

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true

        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    // MARK: - Анимация пунктира

    private func startDashAnimation() {
        guard dashTimer == nil else { return }
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dashPhase -= 1
                if self.dashPhase < -1000 { self.dashPhase = 0 }
                if case .targeted = self.state { self.needsDisplay = true }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dashTimer = t
    }

    private func stopDashAnimation() {
        dashTimer?.invalidate()
        dashTimer = nil
    }

    private func startLoaderSpin() {
        guard loaderTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loaderAngle -= 6
                if self.loaderAngle < -3600 { self.loaderAngle = 0 }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        loaderTimer = t
    }

    private func stopLoaderSpin() {
        loaderTimer?.invalidate()
        loaderTimer = nil
    }

    private func startCheckAnimation() {
        checkTimer?.invalidate()
        checkProgress = 0
        checkStart = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - self.checkStart
                self.checkProgress = min(1, CGFloat(elapsed / self.checkDuration))
                self.needsDisplay = true
                if self.checkProgress >= 1 {
                    self.checkTimer?.invalidate()
                    self.checkTimer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t
    }

    // MARK: - Drag destination

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        revertWork?.cancel()
        state = .targeted
        onDragActiveChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if case .targeted = state { state = .idle }
        onDragActiveChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragActiveChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handlePasteboard(sender.draggingPasteboard)
    }

    private func saveImageObject(_ img: NSImage) {
        switch SaveManager.shared.save(image: img) {
        case .saved(let url, let folder):
            currentPreviews = [img]
            prepareChips(savedURLs: [url])
            showSaved(SavedInfo(count: 1, name: url.deletingPathExtension().lastPathComponent,
                                ext: url.pathExtension.lowercased(), size: fileSizeString(url), folder: folder))
        case .noFolder: showError("Pick a folder first")
        case .failed(let m): showError(m)
        }
    }

    // Общий приём: дроп и хоткей (drag-pasteboard).
    // fromHotkey=true: файлы-промисы не материализованы в драге — берём только существующие/картинку.
    @discardableResult
    func handlePasteboard(_ pb: NSPasteboard, fromHotkey: Bool = false) -> Bool {
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }

        if fromHotkey {
            // Скриншот-превью отдаёт промис-URL (копия падает) → берём картинку из pasteboard первой.
            if let img = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first {
                saveImageObject(img)
                return true
            }
            if !existing.isEmpty { handleSaved(sources: existing); return true }
            return false // нечего захватывать — тихий no-op (окно ловит скриншот с диска отдельно)
        }

        // Обычный дроп: реальные файлы → promise → картинка.
        if !existing.isEmpty {
            handleSaved(sources: existing)
            return true
        }

        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                          options: nil) as? [NSFilePromiseReceiver],
           let receiver = receivers.first {
            let dir = FileManager.default.temporaryDirectory
            receiver.receivePromisedFiles(atDestination: dir, options: [:],
                                          operationQueue: .main) { [weak self] url, error in
                if let error {
                    self?.showError(error.localizedDescription)
                } else {
                    self?.handleSaved(sources: [url])
                }
            }
            return true
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first {
            saveImageObject(img)
            return true
        }

        showError("Unsupported type")
        return false
    }

    // Сохранение одного или нескольких файлов.
    private func handleSaved(sources: [URL]) {
        var saved: [URL] = []
        var folder = ""
        var totalBytes: Int64 = 0
        var failMsg: String?

        for src in sources {
            switch SaveManager.shared.save(fileAt: src) {
            case .saved(let url, let f):
                saved.append(url); folder = f; totalBytes += fileBytes(url)
            case .noFolder: failMsg = "Pick a folder first"
            case .failed(let m): failMsg = m
            }
        }

        guard !saved.isEmpty else { showError(failMsg ?? "Error"); return }

        prepareChips(savedURLs: saved)

        savedGeneration += 1
        let gen = savedGeneration
        let firstThree = Array(saved.prefix(3))

        // Заглушки: картинка — сама, иначе иконка типа файла. Видео/PDF уточним через QuickLook.
        var placeholders: [NSImage] = []
        var needThumb: [(Int, URL)] = []
        for (i, url) in firstThree.enumerated() {
            if let img = NSImage(contentsOf: url) {
                placeholders.append(img)
            } else {
                placeholders.append(NSWorkspace.shared.icon(forFile: url.path))
                needThumb.append((i, url))
            }
        }
        currentPreviews = placeholders

        let info: SavedInfo
        if saved.count == 1 {
            let u = saved[0]
            info = SavedInfo(count: 1, name: u.deletingPathExtension().lastPathComponent,
                             ext: u.pathExtension.lowercased(), size: byteString(totalBytes), folder: folder)
        } else {
            info = SavedInfo(count: saved.count, name: "\(saved.count) images",
                             ext: "", size: byteString(totalBytes), folder: folder)
        }
        showSaved(info)

        for (i, url) in needThumb { requestThumbnail(url, index: i, gen: gen) }
    }

    // Кадр из видео / превью PDF и т.п. через QuickLook (async).
    private func requestThumbnail(_ url: URL, index: Int, gen: Int) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Запрос в nonisolated-контексте: completion QuickLook прилетает с фонового потока,
        // поэтому замыкание НЕ должно быть MainActor-привязано (иначе executor-check → краш).
        Self.generateThumbnail(url: url, scale: scale, index: index, gen: gen, target: self)
    }

    nonisolated private static func generateThumbnail(url: URL, scale: CGFloat,
                                                      index: Int, gen: Int, target: NotchContentView) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
                                               scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let rep else { return }
            nonisolated(unsafe) let img = rep.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    target.applyThumbnail(img, index: index, gen: gen)
                }
            }
        }
    }

    private func applyThumbnail(_ img: NSImage, index: Int, gen: Int) {
        guard savedGeneration == gen, index < currentPreviews.count else { return }
        if case .saved = state {
            currentPreviews[index] = img
            needsDisplay = true
        }
    }

    private func showSaved(_ info: SavedInfo) {
        state = .saved(info)
        startCheckAnimation()
        startSavedEntrance()
        // Закрытие saved ведёт savedPoll (надёжно по позиции курсора).
    }

    private func startSavedEntrance() {
        savedEntranceStart = CACurrentMediaTime()
        savedEntranceTimer?.invalidate()
        let total = Double(savedEntranceDur) + 0.12 + Double(max(folders.count, 1)) * 0.04 + 0.1
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsDisplay = true
                if CACurrentMediaTime() - self.savedEntranceStart >= total {
                    self.savedEntranceTimer?.invalidate(); self.savedEntranceTimer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        savedEntranceTimer = t
    }

    // Трансформ появления/исчезновения элемента: scale-pop + fade со стаггером.
    private func entrance(center: NSPoint, delay: CGFloat, _ body: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { body(); return }
        let t: CGFloat
        if isClosing {
            // Реверс: элементы с большим delay (папки) закрываются первыми.
            let elapsed = CGFloat(CACurrentMediaTime() - closeStart)
            let closeDelay = max(0, entranceSpread - delay)
            let tc = max(0, min(1, (elapsed - closeDelay) / closeDur))
            t = 1 - tc
        } else {
            let elapsed = CGFloat(CACurrentMediaTime() - savedEntranceStart)
            t = max(0, min(1, (elapsed - delay) / savedEntranceDur))
        }
        let c1: CGFloat = 1.2
        let e = 1 + (c1 + 1) * pow(t - 1, 3) + c1 * pow(t - 1, 2) // easeOutBack
        let scale = 0.8 + 0.2 * e
        ctx.saveGState()
        ctx.setAlpha(Double(t))
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -center.x, y: -center.y)
        body()
        ctx.restoreGState()
    }

    // Зеркальное закрытие: обратный pop, затем completion (сворачивание окна).
    func startClose(completion: @escaping () -> Void) {
        closeCompletion = completion
        isClosing = true
        closeStart = CACurrentMediaTime()
        setRevealed(false) // полоса-челка тоже уезжает
        closeTimer?.invalidate()
        let total = Double(closeDur + entranceSpread) + 0.04
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsDisplay = true
                if CACurrentMediaTime() - self.closeStart >= total {
                    self.closeTimer?.invalidate(); self.closeTimer = nil
                    self.isClosing = false
                    let c = self.closeCompletion; self.closeCompletion = nil
                    c?()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        closeTimer = t
    }

    private func showError(_ msg: String) {
        state = .error(msg)
        scheduleRevert()
    }

    // Закрытие сворачивает окно из текущего состояния (без вспышки idle).
    var onRequestClose: (() -> Void)?

    private func requestClose() {
        revertWork?.cancel()
        stopSavedPoll()
        onRequestClose?()
    }

    // Сброс в idle — вызывается окном ПОСЛЕ полного сворачивания (не видно).
    func resetToIdle() {
        if case .idle = state { return }
        state = .idle
    }

    private func scheduleRevert(after: TimeInterval = 2.0) {
        revertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestClose() }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func fileBytes(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func fileSizeString(_ url: URL) -> String {
        byteString(fileBytes(url))
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let notchH = metrics.notchHeight
        let cx = b.midX
        let p = revealProgress

        // Челка-полоса: ширина анимируется notchWidth → 360 (выезжают крылья).
        let notchW = min(metrics.notchWidth, b.width)
        let barW = notchW + (360 - notchW) * p
        let bar = NSRect(x: cx - barW / 2, y: 0, width: barW, height: notchH)
        NSColor.black.setFill()
        bottomRoundedPath(in: bar, radius: 16).fill()

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Контент крыльев (имя папки/Saved слева, лоадер/check справа), alpha p.
        if p > 0.01 {
            ctx.saveGState(); ctx.setAlpha(Double(p))
            drawBarWings(bar: bar)
            ctx.restoreGState()
        } else {
            chooseButtonRect = nil
        }

        // Контент ниже челки — pop-разлёт/схлоп через entrance() (свой alpha+scale).
        guard b.height > notchH + 1 else { return }
        if case .saved(let info) = state {
            drawSavedFloating(in: b, notchH: notchH, info: info)
        } else {
            drawDropFloating(in: b, notchH: notchH)
        }
    }

    // Плавающая drop-плашка (путь/Saved теперь в полосе-челке).
    private func drawDropFloating(in b: NSRect, notchH: CGFloat) {
        let cx = b.midX
        let dropW: CGFloat = 240
        let hasFolder = SaveManager.shared.destination != nil

        // Тёмная плашка с пунктиром (240, центр), сразу под челкой.
        let blob = NSRect(x: cx - dropW / 2, y: notchH + 8, width: dropW, height: 80)
        entrance(center: NSPoint(x: blob.midX, y: blob.midY), delay: 0.06) {
            let blobPath = NSBezierPath(roundedRect: blob, xRadius: 16, yRadius: 16)
            NSGraphicsContext.current?.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor(white: 0, alpha: 0.12)
            sh.shadowOffset = NSSize(width: 0, height: -8)
            sh.shadowBlurRadius = 12
            sh.set()
            self.panelBottom.setFill()
            blobPath.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            if let gradient = NSGradient(starting: self.panelTop, ending: self.panelBottom) {
                gradient.draw(in: blobPath, angle: 90)
            }

            let label: String
            let color: NSColor
            var animated = false
            switch self.state {
            case .targeted: label = "Drop it"; color = self.mint; animated = true
            case .error(let m): label = m; color = .systemRed
            default: label = hasFolder ? "Drop the pic here" : "Сначала выбери папку"
                     color = NSColor(white: 1, alpha: 0.9)
            }
            let inner = blob.insetBy(dx: 4, dy: 4)
            let dashed = NSBezierPath(roundedRect: inner, xRadius: 12, yRadius: 12)
            dashed.lineWidth = 1
            dashed.setLineDash([6, 5], count: 2, phase: animated ? self.dashPhase : 0)
            (animated ? self.mint : NSColor(white: 1, alpha: 0.3)).setStroke()
            dashed.stroke()
            let isError: Bool = { if case .error = self.state { return true } else { return false } }()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: isError ? 13 : 16, weight: .regular), .foregroundColor: color
            ]
            let display = self.truncate(label, attrs: attrs, maxWidth: inner.width - 16)
            let sz = display.size(withAttributes: attrs)
            display.draw(at: NSPoint(x: inner.midX - sz.width / 2, y: inner.midY - sz.height / 2), withAttributes: attrs)
        }
    }

    private func drawDropZone(in rect: NSRect, label: String, stroke: NSColor, text: NSColor, animated: Bool) {
        let box = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        box.lineWidth = 1
        box.setLineDash([6, 5], count: 2, phase: animated ? dashPhase : 0)
        stroke.setStroke()
        box.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: text
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                   withAttributes: attrs)
    }

    // Кнопка «Выбрать папку» (idle без выбранной папки).
    private func drawChooseFolder(in rect: NSRect) {
        let label = "Выбрать папку"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let iconW: CGFloat = 18
        let gap: CGFloat = 6
        let textSize = label.size(withAttributes: attrs)
        let padX: CGFloat = 16
        let btnW = iconW + gap + textSize.width + padX * 2
        let btnH: CGFloat = 36
        let btn = NSRect(x: rect.midX - btnW / 2, y: rect.midY - btnH / 2, width: btnW, height: btnH)
        chooseButtonRect = btn

        NSColor(white: 1, alpha: buttonHovered ? 0.24 : 0.14).setFill()
        NSBezierPath(roundedRect: btn, xRadius: 10, yRadius: 10).fill()

        let iconRect = NSRect(x: btn.minX + padX, y: btn.midY - iconW / 2, width: iconW, height: iconW)
        if let folder = addFolderImage {
            folder.draw(in: iconRect, from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
        } else if let fallback = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            fallback.withSymbolConfiguration(cfg)?.tinting(with: .white)
                .draw(in: iconRect, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
        label.draw(at: NSPoint(x: iconRect.maxX + gap, y: btn.midY - textSize.height / 2),
                   withAttributes: attrs)
    }

    // Вёрстка saved по макету 23:49: превью → check+Saved → чипсы. Отступы pt16/gap8/gap2/gap16/pb8.
    private func drawSaved(in rect: NSRect, info: SavedInfo) {
        // 1) Превью (pt16), white/12 r16, картинка 87×56 r12 + тёмный оверлей 0.2.
        let thumb = NSRect(x: rect.midX - 47, y: rect.minY + 16, width: 94, height: 64)
        white12.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 16, yRadius: 16).fill()
        if info.count > 1, !currentPreviews.isEmpty {
            drawStack(currentPreviews, in: thumb)
        } else if let preview = currentPreviews.first {
            let imgBox = NSRect(x: thumb.midX - 87/2, y: thumb.midY - 56/2, width: 87, height: 56)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: imgBox, xRadius: 12, yRadius: 12).setClip()
            drawCover(preview, in: imgBox)
            NSColor(white: 0, alpha: 0.2).setFill()
            imgBox.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // 2) check (16) над «Saved» (12 medium), gap8 от превью, gap2 между.
        let checkRect = NSRect(x: rect.midX - 8, y: thumb.maxY + 8, width: 16, height: 16)
        drawAnimatedCheck(in: checkRect, progress: checkProgress)
        let savedAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: savedGreen
        ]
        let savedText = "Saved"
        let stW = savedText.size(withAttributes: savedAttrs).width
        savedText.draw(at: NSPoint(x: rect.midX - stW / 2, y: checkRect.maxY + 2), withAttributes: savedAttrs)

        // 3) Чипсы (pb8).
        drawChips(in: rect)
    }

    // MARK: - Новый плавающий saved (макет 43:367)

    private let sideGap: CGFloat = 8
    private let pillDark = NSColor(white: 0.0, alpha: 0.85) // тёмный фон пилла — читается на любом фоне
    private let previewAspect: CGFloat = 2214.0 / 3420.0

    private func folderPillWidth(_ name: String) -> CGFloat {
        8 + 16 + 6 + name.size(withAttributes: chipNameAttrs).width + 12
    }

    private func drawFloatingPill(_ rect: NSRect, color: NSColor) {
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.18)
        sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.shadowBlurRadius = 8
        sh.set()
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func rootPathLabel() -> String {
        guard let dest = SaveManager.shared.destination else { return "Выбрать папку" }
        let home = NSHomeDirectory()
        return dest.path.hasPrefix(home) ? "~" + dest.path.dropFirst(home.count) : dest.lastPathComponent
    }

    // Контент «крыльев» челки-полосы: слева имя/Saved, справа лоадер/check.
    private func drawBarWings(bar: NSRect) {
        if case .saved = state {
            chooseButtonRect = nil
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: savedGreen]
            "Saved".draw(at: NSPoint(x: bar.minX + 8, y: bar.midY - 7), withAttributes: a)
            drawAnimatedCheck(in: NSRect(x: bar.maxX - 8 - 16, y: bar.midY - 8, width: 16, height: 16),
                              progress: checkProgress)
            return
        }
        // idle / targeted: вся полоса кликабельна → выбор корня.
        chooseButtonRect = bar
        let hasFolder = SaveManager.shared.destination != nil
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: hasFolder ? NSColor(white: 1, alpha: 0.85) : savedGreen]
        (hasFolder ? rootPathLabel() : "Выбрать папку")
            .draw(at: NSPoint(x: bar.minX + 8, y: bar.midY - 7), withAttributes: a)
        if let loader = loaderImage, let ctx = NSGraphicsContext.current?.cgContext {
            let lr = NSRect(x: bar.maxX - 8 - 16, y: bar.midY - 8, width: 16, height: 16)
            let lc = NSPoint(x: lr.midX, y: lr.midY)
            ctx.saveGState()
            ctx.translateBy(x: lc.x, y: lc.y); ctx.rotate(by: loaderAngle * .pi / 180); ctx.translateBy(x: -lc.x, y: -lc.y)
            loader.draw(in: lr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }
    }

    private func drawSavedFloating(in b: NSRect, notchH: CGFloat, info: SavedInfo) {
        let cx = b.midX
        let previewW: CGFloat = 240
        let previewH = previewW * previewAspect

        // Превью 240 сразу под челкой (Saved/check теперь в полосе-челке).
        let preview = NSRect(x: cx - previewW / 2, y: notchH + 8, width: previewW, height: previewH)
        entrance(center: NSPoint(x: preview.midX, y: preview.midY), delay: 0.05) {
            if info.count > 1, !currentPreviews.isEmpty {
                // Мультидроп — стопка веером на тёмной подложке.
                drawFloatingPill(preview, color: pillDark)
                drawStack(currentPreviews, in: preview)
            } else if let p = currentPreviews.first {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(roundedRect: preview, xRadius: 16, yRadius: 16).setClip()
                drawCover(p, in: preview)
                NSColor(white: 0, alpha: 0.2).setFill()
                preview.fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }

        // 3) ＋ слева от превью.
        let plus = NSRect(x: preview.minX - sideGap - 32, y: preview.minY, width: 32, height: 32)
        plusChipRect = plus
        entrance(center: NSPoint(x: plus.midX, y: plus.midY), delay: 0.1) {
            drawFloatingPill(plus, color: self.pillBg(self.hoveredKind == .plus))
            addFolderImage?.draw(in: NSRect(x: plus.midX - 8, y: plus.midY - 8, width: 16, height: 16),
                                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // 4) Колонка папок справа от превью, вертикально (стаггер).
        folderChipRects = []
        let colX = preview.maxX + sideGap
        var y = preview.minY
        for (i, f) in folders.enumerated() {
            let nm = f.lastPathComponent
            let w = folderPillWidth(nm)
            let chip = NSRect(x: colX, y: y, width: w, height: 32)
            folderChipRects.append((chip, nm))
            entrance(center: NSPoint(x: chip.midX, y: chip.midY), delay: 0.12 + CGFloat(i) * 0.04) {
                drawFloatingPill(chip, color: self.pillBg(self.hoveredKind == .folder(nm)))
                let iconRect = NSRect(x: chip.minX + 8, y: chip.midY - 8, width: 16, height: 16)
                if movedFolder == nm {
                    drawIconPop(approveFolderGreen, in: iconRect, progress: chipCheckProgress)
                } else {
                    folderImage?.draw(in: iconRect, from: .zero, operation: .sourceOver,
                                      fraction: 1, respectFlipped: true, hints: nil)
                }
                nm.draw(at: NSPoint(x: iconRect.maxX + 6, y: chip.midY - 7), withAttributes: chipNameAttrs)
            }
            y += 32 + 8
        }
    }

    // Чипсы (по макету 23:79): центрированная группа; при переполнении — ＋ слева + скролл.
    private let chipNameAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white
    ]
    private let chipH: CGFloat = 32
    private let chipIcon: CGFloat = 16
    private let chipInnerGap: CGFloat = 6
    private let chipPadX: CGFloat = 8
    private let chipGap: CGFloat = 8
    private let plusW: CGFloat = 32

    private func folderChipWidth(_ name: String) -> CGFloat {
        chipPadX + chipIcon + chipInnerGap + name.size(withAttributes: chipNameAttrs).width + chipPadX
    }

    private func drawChips(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rowY = rect.maxY - 8 - chipH
        folderChipRects = []

        let widths = folders.map { folderChipWidth($0.lastPathComponent) }
        let totalW = plusW + widths.reduce(0) { $0 + chipGap + $1 }
        let avail = rect.width - 16

        if totalW <= avail {
            // Центрированная группа, без скролла.
            chipMaxScroll = 0; chipScrollOffset = 0
            var x = rect.midX - totalW / 2
            drawPlusChip(at: NSRect(x: x, y: rowY, width: plusW, height: chipH))
            x += plusW + chipGap
            for (i, f) in folders.enumerated() {
                let chip = NSRect(x: x, y: rowY, width: widths[i], height: chipH)
                drawFolderChip(at: chip, name: f.lastPathComponent)
                folderChipRects.append((chip, f.lastPathComponent))
                x += widths[i] + chipGap
            }
        } else {
            // Переполнение: ＋ запинен слева, папки скроллятся.
            let plus = NSRect(x: rect.minX + 8, y: rowY, width: plusW, height: chipH)
            drawPlusChip(at: plus)
            let regionX = plus.maxX + chipGap
            let region = NSRect(x: regionX, y: rowY, width: rect.maxX - 8 - regionX, height: chipH)
            let scrollTotal = widths.reduce(0) { $0 + $1 + chipGap } - (widths.isEmpty ? 0 : chipGap)
            chipMaxScroll = min(0, region.width - scrollTotal)
            chipScrollOffset = max(chipMaxScroll, min(0, chipScrollOffset))
            ctx.saveGState()
            NSBezierPath(rect: region).addClip()
            var x = regionX + chipScrollOffset
            for (i, f) in folders.enumerated() {
                let chip = NSRect(x: x, y: rowY, width: widths[i], height: chipH)
                drawFolderChip(at: chip, name: f.lastPathComponent)
                folderChipRects.append((chip, f.lastPathComponent))
                x += widths[i] + chipGap
            }
            ctx.restoreGState()
        }
    }

    private func drawPlusChip(at rect: NSRect) {
        plusChipRect = rect
        white12.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        addFolderImage?.draw(in: NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawFolderChip(at chip: NSRect, name: String) {
        white12.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 16, yRadius: 16).fill()
        let iconRect = NSRect(x: chip.minX + chipPadX, y: chip.midY - chipIcon / 2,
                              width: chipIcon, height: chipIcon)
        if movedFolder == name {
            drawIconPop(approveFolderGreen, in: iconRect, progress: chipCheckProgress)
        } else {
            folderImage?.draw(in: iconRect, from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
        }
        name.draw(at: NSPoint(x: iconRect.maxX + chipInnerGap, y: chip.midY - 7), withAttributes: chipNameAttrs)
    }

    // MARK: - Helpers

    // Анимированная галочка: кружок впрыгивает (scale-pop) + чек прорисовывается.
    private func drawAnimatedCheck(in rect: NSRect, progress p: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Pop-масштаб с лёгким перелётом.
        let sp = min(p / 0.45, 1)
        let c1: CGFloat = 1.2, c3 = 1.2 + 1
        let pop = sp >= 1 ? 1 : 1 + c3 * pow(sp - 1, 3) + c1 * pow(sp - 1, 2)
        let scale = 0.4 + 0.6 * pop

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -center.x, y: -center.y)

        func pt(_ sx: CGFloat, _ sy: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + sx / 16 * rect.width, y: rect.minY + sy / 16 * rect.height)
        }

        // Кружок обводится по дуге (sweep 0→360°).
        let circleFrac = max(0, min(1, p / 0.6))
        if circleFrac > 0.001 {
            let inset = rect.insetBy(dx: 1.4, dy: 1.4)
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = inset.width / 2
            let sweep = circleFrac * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = 1.4
            arc.lineCapStyle = .round
            savedGreen.setStroke()
            arc.stroke()
        }

        // Чек прорисовывается по длине (после кружка).
        let a = pt(5.0, 8.0), b = pt(7.0, 10.1), c = pt(11.0, 5.9)
        let l1 = hypot(b.x - a.x, b.y - a.y)
        let l2 = hypot(c.x - b.x, c.y - b.y)
        let frac = max(0, min(1, (p - 0.5) / 0.5))
        let drawLen = frac * (l1 + l2)
        if drawLen > 0.01 {
            let path = NSBezierPath()
            path.move(to: a)
            if drawLen <= l1 {
                let t = drawLen / l1
                path.line(to: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            } else {
                path.line(to: b)
                let t = (drawLen - l1) / l2
                path.line(to: NSPoint(x: b.x + (c.x - b.x) * t, y: b.y + (c.y - b.y) * t))
            }
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            savedGreen.setStroke()
            path.stroke()
        }

        ctx.restoreGState()
    }

    // Стопка картинок веером (фото с белой рамкой). Размер карточек от контейнера.
    private func drawStack(_ previews: [NSImage], in thumb: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imgs = Array(previews.prefix(3))
        let cardH = thumb.height * 0.78
        let cardW = cardH * 0.76

        // (угол°, сдвиг X). Крайние сзади, центральная сверху.
        let layouts: [(CGFloat, CGFloat)] = imgs.count >= 3
            ? [(-14, -11), (13, 11), (0, 0)]
            : [(-10, -7), (9, 7)]

        let dxScale = cardW / 38 // сдвиги пропорционально размеру карточки
        for (i, img) in imgs.enumerated() {
            let (angle, dx) = layouts[i]
            let c = NSPoint(x: thumb.midX + dx * dxScale, y: thumb.midY)
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.translateBy(x: -c.x, y: -c.y)

            let card = NSRect(x: c.x - cardW / 2, y: c.y - cardH / 2, width: cardW, height: cardH)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 4, yRadius: 4).fill()

            let imgRect = card.insetBy(dx: 3, dy: 3)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: imgRect, xRadius: 2, yRadius: 2).setClip()
            drawCover(img, in: imgRect)
            NSGraphicsContext.current?.restoreGraphicsState()

            ctx.restoreGState()
        }
    }

    // Иконка с лёгким scale-pop (для approve_folder после переноса).
    private func drawIconPop(_ image: NSImage?, in rect: NSRect, progress p: CGFloat) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sp = min(p / 0.6, 1)
        let c1: CGFloat = 1.2
        let pop = sp >= 1 ? 1 : 1 + (c1 + 1) * pow(sp - 1, 3) + c1 * pow(sp - 1, 2)
        let scale = 0.5 + 0.5 * pop
        let c = NSPoint(x: rect.midX, y: rect.midY)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        image.draw(in: rect, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }

    private func drawCover(_ image: NSImage, in rect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        let drawRect = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        // respectFlipped: вью перевёрнут (isFlipped), иначе картинка вверх ногами.
        image.draw(in: drawRect, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }

    private func truncate(_ s: String, attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> String {
        if s.size(withAttributes: attrs).width <= maxWidth { return s }
        var r = s
        while r.size(withAttributes: attrs).width > maxWidth && r.count > 2 {
            r = String(r.dropLast())
        }
        return r + "…"
    }

    // Вогнутые филлеты у верхних углов плашки (стык с менюбаром).
    private func drawFillets(blobRect: NSRect, radius R: CGFloat) {
        let k: CGFloat = 0.5523
        let top = blobRect.minY
        panelTop.setFill()

        // Левый.
        let left = blobRect.minX
        let lp = NSBezierPath()
        lp.move(to: NSPoint(x: left, y: top))
        lp.line(to: NSPoint(x: left - R, y: top))
        lp.curve(to: NSPoint(x: left, y: top + R),
                 controlPoint1: NSPoint(x: left - R * (1 - k), y: top),
                 controlPoint2: NSPoint(x: left, y: top + R * (1 - k)))
        lp.close()
        lp.fill()

        // Правый (зеркально).
        let right = blobRect.maxX
        let rp = NSBezierPath()
        rp.move(to: NSPoint(x: right, y: top))
        rp.line(to: NSPoint(x: right + R, y: top))
        rp.curve(to: NSPoint(x: right, y: top + R),
                 controlPoint1: NSPoint(x: right + R * (1 - k), y: top),
                 controlPoint2: NSPoint(x: right, y: top + R * (1 - k)))
        rp.close()
        rp.fill()
    }

    private func bottomRoundedPath(in rect: NSRect, radius r: CGFloat) -> NSBezierPath {
        let rr = min(r, rect.height, rect.width / 2)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - rr))
        p.appendArc(withCenter: NSPoint(x: rect.maxX - rr, y: rect.maxY - rr),
                    radius: rr, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: rect.minX + rr, y: rect.maxY))
        p.appendArc(withCenter: NSPoint(x: rect.minX + rr, y: rect.maxY - rr),
                    radius: rr, startAngle: 90, endAngle: 180)
        p.close()
        return p
    }
}

private extension NSImage {
    func tinting(with color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        rect.fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
