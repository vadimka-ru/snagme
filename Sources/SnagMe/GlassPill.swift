import AppKit

// Пилл из macOS 26 Liquid Glass (NSGlassEffectView через runtime) с иконкой + текстом.
// Прозрачен для кликов (hitTest → nil) — хит-тест/ховер ведёт NotchContentView по rect'ам.
@MainActor
final class GlassPill: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let content = NSView()
    private var glass: NSView!
    private var isLiquid = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        content.addSubview(icon)
        content.addSubview(label)

        if let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let g = cls.init(frame: .zero)
            g.setValue(content, forKey: "contentView")
            glass = g
            isLiquid = true
        } else {
            let v = NSVisualEffectView()
            v.material = .fullScreenUI
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            v.addSubview(content)
            glass = v
        }
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(image: NSImage?, text: String, radius: CGFloat) {
        icon.image = image
        label.stringValue = text
        label.isHidden = text.isEmpty
        if isLiquid {
            glass.setValue(radius, forKey: "cornerRadius")
        } else {
            glass.layer?.cornerRadius = radius
            glass.layer?.cornerCurve = .continuous
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = bounds
        let h = bounds.height
        if label.isHidden {
            // только иконка — по центру
            icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
        } else {
            icon.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
            label.sizeToFit()
            label.frame = NSRect(x: 8 + 16 + 6, y: (h - label.frame.height) / 2,
                                 width: label.frame.width, height: label.frame.height)
        }
    }
}
