import AppKit
import QuartzCore

// Полёт миниатюры захваченной картинки от курсора в челку.
@MainActor
final class FlyAnimator {
    static let shared = FlyAnimator()
    private var win: NSWindow?

    func fly(image: NSImage, from: NSPoint, to: NSPoint, completion: @escaping () -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(); return
        }
        let screen = NSScreen.screens.first { NSMouseInRect(from, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView?.wantsLayer = true

        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 1
        let startW: CGFloat = 120, startH = startW * aspect
        let endW: CGFloat = 30, endH = endW * aspect

        let layer = CALayer()
        layer.contents = cg
        layer.contentsGravity = .resizeAspectFill
        layer.cornerRadius = 10
        layer.masksToBounds = true

        let sCenter = CGPoint(x: from.x - screen.frame.minX, y: from.y - screen.frame.minY)
        let eCenter = CGPoint(x: to.x - screen.frame.minX, y: to.y - screen.frame.minY)
        layer.bounds = CGRect(x: 0, y: 0, width: startW, height: startH)
        layer.position = sCenter
        w.contentView?.layer?.addSublayer(layer)
        w.orderFrontRegardless()
        self.win = w

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            w.orderOut(nil); self?.win = nil; completion()
        }
        let dur: CFTimeInterval = 0.42
        let ease = CAMediaTimingFunction(name: .easeIn)

        // Финальные значения модели.
        layer.position = eCenter
        layer.bounds = CGRect(x: 0, y: 0, width: endW, height: endH)
        layer.opacity = 0

        let pos = CABasicAnimation(keyPath: "position"); pos.fromValue = sCenter
        let bnd = CABasicAnimation(keyPath: "bounds"); bnd.fromValue = CGRect(x: 0, y: 0, width: startW, height: startH)
        let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 1
        for a in [pos, bnd, op] { a.duration = dur; a.timingFunction = ease }
        layer.add(pos, forKey: "position")
        layer.add(bnd, forKey: "bounds")
        layer.add(op, forKey: "opacity")
        CATransaction.commit()
    }
}
