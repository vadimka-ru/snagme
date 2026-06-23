import AppKit

// Пилл-капсула с иконкой + текстом. Тёмная непрозрачная подложка поверх стеклянного слоя —
// единый вид на любом фоне (glass как contentView даёт vibrancy и просвечивает фон, поэтому
// заливка/контент кладутся прямо на self, НАД стеклом).
// Прозрачен для кликов (hitTest → nil) — хит-тест/ховер ведёт NotchContentView по rect'ам.
@MainActor
final class GlassPill: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let base = NSView()      // постоянная тёмная подложка
    private let overlay = NSView()   // ховер-подсветка
    private var glass: NSView!       // стеклянный слой (сзади, для frosted-кромки)
    private var isLiquid = false
    private var radius: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        if let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            glass = cls.init(frame: .zero)
            isLiquid = true
        } else {
            let v = NSVisualEffectView()
            v.material = .fullScreenUI
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            glass = v
        }

        base.wantsLayer = true
        base.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.6).cgColor
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor

        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false

        // Порядок снизу вверх: стекло → тёмная заливка → ховер → иконка/текст.
        addSubview(glass)
        addSubview(base)
        addSubview(overlay)
        addSubview(icon)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var hovered = false
    func setHovered(_ on: Bool) {
        guard on != hovered else { return }
        hovered = on
        overlay.layer?.backgroundColor = (on ? NSColor(white: 1, alpha: 0.10) : .clear).cgColor
    }

    func configure(image: NSImage?, text: String, radius: CGFloat) {
        icon.image = image
        label.stringValue = text
        label.isHidden = text.isEmpty
        self.radius = radius
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
        for v in [base, overlay] {
            v.frame = bounds
            v.layer?.cornerRadius = radius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
        }
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
