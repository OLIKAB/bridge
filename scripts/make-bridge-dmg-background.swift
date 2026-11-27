// Renders Resources/BridgeDMGBackground.tiff (1x + 2x) for Bridge's installer window, in the website's look
// (website/index.html): a near-black night with the aurora in the knot's three colours (the page's own shader,
// worked out pixel by pixel here, so it is the same sky), grain, the knot and "Bridge" at the top left as in
// the page's header, one tight SF Pro Display line, and the icons' names on white pills like the Download button.
// Run: swift scripts/make-bridge-dmg-background.swift [--preview]
// Icon positions must match scripts/bridge-dmg-settings.py (Bridge 170,200 · Applications 470,200 · window 640×460).
// Finder may add a path bar and status bar at the bottom whatever the settings say, so everything that
// matters sits in the top 320 points.
import AppKit
import SwiftUI

let window = CGSize(width: 640, height: 460)
// Larger than the window, so a path bar, status bar or resized window never shows an edge.
let canvas = CGSize(width: 1000, height: 700)

// The page's colours (`--ink`, the knot's lights).
let ink = Color(red: 0.957, green: 0.957, blue: 0.969)
let mint = Color(red: 0.30, green: 0.94, blue: 0.71)
let violet = Color(red: 0.61, green: 0.55, blue: 1.0)
let coral = Color(red: 1.0, green: 0.63, blue: 0.44)

let app = CGPoint(x: 170, y: 200)
let applications = CGPoint(x: 470, y: 200)
/// How far below an icon's centre Finder puts the middle of its name, at icon size 100 and text size 12.
let labelOffset: CGFloat = 65

// MARK: The sky

/// The website's aurora shader (`sky()` in website/index.html), in Swift, at one moment `t`. `x`, `y` are in
/// pixels from the window's bottom left, as gl_FragCoord is; the window's size is what the page's `r` is, so the
/// sky sits in the 640×460 window as it sits on the page, and carries on smoothly past it into the spare canvas.
enum Sky {
    static func hash(_ x: Double, _ y: Double) -> Double {
        let v = sin(x * 127.1 + y * 311.7) * 43758.5453
        return v - floor(v)
    }

    static func noise(_ x: Double, _ y: Double) -> Double {
        let ix = floor(x), iy = floor(y)
        var fx = x - ix, fy = y - iy
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }

    static func fbm(_ x: Double, _ y: Double) -> Double {
        var v = 0.0, a = 0.5, px = x, py = y
        for _ in 0..<5 {
            v += a * noise(px, py)
            px *= 2.03; py *= 2.03; a *= 0.5
        }
        return v
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static let lights: [(Double, Double, Double)] = [(0.30, 0.94, 0.71), (0.61, 0.55, 1.0), (1.0, 0.63, 0.44)]

    static func color(x: Double, y: Double, width: Double, height: Double, t: Double) -> (Double, Double, Double) {
        let u = x / width, v = y / height, aspect = width / height, qx = u * aspect
        var r = 0.012 + (0.03 - 0.012) * v, g = 0.012 + (0.025 - 0.012) * v, b = 0.02 + (0.055 - 0.02) * v
        for i in 0..<3 {
            let fi = Double(i)
            let px = qx * 0.7 + fi * 1.91
            let base = 0.46 + 0.1 * fi + 0.08 * sin(px * 1.3 + t * 0.05 + fi * 2.3) + 0.14 * (fbm(px * 0.7, t * 0.02 + fi) - 0.5)
            let d = v - base
            let edge = smoothstep(-0.34, 0.04, d) * exp(-max(d, 0) * (2.6 + fi * 0.5))
            let streak = pow(fbm(px * 6, t * 0.08 + fi * 3), 2.3) * 2.4
            let a = edge * streak * (0.5 + 0.5 * fbm(px * 1.8, t * 0.04))
            let c = lights[i]
            r += c.0 * a * 0.42; g += c.1 * a * 0.42; b += c.2 * a * 0.42
        }
        let cx = (u - 0.5) * aspect, cy = v - 0.45
        let center = 0.07 * exp(-sqrt(cx * cx + cy * cy) * 2.6)
        r += 0.61 * center; g += 0.55 * center; b += 1.0 * center
        let vx = u - 0.5, vy = (v - 0.5) * 1.15
        let vignette = 0.55 + 0.45 * smoothstep(1.2, 0.25, sqrt(vx * vx + vy * vy))
        r *= vignette; g *= vignette; b *= vignette
        let floorGlow = 0.035 * smoothstep(0.35, 0, v)
        r += 0.61 * floorGlow; g += 0.55 * floorGlow; b += 1.0 * floorGlow
        return (r, g, b)
    }

    /// The canvas's sky at `scale` pixels per point, with the page's grain in it so the gradients never band.
    static func image(scale: Double, t: Double) -> CGImage {
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let ww = window.width * scale, wh = window.height * scale
        for row in 0..<h {
            // From the window's bottom, as gl_FragCoord counts; rows below the window go negative.
            let y = wh - Double(row) - 0.5
            for column in 0..<w {
                let x = Double(column) + 0.5
                var (r, g, b) = color(x: x, y: y, width: ww, height: wh, t: t)
                let grain = (hash(x, y) - 0.5) * 0.045
                r += grain; g += grain; b += grain
                let i = (row * w + column) * 4
                pixels[i] = UInt8(min(max(r, 0), 1) * 255)
                pixels[i + 1] = UInt8(min(max(g, 0), 1) * 255)
                pixels[i + 2] = UInt8(min(max(b, 0), 1) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

// MARK: The knot

/// The knot as the page's header draws it: three rings on the 100-unit grid, each cut where the ring that
/// passes over it lies (A over B, B over C, C over A).
struct Knot: View {
    var body: some View {
        Canvas { context, size in
            // The page's viewBox, 19 16.25 62 62.
            let s = size.width / 62
            func ring(_ x: Double, _ y: Double) -> Path {
                Path(ellipseIn: CGRect(x: (x - 16 - 19) * s, y: (y - 16 - 16.25) * s, width: 32 * s, height: 32 * s))
            }
            let a = ring(50, 39), b = ring(40.5, 55.5), c = ring(59.5, 55.5)
            for (under, over) in [(a, c), (b, a), (c, b)] {
                var layer = context
                layer.clip(to: over.strokedPath(StrokeStyle(lineWidth: 13.1 * s)), options: .inverse)
                layer.stroke(under, with: .color(ink), lineWidth: 7.5 * s)
            }
        }
    }
}

// MARK: The window

struct Background: View {
    let sky: CGImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: sky, scale: 2)
                .resizable()
                .frame(width: canvas.width, height: canvas.height)

            // The page's header: the knot and the name, at its corner.
            HStack(spacing: 8) {
                Knot().frame(width: 17, height: 17)
                Text("Bridge")
                    .font(.system(size: 13.5, weight: .medium))
                    .tracking(-0.14)
                    .foregroundStyle(ink.opacity(0.9))
            }
            .fixedSize()
            .placed(x: 22, y: 20)

            // The page's line: SF Pro Display, semibold, tight.
            Text("Drag Bridge into Applications.")
                .font(.system(size: 25, weight: .semibold))
                .tracking(-0.85)
                .foregroundStyle(ink)
                .fixedSize()
                .frame(width: window.width)
                .placed(x: 0, y: 62)

            Canvas { context, _ in
                // A hairline from Bridge to Applications in the knot's three colours, mint to coral.
                let y = app.y - 4
                let start = CGPoint(x: app.x + 72, y: y), end = CGPoint(x: applications.x - 74, y: y)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [mint.opacity(0.9), violet, coral.opacity(0.95)]), startPoint: start, endPoint: end)
                var line = Path()
                line.move(to: start)
                line.addLine(to: CGPoint(x: end.x - 1, y: y))
                context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                var head = Path()
                head.move(to: CGPoint(x: end.x - 7, y: y - 6))
                head.addLine(to: end)
                head.addLine(to: CGPoint(x: end.x - 7, y: y + 6))
                context.stroke(head, with: .color(coral.opacity(0.95)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .frame(width: canvas.width, height: canvas.height)

            // Finder draws icon names in black, so each sits on a pill like the page's Download button:
            // the ink white, a darker edge at its foot, and the knot's three colours glowing behind it.
            ForEach([app, applications], id: \.x) { icon in
                Capsule()
                    .fill(ink)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: mint.opacity(0.28), radius: 9, x: -8, y: 2)
                    .shadow(color: violet.opacity(0.28), radius: 9, x: 0, y: 3)
                    .shadow(color: coral.opacity(0.28), radius: 9, x: 8, y: 2)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                    .frame(width: 104, height: 22)
                    .position(x: icon.x, y: icon.y + labelOffset)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)

            // The page's quieter line under the button.
            Text("Free and open source · bridge.olikab.com")
                .font(.system(size: 11.5))
                .foregroundStyle(ink.opacity(0.4))
                .fixedSize()
                .frame(width: window.width)
                .placed(x: 0, y: 330)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
    }
}

extension View {
    /// At `x`, `y` from the canvas's top left, in a layer exactly the canvas's size, so nothing it holds can
    /// make the stack larger than the canvas and move everything else.
    func placed(x: CGFloat, y: CGFloat) -> some View {
        padding(.leading, x).padding(.top, y)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}

@MainActor func render(_ view: Background, scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
    rep.size = NSSize(width: canvas.width, height: canvas.height) // 72 dpi at 1x, 144 dpi at 2x
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeDMG-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let one = work.appendingPathComponent("bg.png")
let two = work.appendingPathComponent("bg@2x.png")
// One moment of the page's sky, picked for a calm spread of all three colours behind the icons.
let sky = Sky.image(scale: 2, t: 44)
MainActor.assumeIsolated {
    render(Background(sky: sky), scale: 1, to: one)
    render(Background(sky: sky), scale: 2, to: two)
}

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", one.path, two.path, "-out", root.appendingPathComponent("Resources/BridgeDMGBackground.tiff").path]
tiffutil.standardOutput = FileHandle.nullDevice
try! tiffutil.run()
tiffutil.waitUntilExit()
if CommandLine.arguments.contains("--preview") {
    let preview = root.appendingPathComponent("build/bridge-dmg-background-preview.png")
    try? FileManager.default.removeItem(at: preview)
    try? FileManager.default.copyItem(at: two, to: preview)
}
try? FileManager.default.removeItem(at: work)
print("Wrote Resources/BridgeDMGBackground.tiff")
