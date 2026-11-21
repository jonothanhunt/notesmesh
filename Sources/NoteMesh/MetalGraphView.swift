import AppKit
import MetalKit
import simd

/// The knowledge graph, drawn natively with Metal.
///
/// Edges, nodes and labels are instanced quads: one draw call each. Panning and zooming only
/// change a few uniforms; labels come from a Core Text glyph atlas made once. The view only
/// renders when something changed (a gesture, the layout settling, a camera move) and sleeps
/// otherwise. Look and feel follow Mesh: ink on paper, 1pt lines, dotted topic edges,
/// constant on-screen dot sizes, selected = inverted, hover = faint, instant state changes.
final class MetalGraphView: MTKView, MTKViewDelegate {
    // MARK: Callbacks to SwiftUI
    var onSelect: ((String?) -> Void)?
    var onPress: (() -> Void)?
    var onOpen: ((String) -> Void)?
    var onHover: ((GraphHover?) -> Void)?
    var onTypes: (([String: Int], String?) -> Void)?
    var onIslands: (([IslandSummary]) -> Void)?
    /// Island names float as glass pills when zoomed far out; clicking one reports its island.
    var onPillClick: ((Int) -> Void)?
    var onPills: (([IslandPill]) -> Void)?
    private var pillMonitor: Any?
    private var pillDrag: (start: NSEvent, dragging: Bool)?
    private var pillViews: [Int: IslandPillView] = [:]
    /// Transparent overlay above the graph that holds the pills (a Metal layer won't composite
    /// subviews). It lets every click through except on a pill.
    let pillLayer = PassthroughView()
    private var islandTitle: [Int: String] = [:]
    private var lastPills: [IslandPill] = []
    /// Pills fade in below this zoom and are fully shown at `pillZoomFull`.
    static let pillZoomStart = 0.5, pillZoomFull = 0.36
    private var looseIslands: Set<Int> = []
    private var islandMatches: Set<String>?

    // MARK: Scene
    final class Node {
        let id: String
        var kind = "note", label = "", group = "", snippet = "", source = "", category = "note"
        var count = 0
        var x = Double.nan, y = Double.nan
        var pinned = false
        init(id: String) { self.id = id }
        var type: String { kind == "note" ? category : kind }
        var isHub: Bool { kind != "note" }
    }
    struct Link { let s: Int, t: Int, kind: String, w: Double, rank: Int }

    private var payload: GraphPayload?
    private var nodeByID: [String: Node] = [:]
    private var nodes: [Node] = []            // visible
    private var index: [String: Int] = [:]    // id → visible index
    private var links: [Link] = []
    private var neighbours: [[Int]] = []
    private var degree: [Int] = []
    // Per visible node, computed once in apply() so frames do no string or dictionary work.
    private var radius: [Float] = []
    private var labelText: [String] = []
    private var labelLength: [Int] = []
    private var glyph: [GlyphAtlas.Entry?] = []
    private var glyphGeneration = -1
    private var occupancy: [UInt8] = []       // label-placement bitmap, reused every frame
    private var shownLastFrame: [Bool] = []   // labels keep their place while you pan (no flicker)
    private var labelAlpha: [Float] = []      // labels fade in and out instead of popping
    private var lastLabelTime = CACurrentMediaTime()
    private var labelsFading = false
    private var layers: [String: Bool] = ["notelink": true, "link": true, "tag": true, "topic": true, "similar": true]
    private var islands = true
    private var byFolder = false
    private var folderNames: [String] = []
    private var folderOf: [Int] = []          // per visible node, -1 for hubs
    private var islandOf: [Int] = []          // per visible node, -1 for none
    private var similarK = 2

    private var hover: Int?
    private var selected: String?
    private var queryMatches: Set<String>?
    private var typeFilter: String?
    private var focus: [Bool]?                // per visible node; nil = nothing focused
    private var hasAnchor = false

    // MARK: Camera
    private var camX = 0.0, camY = 0.0, zoom = 1.0
    private let minZoom = 0.12, maxZoom = 8.0
    private var insets = NSEdgeInsets()
    private struct Tween { var from: (Double, Double, Double), to: (Double, Double, Double), start: CFTimeInterval, duration: Double }
    private var tween: Tween?
    private var firstFit = true

    // MARK: Physics
    private let sim = ForceSim()

    // MARK: Metal
    private var queue: MTLCommandQueue!
    private var edgePipeline: MTLRenderPipelineState!
    private var nodePipeline: MTLRenderPipelineState!
    private var labelPipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!
    private var atlas: GlyphAtlas!
    private let inFlight = DispatchSemaphore(value: 3)
    private var ring = 0
    private var buffers: [[MTLBuffer?]] = Array(repeating: [nil, nil, nil], count: 3)
    private var theme = MeshTheme.make(dark: false)

    struct EdgeInstance { var line: SIMD4<Float>; var color: SIMD4<Float>; var style: SIMD2<Float>; var pad = SIMD2<Float>() }
    struct NodeInstance { var pos: SIMD2<Float>; var sizeShape: SIMD2<Float>; var color: SIMD4<Float> }
    struct LabelInstance { var pos: SIMD2<Float>; var pad = SIMD2<Float>(); var rect: SIMD4<Float>; var uv: SIMD4<Float>; var color: SIMD4<Float> }
    struct Uniforms { var center: SIMD2<Float>; var view: SIMD2<Float>; var zoom: Float; var dpr: Float; var pad = SIMD2<Float>(); var ink: SIMD4<Float> }

    // MARK: - Setup

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        super.init(frame: .zero, device: device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 120
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        layer?.isOpaque = true
        // Present in the same Core Animation transaction as the island pills (AppKit glass
        // views on top), so pills and graph move together frame for frame.
        presentsWithTransaction = true
        queue = device.makeCommandQueue()
        atlas = GlyphAtlas(device: device, scale: NSScreen.main?.backingScaleFactor ?? 2)
        buildPipelines()
        readTheme()
        pillMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.routePillEvent(e) ?? e
        }
    }

    /// The pills are SwiftUI views over the graph; anything but a clean click on one belongs to
    /// the graph underneath (scroll, pinch, or a drag that starts on a pill).
    private func overPill(_ e: NSEvent) -> Bool {
        guard e.window === window, !lastPills.isEmpty else { return false }
        let p = convert(e.locationInWindow, from: nil)
        let y = isFlipped ? p.y : bounds.height - p.y
        return lastPills.contains { pill in
            let w = Double(pill.title.count) * 7.6 + 50, h = 32.0
            return abs(Double(p.x) - Double(pill.point.x)) < w / 2 && abs(Double(y) - Double(pill.point.y)) < h / 2
        }
    }

    private func routePillEvent(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .scrollWheel where overPill(e): scrollWheel(with: e); return nil
        case .magnify where overPill(e): magnify(with: e); return nil
        case .smartMagnify where overPill(e): smartMagnify(with: e); return nil
        case .leftMouseDown:
            pillDrag = overPill(e) ? (e, false) : nil
            return e
        case .leftMouseDragged:
            guard var d = pillDrag else { return e }
            if !d.dragging {
                let a = d.start.locationInWindow, b = e.locationInWindow
                guard hypot(b.x - a.x, b.y - a.y) > 3 else { return nil }
                d.dragging = true; pillDrag = d
                mouseDown(with: d.start)
            }
            mouseDragged(with: e)
            return nil
        case .leftMouseUp:
            defer { pillDrag = nil }
            if let d = pillDrag, d.dragging { mouseUp(with: e); return nil }
            return e
        default: return e
        }
    }
    required init(coder: NSCoder) { fatalError() }

    private func buildPipelines() {
        let library = try! device!.makeLibrary(source: Self.shaders, options: nil)
        func pipeline(_ vs: String, _ fs: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            let c = d.colorAttachments[0]!
            c.pixelFormat = colorPixelFormat
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! device!.makeRenderPipelineState(descriptor: d)
        }
        edgePipeline = pipeline("edgeVS", "edgeFS")
        nodePipeline = pipeline("nodeVS", "nodeFS")
        labelPipeline = pipeline("labelVS", "labelFS")
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        sampler = device!.makeSamplerState(descriptor: s)
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); readTheme() }
    private func readTheme() {
        theme = MeshTheme.make(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        clearColor = MTLClearColor(red: Double(theme.bg.x), green: Double(theme.bg.y), blue: Double(theme.bg.z), alpha: 1)
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        if s > atlas.scale { atlas.reset(height: atlas.height, scale: s) }
        redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: - Rendering loop

    private var viewW: Double { Double(bounds.width) }
    private var viewH: Double { Double(bounds.height) }

    /// Ask for one frame (coalesced to the display refresh).
    func redraw() { needsDisplay = true }

    /// Run continuously while the layout settles or the camera eases; sleep otherwise.
    private func setAnimating(_ on: Bool) {
        if on { enableSetNeedsDisplay = false; isPaused = false }
        else { isPaused = true; enableSetNeedsDisplay = true }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw() }

    // Benchmark: `open NoteMesh.app --args --bench` sweeps the zoom for 3 s and reports
    // frames drawn and the CPU time spent building each frame.
    private var bench: (start: CFTimeInterval, z0: Double, frames: Int, cpu: Double, worst: Double, done: (String) -> Void)?
    func runBenchmark(_ done: @escaping (String) -> Void) {
        bench = (CACurrentMediaTime(), zoom, 0, 0, 0, done)
        setAnimating(true)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var animating = false
        if var b = bench {
            let t = now - b.start
            zoom = b.z0 * exp(sin(t / 3 * 2 * .pi) * 1.6)
            b.frames += 1
            bench = b
            if t >= 3 {
                let fps = Double(b.frames) / t
                b.done(String(format: "bench: %.0f fps over %.1f s (display max %d) · frame build avg %.2f ms, worst %.2f ms · %d nodes, %d edges",
                              fps, t, NSScreen.main?.maximumFramesPerSecond ?? 0, b.cpu / Double(b.frames) * 1000, b.worst * 1000,
                              nodes.count, links.count))
                zoom = b.z0
                bench = nil
            } else { animating = true }
        }

        if let t = tween {
            let p = min(1, (now - t.start) / t.duration), k = 1 - pow(1 - p, 3)
            camX = t.from.0 + (t.to.0 - t.from.0) * k
            camY = t.from.1 + (t.to.1 - t.from.1) * k
            zoom = exp(log(t.from.2) + (log(t.to.2) - log(t.from.2)) * k)
            if p >= 1 { tween = nil } else { animating = true }
        }
        if sim.isActive && !nodes.isEmpty {
            sim.tick()
            for (i, n) in nodes.enumerated() { n.x = sim.x[i]; n.y = sim.y[i] }
            animating = true
            if !sim.isActive && firstFit { firstFit = false; fit(duration: 0.5) ; animating = true }
            if !sim.isActive { reportIslands() }   // the layout has settled: refresh the mini maps
            if hover != nil { reportHover() }
        }
        if labelsFading { animating = true }
        setAnimating(animating)

        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        inFlight.wait()
        ring = (ring + 1) % 3
        let buildStart = CACurrentMediaTime()
        let edges = buildEdges(), nodeData = buildNodes(), labels = buildLabels()
        if var b = bench {
            let dt = CACurrentMediaTime() - buildStart
            b.cpu += dt; b.worst = max(b.worst, dt); bench = b
        }

        let cmd = queue.makeCommandBuffer()!
        cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        var u = Uniforms(center: SIMD2(Float(camX), Float(camY)), view: SIMD2(Float(viewW), Float(viewH)),
                         zoom: Float(zoom), dpr: Float(window?.backingScaleFactor ?? 2), ink: theme.fg)
        func draw<T>(_ pipeline: MTLRenderPipelineState, _ data: [T], slot: Int) {
            guard !data.isEmpty, let buf = buffer(slot, bytes: data) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: data.count)
        }
        draw(edgePipeline, edges, slot: 0)
        draw(nodePipeline, nodeData, slot: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        draw(labelPipeline, labels, slot: 2)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilScheduled()
        drawable.present()
    }

    /// Triple-buffered instance storage, grown as needed.
    private func buffer<T>(_ slot: Int, bytes data: [T]) -> MTLBuffer? {
        let length = MemoryLayout<T>.stride * data.count
        if (buffers[ring][slot]?.length ?? 0) < length {
            buffers[ring][slot] = device!.makeBuffer(length: max(length, 4096) * 2, options: .storageModeShared)
        }
        guard let buf = buffers[ring][slot] else { return nil }
        data.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        return buf
    }

    // MARK: - Frame building

    private func screen(_ n: Node) -> (Double, Double) {
        ((n.x - camX) * zoom + viewW / 2, (n.y - camY) * zoom + viewH / 2)
    }
    private func pxRadius(_ i: Int) -> Float { radius[i] }
    private func computeRadius(_ i: Int) -> Float {
        let n = nodes[i]
        if n.isHub { return Float(min(4.5, 2.2 + Double(n.count) * 0.12)) }
        let base: Double = n.category == "person" || n.category == "entity" ? 3.6 : 2.4
        return Float(base + min(1.6, Double(degree[i]).squareRoot() * 0.22))
    }
    private func dimmed(_ i: Int) -> Bool { focus.map { !$0[i] } ?? false }

    private func mixed(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        var m = a + (b - a) * t; m.w = 1; return m
    }

    private func buildEdges() -> [EdgeInstance] {
        var out: [EdgeInstance] = []
        out.reserveCapacity(links.count)
        let anchor = selected.flatMap { index[$0] } ?? hover
        let base: Float = focus == nil ? 1 : 0.05
        for l in links {
            let a = nodes[l.s], b = nodes[l.t]
            let style: Float = l.kind == "topic" || l.kind == "tag" ? 1 : l.kind == "similar" ? 2 : 0
            var hi = false
            if let f = focus, f[l.s], f[l.t] { hi = anchor == nil || l.s == anchor || l.t == anchor }
            // Edges between islands stay quiet so the islands read clearly.
            let between = islands && l.s < islandOf.count && islandOf[l.s] != islandOf[l.t]
            let alpha: Float = hi ? [0.75, 0.6, 0.5][Int(style)] : [0.32, 0.24, 0.16][Int(style)] * base * (between ? 0.35 : 1)
            // Lines inside an island take its colour; lines between islands stay ink.
            let g = l.s < islandOf.count ? islandOf[l.s] : -1
            let tint = !between && g >= 0 && !looseIslands.contains(g) ? mixed(theme.fg, theme.island(g), 0.7) : theme.fg
            out.append(EdgeInstance(line: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)), color: tint, style: SIMD2(style, alpha)))
        }
        return out
    }

    private func buildNodes() -> [NodeInstance] {
        var out: [NodeInstance] = []
        out.reserveCapacity(nodes.count + 1)
        for (i, n) in nodes.enumerated() {
            var c = theme.color(forType: n.type)
            // Notes wear their island's colour; topics a softer tint of it. People and
            // companies keep their own colours so they stand out wherever they are.
            if n.category != "person" && n.category != "entity", i < islandOf.count {
                let g = islandOf[i]
                if g >= 0 && !looseIslands.contains(g) {
                    c = n.isHub ? mixed(theme.accent, theme.island(g), 0.5) : mixed(theme.fg, theme.island(g), 0.85)
                }
            }
            c.w = dimmed(i) ? 0.25 : 1
            let shape: Float = n.kind == "tag" ? 2 : n.category == "entity" ? 1 : 0
            out.append(NodeInstance(pos: SIMD2(Float(n.x), Float(n.y)), sizeShape: SIMD2(pxRadius(i), shape), color: c))
        }
        if let s = selected, let i = index[s] {
            out.append(NodeInstance(pos: SIMD2(Float(nodes[i].x), Float(nodes[i].y)), sizeShape: SIMD2(pxRadius(i) + 3, 2), color: theme.fg))
        }
        return out
    }

    /// Mesh's truncation ladder: more characters the closer you zoom.
    private func maxChars(_ n: Node, full: Bool) -> Int {
        if full { return 64 }
        let hub = n.isHub
        return zoom >= 1.4 ? 60 : zoom >= 0.9 ? (hub ? 24 : 18) : zoom >= 0.6 ? (hub ? 16 : 12) : (hub ? 12 : 0)
    }

    /// Greedy, priority-ordered label placement, so labels never collide. Placement uses a
    /// coarse occupancy bitmap (8pt cells) over the screen, reused between frames.
    private func buildLabels() -> [LabelInstance] {
        if glyphGeneration != atlas.generation {
            glyph = Array(repeating: nil, count: nodes.count); glyphGeneration = atlas.generation
        }
        struct Cand { let p: Int32, i: Int32, sx: Float, sy: Float }
        var cands: [Cand] = []
        cands.reserveCapacity(nodes.count)
        let selIndex = selected.flatMap { index[$0] } ?? -1
        let hov = hover ?? -1
        let w = viewW, h = viewH, z = zoom
        let pills = islandPills()
        let pillsOn = !pills.isEmpty
        for i in 0..<nodes.count {
            let n = nodes[i]
            let sx = (n.x - camX) * z + w / 2, sy = (n.y - camY) * z + h / 2
            if sx < -300 || sx > w + 300 || sy < -40 || sy > h + 40 { continue }
            var p = 0
            if i == selIndex { p = 100 }
            else if i == hov { p = 90 }
            else if let f = focus { if f[i] { p = 50 + (n.isHub ? 5 : 0) + min(9, degree[i]) } }
            else if n.isHub { p = z >= 0.3 && !pillsOn ? 20 + min(20, n.count) : 0 }
            else if z >= 0.55 || n.category != "note" { p = (z >= 0.55 ? 10 : 0) + min(9, degree[i]) + (n.category != "note" ? 12 : 0) }
            // Labels already on screen get a head start, so panning doesn't reshuffle them.
            // A strong head start: a neighbour must clearly outrank it to take its place, so
            // zooming doesn't make neighbouring labels trade places back and forth.
            if p > 0, p < 90, i < shownLastFrame.count, shownLastFrame[i] { p += 25 }
            if p > 0 { cands.append(Cand(p: Int32(p), i: Int32(i), sx: Float(sx), sy: Float(sy))) }
        }
        // Ties break by node index, so the order is the same every frame.
        cands.sort { $0.p != $1.p ? $0.p > $1.p : $0.i < $1.i }
        if shownLastFrame.count != nodes.count { shownLastFrame = Array(repeating: false, count: nodes.count) }
        else { shownLastFrame.withUnsafeMutableBufferPointer { $0.update(repeating: false) } }

        // Occupancy bitmap covering the screen plus the off-screen margin labels may start in.
        // Cells are anchored to the world (not the screen) so panning doesn't change which
        // labels collide; only zooming does.
        let cell = 8.0
        let ox0 = (floor((camX * z - w / 2 - 300) / cell)) * cell - (camX * z - w / 2)
        let oy0 = (floor((camY * z - h / 2 - 40) / cell)) * cell - (camY * z - h / 2)
        let cols = Int((w + 600) / cell) + 4, rows = Int((h + 80) / cell) + 4
        if occupancy.count != cols * rows { occupancy = Array(repeating: 0, count: cols * rows) }
        else { occupancy.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }

        var out: [LabelInstance] = []
        out.reserveCapacity(min(cands.count, 600) * 2)
        let adv = Double(atlas.advance), boxH = Double(GlyphAtlas.boxHeight), s = Double(atlas.scale)
        let aw = Double(atlas.width), ah = Double(atlas.height)
        var faint = theme.fg; faint.w = 0.1
        let folderLabels = byFolder ? folderTitles() : []
        occupancy.withUnsafeMutableBufferPointer { occ in
            // Island pills claim their space first, so node labels flow around them.
            for pill in pills where pill.opacity > 0.3 {
                let pw = Double(pill.title.count) * 7.4 + 34, ph = 32.0
                let sx = Double(pill.point.x) - pw / 2, sy = Double(pill.point.y) - ph / 2
                let c0 = max(0, Int((sx - ox0) / cell)), c1 = min(cols - 1, Int((sx + pw - ox0) / cell))
                let r0 = max(0, Int((sy - oy0) / cell)), r1 = min(rows - 1, Int((sy + ph - oy0) / cell))
                if c0 <= c1 && r0 <= r1 { for r in r0...r1 { for col in c0...c1 { occ[r * cols + col] = 1 } } }
            }
            // Folder names float above their regions, quietly, in Mesh's section-label style.
            for f in folderLabels {
                let e = atlas.entry(f.text, weight: 500)
                let tw = Double(f.text.count) * adv
                let sx = (f.x - camX) * z + w / 2 - tw / 2, sy = (f.y - camY) * z + h / 2
                let c0 = max(0, Int((sx - ox0) / cell)), c1 = min(cols - 1, Int((sx + tw - ox0) / cell))
                let r0 = max(0, Int((sy - oy0) / cell)), r1 = min(rows - 1, Int((sy + boxH - oy0) / cell))
                if c0 <= c1 && r0 <= r1 { for r in r0...r1 { for col in c0...c1 { occ[r * cols + col] = 1 } } }
                var col = theme.fg; col.w = focus == nil ? 0.45 : 0.2
                out.append(LabelInstance(pos: SIMD2(Float(f.x), Float(f.y)), rect: SIMD4(Float(-tw / 2), 0, Float(tw), Float(boxH)),
                                         uv: SIMD4(Float(Double(e.x) / aw), Float(Double(e.y) / ah),
                                                   Float((Double(e.x) + tw * s) / aw), Float(Double(e.y + e.height) / ah)),
                                         color: col))
            }
            if labelAlpha.count != nodes.count { labelAlpha = Array(repeating: 0, count: nodes.count) }
            let now = CACurrentMediaTime()
            let step = Float(min(0.1, now - lastLabelTime) * 9)   // ~110 ms fade
            lastLabelTime = now
            var fading = false

            func emit(_ i: Int, chars: Int, length: Int, ox: Double, oy: Double, bw: Double, alpha: Float) {
                let n = nodes[i]
                let truncated = chars < length
                let pos = SIMD2(Float(n.x), Float(n.y))
                var color = n.isHub ? theme.accent : theme.fg
                if i == selIndex {
                    out.append(LabelInstance(pos: pos, rect: SIMD4(Float(ox), Float(oy), Float(bw), Float(boxH)), uv: SIMD4(-1, 0, 0, 0), color: theme.fg))
                    color = theme.bg
                } else if i == hov {
                    out.append(LabelInstance(pos: pos, rect: SIMD4(Float(ox), Float(oy), Float(bw), Float(boxH)), uv: SIMD4(-1, 0, 0, 0), color: faint))
                } else {
                    color.w = (dimmed(i) ? 0.25 : (n.isHub || focus != nil ? 1 : 0.88)) * alpha
                }
                let weight = n.isHub ? 500 : 400
                let e = glyphFor(i, weight: weight)
                let aw = Double(atlas.width), ah = Double(atlas.height)
                let tw = Double(chars) * adv
                out.append(LabelInstance(pos: pos, rect: SIMD4(Float(ox + 4), Float(oy), Float(tw), Float(boxH)),
                                         uv: SIMD4(Float(Double(e.x) / aw), Float(Double(e.y) / ah),
                                                   Float((Double(e.x) + tw * s) / aw), Float(Double(e.y + e.height) / ah)),
                                         color: color))
                if truncated {
                    let el = atlas.entry("…", weight: weight)
                    out.append(LabelInstance(pos: pos, rect: SIMD4(Float(ox + 4 + tw), Float(oy), Float(adv), Float(boxH)),
                                             uv: SIMD4(Float(Double(el.x) / aw), Float(Double(el.y) / ah),
                                                       Float((Double(el.x) + adv * s) / aw), Float(Double(el.y + el.height) / ah)),
                                             color: color))
                }
            }

            for c in cands {
                let i = Int(c.i), n = nodes[i]
                let length = labelLength[i]
                let chars = min(length, maxChars(n, full: c.p >= 50))
                guard chars > 0 else { continue }
                let truncated = chars < length
                let bw = Double(truncated ? chars + 1 : chars) * adv + 8
                let ox = -bw / 2, oy = Double(radius[i]) + 2
                let x0 = Double(c.sx) + ox, y0 = Double(c.sy) + oy
                let c0 = max(0, Int((x0 - ox0) / cell)), c1 = min(cols - 1, Int((x0 + bw - ox0) / cell))
                let r0 = max(0, Int((y0 - oy0) / cell)), r1 = min(rows - 1, Int((y0 + boxH - oy0) / cell))
                if c0 > c1 || r0 > r1 { continue }
                if c.p < 90 {
                    var taken = false
                    rowLoop: for r in r0...r1 { for col in c0...c1 where occ[r * cols + col] != 0 { taken = true; break rowLoop } }
                    if taken { continue }
                }
                for r in r0...r1 { for col in c0...c1 { occ[r * cols + col] = 1 } }
                shownLastFrame[i] = true
                // Selected and hovered labels appear at once; the rest fade in.
                let a = (i == selIndex || i == hov) ? 1 : min(1, labelAlpha[i] + step)
                labelAlpha[i] = a
                if a < 1 { fading = true }
                emit(i, chars: chars, length: length, ox: ox, oy: oy, bw: bw, alpha: a)
            }
            // Labels that just lost their place fade out where they were.
            for i in 0..<nodes.count where !shownLastFrame[i] && labelAlpha[i] > 0 {
                let a = max(0, labelAlpha[i] - step)
                labelAlpha[i] = a
                guard a > 0 else { continue }
                fading = true
                let n = nodes[i], length = labelLength[i]
                let chars = min(length, maxChars(n, full: false))
                guard chars > 0 else { continue }
                let bw = Double(chars < length ? chars + 1 : chars) * adv + 8
                emit(i, chars: chars, length: length, ox: -bw / 2, oy: Double(radius[i]) + 2, bw: bw, alpha: a)
            }
            labelsFading = fading
        }
        return out
    }

    /// A node's atlas slot. If drawing it made the atlas grow, every cached slot moved, so the
    /// cache starts over.
    private func glyphFor(_ i: Int, weight: Int) -> GlyphAtlas.Entry {
        if glyphGeneration != atlas.generation {
            glyph = Array(repeating: nil, count: nodes.count); glyphGeneration = atlas.generation
        }
        if let g = glyph[i] { return g }
        let e = atlas.entry(labelText[i], weight: weight)
        if glyphGeneration != atlas.generation {
            glyph = Array(repeating: nil, count: nodes.count); glyphGeneration = atlas.generation
        }
        glyph[i] = e
        return e
    }

    /// Where to put each folder's name: centred above the folder's notes.
    private func folderTitles() -> [(text: String, x: Double, y: Double)] {
        var sx = [Double](repeating: 0, count: folderNames.count), minY = [Double](repeating: .infinity, count: folderNames.count)
        var cnt = [Double](repeating: 0, count: folderNames.count)
        for (i, n) in nodes.enumerated() where folderOf[i] >= 0 {
            let f = folderOf[i]; sx[f] += n.x; cnt[f] += 1; minY[f] = min(minY[f], n.y)
        }
        return folderNames.indices.compactMap { f in
            cnt[f] > 0 ? (folderNames[f].uppercased(), sx[f] / cnt[f], minY[f] - 26 / zoom) : nil
        }
    }

    // MARK: - Camera

    private func centred(_ wx: Double, _ wy: Double, zoom z: Double) -> (Double, Double) {
        let cx = insets.left + (viewW - insets.left - insets.right) / 2
        let cy = insets.top + (viewH - insets.top - insets.bottom) / 2
        return (wx - (cx - viewW / 2) / z, wy - (cy - viewH / 2) / z)
    }

    private func animate(to x: Double, _ y: Double, zoom z: Double, duration: Double = 0.45) {
        let z = min(maxZoom, max(minZoom, z))
        tween = Tween(from: (camX, camY, zoom), to: (x, y, z), start: CACurrentMediaTime(), duration: duration)
        setAnimating(true)
    }

    func fit(duration: Double = 0.45, only: Set<String>? = nil, padding: Double = 60, maxZoom cap: Double = 8) {
        let set = nodes.filter { only?.contains($0.id) ?? true }
        guard !set.isEmpty else { return }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for n in set { x0 = min(x0, n.x); y0 = min(y0, n.y); x1 = max(x1, n.x); y1 = max(y1, n.y) }
        let aw = viewW - insets.left - insets.right - padding * 2, ah = viewH - insets.top - insets.bottom - padding * 2
        let z = min(cap, maxZoom, max(minZoom, min(aw / max(1, x1 - x0), ah / max(1, y1 - y0))))
        let (cx, cy) = centred((x0 + x1) / 2, (y0 + y1) / 2, zoom: z)
        if duration > 0 { animate(to: cx, cy, zoom: z, duration: duration) }
        else { camX = cx; camY = cy; zoom = z; redraw() }
    }

    /// Zoom buttons: ease around the middle of the view.
    func zoomCentre(by factor: Double) {
        let base = tween?.to ?? (camX, camY, zoom)
        animate(to: base.0, base.1, zoom: base.2 * factor, duration: 0.3)
    }

    private func zoom(at sx: Double, _ sy: Double, by factor: Double) {
        tween = nil
        let z = min(maxZoom, max(minZoom, zoom * factor))
        let wx = (sx - viewW / 2) / zoom + camX, wy = (sy - viewH / 2) / zoom + camY
        zoom = z
        camX = wx - (sx - viewW / 2) / z; camY = wy - (sy - viewH / 2) / z
        redraw()
    }

    private func zoomTo(_ id: String) {
        guard let i = index[id] else { return }
        let n = nodes[i]
        if n.isHub {
            fit(only: Set([n.id] + neighbours[i].map { nodes[$0].id }), padding: 120, maxZoom: 2.6)
        } else {
            let z = max(zoom, 1.8)
            let (x, y) = centred(n.x, n.y, zoom: z)
            animate(to: x, y, zoom: z)
        }
    }

    // MARK: - Input

    /// View point with a top-left origin (SwiftUI's convention).
    private func point(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        return (Double(p.x), viewH - Double(p.y))
    }

    private func pick(_ sx: Double, _ sy: Double) -> Int? {
        var best: Int?, bestD = Double.infinity
        for i in nodes.indices {
            let (x, y) = screen(nodes[i])
            let d = (x - sx) * (x - sx) + (y - sy) * (y - sy)
            let r = max(7, Double(pxRadius(i)) + 4)
            if d < r * r && d < bestD { bestD = d; best = i }
        }
        return best
    }

    // Trackpad: two-finger scroll pans, pinch zooms. Mouse wheel (or ⌘/⌥ + scroll) zooms — as in Mesh.
    override func scrollWheel(with event: NSEvent) {
        let (x, y) = point(event)
        if !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            zoom(at: x, y, by: exp(max(-0.4, min(0.4, Double(dy)))))
        } else {
            tween = nil
            camX -= Double(event.scrollingDeltaX) / zoom
            camY -= Double(event.scrollingDeltaY) / zoom
            redraw()
        }
        setHover(nil)
    }

    override func magnify(with event: NSEvent) {
        let (x, y) = point(event)
        zoom(at: x, y, by: 1 + Double(event.magnification))
        setHover(nil)
    }

    private var drag: (node: Int?, x: Double, y: Double, moved: Bool, cam: (Double, Double))?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onPress?()
        let (x, y) = point(event)
        let hit = pillsActive ? nil : pick(x, y)
        if event.clickCount == 2 {
            if let i = hit, nodes[i].kind == "note" { onOpen?(nodes[i].id) }
            drag = nil
            return
        }
        tween = nil
        drag = (hit, x, y, false, (camX, camY))
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let (x, y) = point(event)
        let dx = x - d.x, dy = y - d.y
        if !d.moved && dx * dx + dy * dy < 16 { return }
        d.moved = true
        drag = d
        setHover(nil)
        if let i = d.node {
            sim.fixed[i] = true
            sim.fx[i] = (x - viewW / 2) / zoom + camX
            sim.fy[i] = (y - viewH / 2) / zoom + camY
            nodes[i].pinned = true
            sim.alphaTarget = 0.15
            if sim.alpha < 0.15 { sim.alpha = 0.15 }
            setAnimating(true)
        } else {
            camX = d.cam.0 - dx / zoom; camY = d.cam.1 - dy / zoom
            redraw()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        if d.node != nil && d.moved { sim.alphaTarget = 0; return }   // stays pinned where dropped
        if d.moved { return }
        if let i = d.node { setSelected(nodes[i].id, fromGraph: true); zoomTo(nodes[i].id) }
        else { setSelected(nil, fromGraph: true) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let (x, y) = point(event)
        if let i = pick(x, y), nodes[i].kind == "note" { onOpen?(nodes[i].id) }
    }

    /// While island pills are showing (zoomed far out) they're what you point at: single notes
    /// don't react to hover or clicks until the pills have faded and you're close enough.
    private var pillsActive: Bool { lastPills.contains { $0.opacity > 0.3 } }

    override func mouseMoved(with event: NSEvent) {
        let (x, y) = point(event)
        let hit = pillsActive ? nil : pick(x, y)
        if hit != hover {
            setHover(hit)
            (hit != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
    override func mouseExited(with event: NSEvent) { setHover(nil); NSCursor.arrow.set() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { setTypeFilter(nil); setSelected(nil, fromGraph: true) }   // Escape
        else { super.keyDown(with: event) }
    }

    private func setHover(_ i: Int?) {
        guard i != hover else { return }
        hover = i
        refreshFocus()
        reportHover()
    }

    private func reportHover() {
        guard let i = hover, nodes[i].kind == "note" else { onHover?(nil); return }
        let n = nodes[i]
        let (x, y) = screen(n)
        onHover?(GraphHover(id: n.id, label: n.label, category: n.category, group: n.group, snippet: n.snippet,
                            links: degree[i], point: CGPoint(x: x, y: y + Double(pxRadius(i)))))
    }

    // MARK: - Focus

    private func setSelected(_ id: String?, fromGraph: Bool) {
        guard id != selected else { return }
        selected = id
        refreshFocus()
        if fromGraph { onSelect?(id) }
    }

    private func refreshFocus() {
        let anchor = selected.flatMap { index[$0] } ?? hover
        var f: [Bool]?
        if let a = anchor {
            f = Array(repeating: false, count: nodes.count)
            f![a] = true
            for j in neighbours[a] { f![j] = true }
        }
        var extra = queryMatches ?? islandMatches
        if extra == nil, let t = typeFilter { extra = Set(nodes.filter { $0.type == t }.map(\.id)) }
        if let extra {
            if f == nil { f = Array(repeating: false, count: nodes.count) }
            for id in extra { if let i = index[id] { f![i] = true } }
        }
        focus = f
        redraw()
    }

    // MARK: - Public API (GraphController)

    func setData(_ payload: GraphPayload) {
        self.payload = payload
        var next: [String: Node] = [:]
        for g in payload.nodes {
            let n = nodeByID[g.id] ?? Node(id: g.id)
            n.kind = g.kind; n.label = g.label; n.group = g.group; n.count = g.count
            n.snippet = g.snippet ?? ""; n.source = g.source ?? ""; n.category = g.category ?? "note"
            next[g.id] = n
        }
        nodeByID = next
        apply()
    }

    func setLayers(_ l: [String: Bool]) { layers.merge(l) { _, b in b }; apply() }
    func setClustering(islands: Bool, folders: Bool) {
        guard islands != self.islands || folders != byFolder else { return }
        self.islands = islands; byFolder = folders
        sim.alpha = 0.8   // a real re-layout, not a nudge
        apply()
    }
    func setSimilar(_ k: Int) { similarK = k; apply() }

    func setQuery(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        queryMatches = q.isEmpty ? nil : Set(nodeByID.values.filter {
            $0.label.lowercased().contains(q) || $0.snippet.lowercased().contains(q)
        }.map(\.id))
        refreshFocus()
    }

    func focusNode(_ id: String?) {
        guard id != selected else { return }
        setSelected(id, fromGraph: false)
        if let id { zoomTo(id) }
    }

    func setInsets(_ i: NSEdgeInsets) { insets = i }

    /// Highlight one island and frame it (nil clears).
    func focusIsland(_ ids: Set<String>?) {
        guard ids != islandMatches else { return }
        islandMatches = ids
        if ids != nil { setSelected(nil, fromGraph: false); fit(only: ids, padding: 80) }
        refreshFocus()
    }

    /// Where each named island's pill goes (its notes' centre, on screen) and how visible it is.
    private func islandPills() -> [IslandPill] {
        var result: [IslandPill] = []
        let t = (Self.pillZoomStart - zoom) / (Self.pillZoomStart - Self.pillZoomFull)
        let opacity = min(1, max(0, t))
        if opacity > 0, islands, !islandTitle.isEmpty, islandOf.count == nodes.count {
            var sx: [Int: Double] = [:], sy: [Int: Double] = [:], cnt: [Int: Double] = [:]
            for (i, g) in islandOf.enumerated() where islandTitle[g] != nil && !nodes[i].isHub {
                sx[g, default: 0] += nodes[i].x; sy[g, default: 0] += nodes[i].y; cnt[g, default: 0] += 1
            }
            for (g, c) in cnt {
                let x = (sx[g]! / c - camX) * zoom + viewW / 2, y = (sy[g]! / c - camY) * zoom + viewH / 2
                guard x > -100, x < viewW + 100, y > -40, y < viewH + 40 else { continue }
                // Dim islands outside the current focus, like their notes.
                result.append(IslandPill(id: g, title: islandTitle[g]!, count: Int(c),
                                         point: CGPoint(x: (x * 2).rounded() / 2, y: (y * 2).rounded() / 2),
                                         opacity: (opacity * 20).rounded() / 20))
            }
            result.sort { ($0.count, $1.id) > ($1.count, $0.id) }
            // Like labels: the biggest islands keep their pill; one that would overlap a bigger
            // one waits until you zoom in far enough to make room.
            var taken: [CGRect] = []
            result = result.filter { p in
                let w = Double(p.title.count) * 7.6 + 56
                let r = CGRect(x: p.point.x - w / 2, y: p.point.y - 17, width: w, height: 34)
                guard !taken.contains(where: { $0.intersects(r) }) else { return false }
                taken.append(r)
                return true
            }
        }
        if result != lastPills {
            lastPills = result
            // Synchronously, inside this frame: SwiftUI's update and this frame's drawable
            // (presentsWithTransaction) land in the same Core Animation commit.
            onPills?(result)
        }
        return result
    }

    /// Places the pills' glass views. Runs inside `draw`, so the frames land in the same
    /// transaction as this frame's drawable.
    private func layoutPills(_ pills: [IslandPill]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<Int>()
        for p in pills {
            seen.insert(p.id)
            let v: IslandPillView
            if let existing = pillViews[p.id] { v = existing } else {
                v = IslandPillView(graph: self) { [weak self] in self?.onPillClick?(p.id) }
                pillLayer.addSubview(v)
                pillViews[p.id] = v
            }
            v.set(title: p.title, count: p.count)
            let size = v.preferredSize
            let y = Double(pillLayer.bounds.height) - Double(p.point.y)
            v.frame = NSRect(x: (Double(p.point.x) - size.width / 2).rounded(), y: (y - size.height / 2).rounded(),
                             width: size.width, height: size.height)
            v.alphaValue = p.opacity
        }
        for (id, v) in pillViews where !seen.contains(id) { v.removeFromSuperview(); pillViews[id] = nil }
        CATransaction.commit()
    }

    /// Islands for the drawer: named after the topic most of their notes share (else their
    /// best-connected note), with member positions for a mini map.
    private func reportIslands() {
        guard !islandOf.isEmpty else { onIslands?([]); return }
        var members: [Int: [Int]] = [:]
        for (i, g) in islandOf.enumerated() where g >= 0 && !looseIslands.contains(g) { members[g, default: []].append(i) }
        var out: [IslandSummary] = []
        for (g, idx) in members {
            let notes = idx.filter { !nodes[$0].isHub }
            guard notes.count >= 3 else { continue }
            let hub = idx.filter { nodes[$0].isHub }.max { degree[$0] < degree[$1] }
            let best = hub ?? notes.max { degree[$0] < degree[$1] }!
            var title = nodes[best].label
            if title.hasPrefix("#") { title.removeFirst() }
            let xs = notes.map { nodes[$0].x }, ys = notes.map { nodes[$0].y }
            let x0 = xs.min()!, y0 = ys.min()!, w = max(1, xs.max()! - x0), h = max(1, ys.max()! - y0)
            let s = max(w, h)
            let pts = notes.map { CGPoint(x: (nodes[$0].x - x0 + (s - w) / 2) / s, y: (nodes[$0].y - y0 + (s - h) / 2) / s) }
            out.append(IslandSummary(id: g, title: title.prefix(1).uppercased() + title.dropFirst(),
                                     noteIDs: notes.map { nodes[$0].id }, points: pts, types: notes.map { nodes[$0].type }))
        }
        islandTitle = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0.title) })
        onIslands?(out.sorted { $0.count > $1.count })
    }

    func setTypeFilter(_ t: String?) {
        typeFilter = t
        reportTypes()
        refreshFocus()
    }

    private func reportTypes() {
        var counts: [String: Int] = [:]
        for n in nodes { counts[n.type, default: 0] += 1 }
        onTypes?(counts, typeFilter)
    }

    private func apply() {
        guard let payload else { return }
        let old = nodes
        nodes = payload.nodes.filter { $0.kind == "note" || layers[$0.kind] == true }.compactMap { nodeByID[$0.id] }
        index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        links = payload.links.compactMap { l in
            guard layers[l.kind] == true, l.kind != "similar" || l.rank < similarK,
                  let s = index[l.source], let t = index[l.target] else { return nil }
            return Link(s: s, t: t, kind: l.kind, w: l.w, rank: l.rank)
        }
        neighbours = Array(repeating: [], count: nodes.count)
        degree = Array(repeating: 0, count: nodes.count)
        for l in links {
            neighbours[l.s].append(l.t); neighbours[l.t].append(l.s)
            degree[l.s] += 1; degree[l.t] += 1
        }
        if let s = selected, index[s] == nil { selected = nil }
        hover = nil
        radius = []; radius = nodes.indices.map { _ in 0 }
        for i in nodes.indices { radius[i] = computeRadius(i) }
        labelText = nodes.map { $0.label.count > 64 ? String($0.label.prefix(63)) : $0.label }
        labelLength = labelText.map(\.count)
        glyph = Array(repeating: nil, count: nodes.count); glyphGeneration = atlas.generation

        // New nodes start beside a placed neighbour, so additions don't fly in from the origin.
        for (i, n) in nodes.enumerated() where !n.x.isFinite {
            let anchor = neighbours[i].map { nodes[$0] }.first { $0.x.isFinite }
            let a = Double.random(in: 0..<(2 * .pi)), r = anchor != nil ? 20 : 220 * Double.random(in: 0..<1).squareRoot()
            n.x = (anchor?.x ?? 0) + cos(a) * r; n.y = (anchor?.y ?? 0) + sin(a) * r
        }

        sim.x = nodes.map(\.x); sim.y = nodes.map(\.y)
        sim.vx = Array(repeating: 0, count: nodes.count); sim.vy = sim.vx
        sim.fixed = nodes.map(\.pinned); sim.fx = sim.x; sim.fy = sim.y
        let layout = LayoutSetup.configure(sim, isHub: nodes.map(\.isHub), folder: nodes.map(\.group),
                                           edges: links.map { LayoutSetup.Edge(s: $0.s, t: $0.t, kind: $0.kind, w: $0.w) },
                                           islands: islands, byFolder: byFolder)
        folderNames = layout.folderNames
        folderOf = layout.folderOf
        islandOf = layout.groups
        looseIslands = layout.looseGroups
        if firstFit || old.isEmpty {
            sim.alpha = 1
            // Settle most of the way before the first frame, then let the rest animate.
            for _ in 0..<160 where sim.alpha > 0.05 { sim.tick() }
            for (i, n) in nodes.enumerated() { n.x = sim.x[i]; n.y = sim.y[i] }
            fit(duration: 0)
        } else {
            sim.alpha = max(sim.alpha, 0.3)
        }

        // Rasterise every label up front, so zooming never waits on text.
        // Rasterise up front (may grow the atlas); slots are looked up lazily per frame.
        for (i, n) in nodes.enumerated() { _ = atlas.entry(labelText[i], weight: n.isHub ? 500 : 400) }
        glyph = Array(repeating: nil, count: nodes.count); glyphGeneration = atlas.generation
        _ = atlas.entry("…", weight: 400); _ = atlas.entry("…", weight: 500)

        reportTypes()
        refreshFocus()
        setAnimating(true)
    }

    // MARK: - Shaders (compiled at runtime; no Metal toolchain needed)

    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 center; float2 view; float zoom; float dpr; float2 pad; float4 ink; };
    static float2 w2s(float2 w, constant Uniforms& u) { return (w - u.center) * u.zoom + u.view * 0.5; }
    static float4 toClip(float2 s, constant Uniforms& u) { float2 n = s / u.view * 2.0 - 1.0; return float4(n.x, -n.y, 0, 1); }
    static float2 snapPx(float2 s, constant Uniforms& u) { return floor(s * u.dpr + 0.5) / u.dpr; }

    constant float2 QUAD[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
    constant float2 LINEQ[6] = { float2(0,-1), float2(1,-1), float2(0,1), float2(0,1), float2(1,-1), float2(1,1) };

    // Edges: 1pt quads; dash patterns measured in screen points.
    struct EdgeInst { float4 line; float4 color; float2 style; float2 pad; };
    struct EdgeOut { float4 pos [[position]]; float along; float side; float2 style [[flat]]; float4 color [[flat]]; };
    vertex EdgeOut edgeVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device EdgeInst* inst [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        EdgeInst e = inst[iid];
        float2 c = LINEQ[vid];
        float2 p0 = w2s(e.line.xy, u), p1 = w2s(e.line.zw, u);
        float2 d = p1 - p0; float len = max(length(d), 0.001);
        float2 n = float2(-d.y, d.x) / len;
        EdgeOut o;
        o.pos = toClip(mix(p0, p1, c.x) + n * c.y, u);
        o.along = c.x * len; o.side = c.y; o.style = e.style; o.color = e.color;
        return o;
    }
    fragment float4 edgeFS(EdgeOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
        float st = in.style.x;
        if (st > 0.5 && st < 1.5 && fmod(in.along, 6.0) >= 3.0) discard_fragment();
        if (st > 1.5 && fmod(in.along, 3.0) >= 1.0) discard_fragment();
        float a = clamp(1.0 - abs(in.side), 0.0, 1.0) * in.style.y;
        return float4(in.color.rgb * a, a);
    }

    // Nodes: circle, square (entities) or 1pt hollow square (tags, the selection frame).
    struct NodeInst { float2 pos; float2 sizeShape; float4 color; };
    struct NodeOut { float4 pos [[position]]; float2 local; float2 ss [[flat]]; float4 color [[flat]]; };
    vertex NodeOut nodeVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device NodeInst* inst [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        NodeInst n = inst[iid];
        float ext = n.sizeShape.x + 1.5;
        NodeOut o;
        o.local = QUAD[vid] * ext;
        o.pos = toClip(snapPx(w2s(n.pos, u), u) + o.local, u);
        o.ss = n.sizeShape; o.color = n.color;
        return o;
    }
    fragment float4 nodeFS(NodeOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
        float r = in.ss.x, d;
        float2 q = abs(in.local);
        if (in.ss.y < 0.5) d = length(in.local) - r;
        else if (in.ss.y < 1.5) d = max(q.x, q.y) - r * 0.9;
        else d = abs(max(q.x, q.y) - r) - 0.5;
        float a = clamp(0.5 - d * u.dpr, 0.0, 1.0) * in.color.a;
        return float4(in.color.rgb * a, a);
    }

    // Labels: glyph-atlas quads (alpha mask), or solid boxes for selection / hover fills.
    struct LabelInst { float2 pos; float2 pad; float4 rect; float4 uv; float4 color; };
    struct LabelOut { float4 pos [[position]]; float2 uv; float solid [[flat]]; float4 color [[flat]]; };
    vertex LabelOut labelVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device LabelInst* inst [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        LabelInst l = inst[iid];
        float2 corner = (QUAD[vid] + 1.0) * 0.5;
        LabelOut o;
        o.pos = toClip(snapPx(w2s(l.pos, u) + l.rect.xy, u) + corner * l.rect.zw, u);
        o.uv = mix(l.uv.xy, l.uv.zw, corner);
        o.solid = l.uv.x < 0.0 ? 1.0 : 0.0;
        o.color = l.color;
        return o;
    }
    fragment float4 labelFS(LabelOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {
        float a = (in.solid > 0.5 ? 1.0 : atlas.sample(s, in.uv).r) * in.color.a;
        return float4(in.color.rgb * a, a);
    }
    """
}


/// One island name as a native Liquid Glass capsule (title, then its note count).
final class IslandPillView: NSGlassEffectView {
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let action: () -> Void
    private weak var graph: NSView?
    private(set) var preferredSize = NSSize(width: 60, height: 30)
    private var shown: (String, Int)?

    init(graph: NSView, action: @escaping () -> Void) {
        self.action = action
        self.graph = graph
        super.init(frame: .zero)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        countField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countField.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleField, countField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.alignment = .firstBaseline
        contentView = stack
        style = .regular
        // A little body behind the text, so names stay legible over dense clusters.
        tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, count: Int) {
        guard shown?.0 != title || shown?.1 != count else { return }
        shown = (title, count)
        titleField.stringValue = title
        countField.stringValue = "\(count)"
        let w = ceil(titleField.intrinsicContentSize.width + countField.intrinsicContentSize.width) + 6 + 24
        preferredSize = NSSize(width: w, height: 30)
        cornerRadius = 15
        toolTip = "Show the \(title) island"
        setAccessibilityLabel("\(title) island, \(count) notes")
    }

    // The pill is part of the map: scrolling, pinching and dragging over it move the graph,
    // and only a clean click opens the island.
    private var down: NSEvent?, dragging = false
    override func scrollWheel(with event: NSEvent) { graph?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { graph?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { graph?.smartMagnify(with: event) }
    override func mouseDown(with event: NSEvent) { down = event; dragging = false; alphaValue = 0.75 }
    override func mouseDragged(with event: NSEvent) {
        guard let start = down else { return }
        if !dragging {
            let a = start.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            dragging = true
            alphaValue = 1
            graph?.mouseDown(with: start)
        }
        graph?.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        defer { down = nil; dragging = false }
        if dragging { graph?.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}


/// A see-through view: hits on its own empty area fall through to whatever is underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// The graph plus its pill overlay, as one view for SwiftUI.
final class GraphContainerView: NSView {
    init(graph: MetalGraphView) {
        super.init(frame: .zero)
        graph.autoresizingMask = [.width, .height]
        graph.pillLayer.autoresizingMask = [.width, .height]
        addSubview(graph)
        addSubview(graph.pillLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
}
