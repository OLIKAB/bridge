// Renders Resources/BridgeDMGBackground.tiff (1x + 2x) for Bridge's installer window, in the app's own look:
// a dark ground lit by the three coloured lights of the icon's knot (mint, violet, coral), SF text,
// and a panel-style row for the one hint.
// Run: swift scripts/make-bridge-dmg-background.swift [--preview]
// Icon positions must match scripts/bridge-dmg-settings.py (Bridge 170,200 · Applications 470,200 · window 640×460).
// Finder may add a path bar and status bar at the bottom whatever the settings say, so everything that
// matters sits in the top 320 points.
import AppKit
import SwiftUI

let window = CGSize(width: 640, height: 460)
// Larger than the window, so a path bar, status bar or resized window never shows a white edge.
let canvas = CGSize(width: 1000, height: 700)

let top = Color(red: 0.07, green: 0.07, blue: 0.09)
let bottom = Color(red: 0.035, green: 0.035, blue: 0.05)
// The icon's three lights, as soft pools around the corners, so the window looks lit by the same scene.
let mint = Color(red: 0.30, green: 0.94, blue: 0.71)
let violet = Color(red: 0.61, green: 0.55, blue: 1.0)
let coral = Color(red: 1.0, green: 0.63, blue: 0.44)
let primary = Color.white.opacity(0.92)
let secondary = Color.white.opacity(0.5)
let hintTint = violet

let app = CGPoint(x: 170, y: 200)
let applications = CGPoint(x: 470, y: 200)
/// How far below an icon's centre Finder puts the middle of its name, at icon size 100 and text size 12.
let labelOffset: CGFloat = 65

struct Background: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                .frame(width: canvas.width, height: canvas.height)
            ZStack(alignment: .topLeading) {
                glow(mint, at: CGPoint(x: 320, y: -40), radius: 300, opacity: 0.30)
                glow(violet, at: CGPoint(x: 10, y: 360), radius: 300, opacity: 0.34)
                glow(coral, at: CGPoint(x: 610, y: 360), radius: 280, opacity: 0.28)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)

            VStack(spacing: 5) {
                Text("Bridge")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(primary)
                Text("Drag to Applications to install")
                    .font(.system(size: 12.5))
                    .foregroundStyle(secondary)
            }
            .frame(width: window.width)
            .padding(.top, 38)

            Canvas { context, _ in
                // A plain solid white arrow between the icons.
                let start = CGPoint(x: app.x + 70, y: app.y - 4)
                let end = CGPoint(x: applications.x - 72, y: applications.y - 4)
                var arrow = Path()
                arrow.move(to: start)
                arrow.addLine(to: end)
                arrow.move(to: CGPoint(x: end.x - 8, y: end.y - 7))
                arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y + 7))
                context.stroke(arrow, with: .color(primary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: canvas.width, height: canvas.height)

            // Finder draws icon names in black even on a dark background, so each name gets a light capsule
            // to sit on, shaped like the panel's skill chips.
            ForEach([app, applications], id: \.x) { icon in
                Capsule()
                    .fill(Color(white: 0.82))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                    .frame(width: 112, height: 22)
                    .position(x: icon.x, y: icon.y + labelOffset)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)

            // The one hint, in a row like the panel's, with a tinted fill.
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
                Text("If macOS stops it on first launch: System Settings › Privacy & Security › Open Anyway")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hintTint.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            )
            .frame(width: window.width)
            .padding(.top, 298)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}

func glow(_ color: Color, at center: CGPoint, radius: CGFloat, opacity: Double) -> some View {
    RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center, startRadius: 0, endRadius: radius)
        .frame(width: radius * 2, height: radius * 2)
        .position(center)
}

@MainActor func render(scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: Background())
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
MainActor.assumeIsolated {
    render(scale: 1, to: one)
    render(scale: 2, to: two)
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
