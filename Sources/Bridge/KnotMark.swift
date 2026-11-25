import AppKit

/// Bridge's mark, the knot, drawn for the menu bar: three Borromean rings, each passing over one
/// neighbour and under the other (A over B, B over C, C over A), as in the app icon.
/// A template image, so macOS tints it for light and dark menu bars. Where a ring passes under
/// another, a gap is cut out of it rather than drawn in a colour, which a template can't have.
///
/// The rings double as status lights for what they stand for: code (top: work that isn't pushed),
/// server (bottom left: a dev server runs) and agent (bottom right: a Claude session works). A ring
/// in use is drawn solid, the others faint, so the knot is always whole. Template images keep their
/// alpha, which is how SF Symbols' hierarchical rendering works too.
enum KnotMark {
    struct Lit: Hashable {
        var code = false, server = false, agent = false
        /// A dot at the top right while a background Claude session waits for an answer.
        var badge = false
    }

    @MainActor private static var cache: [Lit: NSImage] = [:]

    @MainActor static func image(_ lit: Lit) -> NSImage {
        if let image = cache[lit] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, lit: lit)
            return true
        }
        image.isTemplate = true
        cache[lit] = image
        return image
    }

    /// Faint enough that a lit ring stands out at 18 pt on a 1x screen, strong enough that the
    /// knot still reads as one shape with nothing lit.
    private static let restingAlpha: CGFloat = 0.32

    // The design is laid out on a 100-unit grid (the rings' centres and radius below), scaled
    // to fit 18 pt with a line about as heavy as an SF Symbol's in the menu bar.
    private static let scale: CGFloat = 0.304
    private static let radius: CGFloat = 16 * scale
    private static let line: CGFloat = 1.5
    private static let gap: CGFloat = 1.2

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: 9 + (x - 50) * scale, y: 9 + (y - 47.25) * scale)
    }

    private static func draw(in context: CGContext, lit: Lit) {
        // A is code, B server, C agent.
        let a = point(50, 39), b = point(40.5, 55.5), c = point(59.5, 55.5)
        let alpha = { (on: Bool) in on ? 1 : restingAlpha }
        context.setLineCap(.butt)
        // Each ring drawn later is over the ones before it, which gives A over B and B over C.
        for (center, on) in [(c, lit.agent), (b, lit.server), (a, lit.code)] {
            stroke(context, center: center, from: 0, to: 2 * .pi, alpha: alpha(on))
        }
        // C over A closes the cycle: C is drawn again where it crosses A, clipped to A's band so it
        // doesn't also cut into B, which crosses there too.
        let ringA = CGMutablePath()
        ringA.addArc(center: a, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.saveGState()
        // A little wider than the gap A cut, so the redrawn piece overlaps the rest of C instead of
        // meeting it edge to edge, which left a hairline seam.
        context.addPath(ringA.copy(strokingWithWidth: line + 2 * gap + 1, lineCap: .butt, lineJoin: .round, miterLimit: 1))
        context.clip()
        for crossing in intersections(a, c) {
            let angle = atan2(crossing.y - c.y, crossing.x - c.x)
            stroke(context, center: c, from: angle - 0.6, to: angle + 0.6, alpha: alpha(lit.agent))
        }
        context.restoreGState()
        if lit.badge {
            let dot = CGPoint(x: 15.2, y: 3)
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: dot.x - 3.6, y: dot.y - 3.6, width: 7.2, height: 7.2))
            context.setBlendMode(.normal)
            context.fillEllipse(in: CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5))
        }
    }

    /// Clears a band a little wider than the line, then draws the line in it, so whatever this
    /// arc passes over gets a gap on both sides.
    private static func stroke(_ context: CGContext, center: CGPoint, from: CGFloat, to: CGFloat, alpha: CGFloat) {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
        context.setBlendMode(.clear)
        context.setLineWidth(line + 2 * gap)
        context.addPath(path)
        context.strokePath()
        context.setBlendMode(.normal)
        context.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(line)
        context.addPath(path)
        context.strokePath()
    }

    private static func intersections(_ p: CGPoint, _ q: CGPoint) -> [CGPoint] {
        let dx = q.x - p.x, dy = q.y - p.y, d = (dx * dx + dy * dy).squareRoot()
        let h = (radius * radius - d * d / 4).squareRoot()
        let mid = CGPoint(x: p.x + dx / 2, y: p.y + dy / 2)
        return [CGPoint(x: mid.x - dy / d * h, y: mid.y + dx / d * h), CGPoint(x: mid.x + dy / d * h, y: mid.y - dx / d * h)]
    }
}
