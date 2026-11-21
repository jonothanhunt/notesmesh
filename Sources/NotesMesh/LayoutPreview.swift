import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `Notes Mesh --layout graph.json --png out.png [--folders] [--no-islands] [--layers topic,similar,link]
///  [--k 2] [--set groupPull=0.1,groupGap=1.5]` — runs the real layout headlessly and draws it,
/// coloured by island, so forces can be tuned without the app.
enum LayoutPreview {
    static func run(_ args: [String]) {
        func value(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let path = value("--layout"), let data = FileManager.default.contents(atPath: path),
              let payload = try? JSONDecoder().decode(GraphPayload.self, from: data) else { print("need --layout graph.json"); return }
        let layers = Set((value("--layers") ?? "link,topic,similar").split(separator: ",").map(String.init))
        let k = Int(value("--k") ?? "2") ?? 2
        for pair in (value("--set") ?? "").split(separator: ",") {
            let kv = pair.split(separator: "="); guard kv.count == 2, let v = Double(kv[1]) else { continue }
            switch kv[0] {
            case "groupPull": LayoutSetup.tuning.groupPull = v
            case "groupGap": LayoutSetup.tuning.groupGap = v
            case "betweenStrength": LayoutSetup.tuning.betweenStrength = v
            case "betweenDistance": LayoutSetup.tuning.betweenDistance = v
            case "anchorPull": LayoutSetup.tuning.anchorPull = v
            default: print("unknown", kv[0])
            }
        }
        let nodes = payload.nodes.filter { $0.kind == "note" || layers.contains($0.kind) }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let edges = payload.links.compactMap { l -> LayoutSetup.Edge? in
            guard layers.contains(l.kind), l.kind != "similar" || l.rank < k, let s = index[l.source], let t = index[l.target] else { return nil }
            return LayoutSetup.Edge(s: s, t: t, kind: l.kind, w: l.w)
        }
        let sim = ForceSim()
        let n = nodes.count
        var rng = SystemRandomNumberGenerator()
        sim.x = (0..<n).map { _ in Double.random(in: -300...300, using: &rng) }
        sim.y = (0..<n).map { _ in Double.random(in: -300...300, using: &rng) }
        sim.vx = Array(repeating: 0, count: n); sim.vy = sim.vx
        sim.fixed = Array(repeating: false, count: n); sim.fx = sim.x; sim.fy = sim.y
        let result = LayoutSetup.configure(sim, isHub: nodes.map { $0.kind != "note" }, folder: nodes.map(\.group), edges: edges,
                                           islands: !args.contains("--no-islands"), byFolder: args.contains("--folders"))
        let start = Date()
        var ticks = 0
        while sim.isActive && ticks < 600 { sim.tick(); ticks += 1 }
        let groups = Set(result.groups.filter { $0 >= 0 }).count
        print(String(format: "%d nodes, %d edges, %d islands, %d ticks in %.2fs", n, edges.count, groups, ticks, Date().timeIntervalSince(start)))

        // Draw.
        let W = 1400, H = 1000
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let xs = sim.x, ys = sim.y
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        let s = min(Double(W - 80) / (x1 - x0), Double(H - 80) / (y1 - y0))
        func p(_ i: Int) -> CGPoint { CGPoint(x: 40 + (xs[i] - x0) * s, y: Double(H) - 40 - (ys[i] - y0) * s) }
        ctx.setLineWidth(0.5); ctx.setStrokeColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.08)
        for e in edges { ctx.move(to: p(e.s)); ctx.addLine(to: p(e.t)) }
        ctx.strokePath()
        for i in 0..<n {
            let g = result.groups[i]
            if g >= 0 {
                let hue = CGFloat((Double(g) * 0.618034).truncatingRemainder(dividingBy: 1))
                let c = hsb(hue, 0.65, 0.8)
                ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            } else { ctx.setFillColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1) }
            let r: CGFloat = nodes[i].kind == "note" ? 2.5 : 4
            ctx.fillEllipse(in: CGRect(x: p(i).x - r, y: p(i).y - r, width: r * 2, height: r * 2))
        }
        let out = value("--png") ?? "layout.png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        print("wrote", out)
    }

    private static func hsb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let i = Int(h * 6), f = h * 6 - CGFloat(i), p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i % 6 { case 0: return (v, t, p); case 1: return (q, v, p); case 2: return (p, v, t)
        case 3: return (p, q, v); case 4: return (t, p, v); default: return (v, p, q) }
    }
}
