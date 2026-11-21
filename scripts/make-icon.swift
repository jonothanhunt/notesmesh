// Draws NoteMesh's app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// A warm squircle with a small mesh of notes (cream), a person (coral) and an entity (blue),
// lit from the top like glass.
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    // macOS icon grid: the shape sits inside ~80% of the canvas.
    let inset = s * 0.1, r = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = CGPath(roundedRect: r, cornerWidth: r.width * 0.225, cornerHeight: r.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor(red: 0.16, green: 0.14, blue: 0.12, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.27, green: 0.22, blue: 0.18, alpha: 1).cgColor,
        NSColor(red: 0.12, green: 0.10, blue: 0.09, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    // Soft colour glows, like the islands.
    for (c, x, y, rad) in [(NSColor(red: 0.98, green: 0.55, blue: 0.36, alpha: 0.35), 0.32, 0.62, 0.42),
                           (NSColor(red: 0.36, green: 0.62, blue: 0.98, alpha: 0.30), 0.72, 0.36, 0.40)] {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        let p = CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r.width * rad, options: [])
    }

    // The mark: an N drawn as a graph. Four big, bright nodes at its corners joined by
    // strong lines; a few small, faint nodes around it hint at the rest of the mesh.
    func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
    let cream = NSColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1)
    let corners = [P(0.31, 0.27), P(0.31, 0.73), P(0.69, 0.27), P(0.69, 0.73)]   // BL, TL, BR, TR
    let faint: [(Double, Double)] = [(0.17, 0.50), (0.50, 0.83), (0.83, 0.50), (0.50, 0.17),
                                     (0.20, 0.80), (0.82, 0.20), (0.50, 0.58), (0.86, 0.80)]
    // Faint threads from the background nodes to the N.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(cream.withAlphaComponent(0.16).cgColor)
    ctx.setLineWidth(max(1, s * 0.006))
    for f in faint {
        let p = P(f.0, f.1)
        let near = corners.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }!
        ctx.move(to: p); ctx.addLine(to: near)
    }
    ctx.strokePath()
    for f in faint {
        let rad = s * 0.018, p = P(f.0, f.1)
        ctx.setFillColor(cream.withAlphaComponent(0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2))
    }
    // The N: up the left side, diagonally down, up the right side.
    ctx.setStrokeColor(cream.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(max(1.5, s * 0.03))
    ctx.setLineJoin(.round)
    ctx.move(to: corners[0]); ctx.addLine(to: corners[1]); ctx.addLine(to: corners[2]); ctx.addLine(to: corners[3])
    ctx.strokePath()
    for (i, c) in corners.enumerated() {
        let rad = s * 0.062
        // A touch of the app's two accents: a person (coral) and an entity (blue).
        let fill: NSColor = i == 1 ? NSColor(red: 0.98, green: 0.55, blue: 0.36, alpha: 1)
                          : i == 2 ? NSColor(red: 0.36, green: 0.62, blue: 0.98, alpha: 1) : cream
        ctx.setShadow(offset: .zero, blur: s * 0.03, color: fill.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    // Glass: a bright rim and a sheen across the top.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.midY + r.height * 0.05), options: [])
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = fm.temporaryDirectory.appendingPathComponent("NoteMesh.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try! fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try! draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print("wrote", out.path)
