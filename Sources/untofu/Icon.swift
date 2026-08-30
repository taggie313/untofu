import AppKit

/// untofu's mark, drawn in code.
///
/// Drawn rather than shipped as a resource, and that is a packaging decision
/// rather than a stylistic one: the Homebrew formula installs a single
/// executable and nothing else, which is what makes one universal bottle valid
/// for all ten macOS tags with `any_skip_relocation`. Adding a resource bundle
/// beside the binary would quietly invalidate that.
///
/// The geometry is lifted straight from `site/untofu-icon.svg` on a 1024 grid,
/// so this is the same mark the website and the installer use rather than an
/// approximation of it: a "tofu" box — the empty rectangle a renderer shows when
/// it has no glyph — with a real letterform standing in it and breaking past its
/// edges. The placeholder is what you had; the letter is what arrived.
enum Icon {

    /// Cached per size: NSAlert asks for this every time one is shown, and the
    /// drawing is not free.
    private static var cache: [CGFloat: NSImage] = [:]
    private static let lock = NSLock()

    static func image(size: CGFloat = 128) -> NSImage {
        lock.lock(); defer { lock.unlock() }
        if let existing = cache[size] { return existing }
        let drawn = draw(size: size)
        cache[size] = drawn
        return drawn
    }

    private static func draw(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let s = size / 1024                       // the artwork's design grid
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // Full bleed, no rounded rect of its own. macOS masks icons into the
            // system shape; artwork carrying its own corners and a transparent
            // margin comes out as a small tile floating on a white square.
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            let gradient = NSGradient(colorsAndLocations:
                (NSColor(srgbRed: 0x6B/255, green: 0x63/255, blue: 0xE8/255, alpha: 1), 0.0),
                (NSColor(srgbRed: 0x40/255, green: 0x38/255, blue: 0xB8/255, alpha: 1), 0.55),
                (NSColor(srgbRed: 0x24/255, green: 0x1C/255, blue: 0x6E/255, alpha: 1), 1.0))
            gradient?.draw(in: bounds, angle: -45)

            let ink = NSColor(srgbRed: 0xFB/255, green: 0xF6/255, blue: 0xEC/255, alpha: 1)

            // The SVG's y axis runs downwards and Core Graphics' upwards, so
            // every y is mirrored through the 1024 grid on the way in.
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * s, y: (1024 - y) * s)
            }

            // The placeholder box: deliberately secondary, thin and translucent,
            // so at small sizes the letter dominates rather than the whole thing
            // dissolving into a grid of lines.
            let box = NSBezierPath(roundedRect:
                CGRect(x: 286 * s, y: 286 * s, width: 452 * s, height: 452 * s),
                xRadius: 44 * s, yRadius: 44 * s)
            box.lineWidth = 34 * s
            ink.withAlphaComponent(0.42).setStroke()
            box.stroke()

            // The glyph that arrived, overrunning the box top and bottom.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 18 * s,
                              color: NSColor(srgbRed: 0x14/255, green: 0x0F/255,
                                             blue: 0x45/255, alpha: 0.45).cgColor)
            let letter = NSBezierPath()
            letter.move(to: p(348, 764)); letter.line(to: p(512, 302)); letter.line(to: p(676, 764))
            letter.move(to: p(406, 640)); letter.line(to: p(618, 640))
            letter.lineWidth = 88 * s
            letter.lineCapStyle = .butt
            letter.lineJoinStyle = .miter
            ink.setStroke()
            letter.stroke()
            context.restoreGState()

            return true
        }
        // The mark is a fixed image, not a template: it must keep its own colour
        // rather than being tinted to the label colour in either appearance.
        image.isTemplate = false
        return image
    }
}
