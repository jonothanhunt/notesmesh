import Foundation

/// A d3-force style simulation: Barnes–Hut many-body repulsion, spring links, weak gravity
/// to the origin, velocity decay and a cooling alpha. Same parameters the graph used in d3,
/// so the layout looks the same; ~1 ms per tick for ~1,000 nodes.
final class ForceSim {
    struct Link { var s: Int, t: Int, distance: Double, strength: Double, bias: Double = 0.5 }

    var x: [Double] = [], y: [Double] = [], vx: [Double] = [], vy: [Double] = []
    var fixed: [Bool] = [], fx: [Double] = [], fy: [Double] = []
    var charge: [Double] = []
    var links: [Link] = []

    var alpha = 1.0, alphaMin = 0.001, alphaTarget = 0.0
    let alphaDecay = 1 - pow(0.001, 1.0 / 300)
    var velocityDecay = 0.32
    var theta2 = 0.81
    var distanceMax2 = 460.0 * 460.0
    var gravity = 0.02

    // Islands: each node's group (-1 for none). Members are pulled to their group's centre,
    // and groups push each other apart until they no longer overlap.
    var group: [Int] = []
    var groupPull = 0.0
    var groupGap = 1.35
    // Optional anchors (folders): each node drifts towards its own anchor point.
    var anchorX: [Double] = [], anchorY: [Double] = []
    var anchorPull = 0.0

    var isActive: Bool { alpha > alphaMin || alphaTarget > alphaMin }

    func setLinks(_ ls: [Link]) {
        var count = [Int](repeating: 0, count: x.count)
        for l in ls { count[l.s] += 1; count[l.t] += 1 }
        links = ls.map { l in
            var l = l
            l.bias = Double(count[l.s]) / Double(max(1, count[l.s] + count[l.t]))
            return l
        }
    }

    func tick() {
        alpha += (alphaTarget - alpha) * alphaDecay
        let n = x.count
        guard n > 0 else { return }

        // Links (d3.forceLink, one iteration).
        for l in links {
            var dx = x[l.t] + vx[l.t] - x[l.s] - vx[l.s]
            var dy = y[l.t] + vy[l.t] - y[l.s] - vy[l.s]
            if dx == 0 { dx = jiggle() }
            if dy == 0 { dy = jiggle() }
            let len = (dx * dx + dy * dy).squareRoot()
            let k = (len - l.distance) / len * alpha * l.strength
            dx *= k; dy *= k
            vx[l.t] -= dx * l.bias; vy[l.t] -= dy * l.bias
            vx[l.s] += dx * (1 - l.bias); vy[l.s] += dy * (1 - l.bias)
        }

        // Many-body (Barnes–Hut).
        let tree = QuadTree(x: x, y: y, charge: charge)
        for i in 0..<n { tree.apply(to: i, x: x[i], y: y[i], alpha: alpha, theta2: theta2, distanceMax2: distanceMax2, vx: &vx[i], vy: &vy[i]) }

        applyGroups()
        if anchorPull > 0, anchorX.count == n {
            let k = anchorPull * alpha
            for i in 0..<n where anchorX[i].isFinite {
                vx[i] += (anchorX[i] - x[i]) * k; vy[i] += (anchorY[i] - y[i]) * k
            }
        }

        // Gravity towards the origin, then integrate.
        let g = (anchorPull > 0 ? gravity * 0.3 : gravity) * alpha
        for i in 0..<n {
            if fixed[i] { x[i] = fx[i]; y[i] = fy[i]; vx[i] = 0; vy[i] = 0; continue }
            vx[i] += -x[i] * g; vy[i] += -y[i] * g
            vx[i] *= 1 - velocityDecay; vy[i] *= 1 - velocityDecay
            x[i] += vx[i]; y[i] += vy[i]
        }
    }

    private func applyGroups() {
        guard groupPull > 0, group.count == x.count else { return }
        let groups = (group.max() ?? -1) + 1
        guard groups > 0 else { return }
        var sx = [Double](repeating: 0, count: groups), sy = sx, cnt = sx
        for i in x.indices where group[i] >= 0 { sx[group[i]] += x[i]; sy[group[i]] += y[i]; cnt[group[i]] += 1 }
        for g in 0..<groups where cnt[g] > 0 { sx[g] /= cnt[g]; sy[g] /= cnt[g] }
        // Pull members in.
        let k = groupPull * alpha
        for i in x.indices where group[i] >= 0 {
            vx[i] += (sx[group[i]] - x[i]) * k; vy[i] += (sy[group[i]] - y[i]) * k
        }
        // Push overlapping groups apart (radius grows with membership).
        var dvx = [Double](repeating: 0, count: groups), dvy = dvx
        for a in 0..<groups where cnt[a] >= 3 {
            let ra = cnt[a].squareRoot() * 16
            for b in (a + 1)..<max(a + 1, groups) where cnt[b] >= 3 {
                let rb = cnt[b].squareRoot() * 16
                var dx = sx[b] - sx[a], dy = sy[b] - sy[a]
                if dx == 0 && dy == 0 { dx = jiggle(); dy = jiggle() }
                let d = (dx * dx + dy * dy).squareRoot()
                let want = (ra + rb) * groupGap
                guard d < want else { continue }
                let push = (want - d) / d * alpha * 0.25
                let wa = cnt[b] / (cnt[a] + cnt[b]), wb = 1 - wa
                dvx[a] -= dx * push * wa; dvy[a] -= dy * push * wa
                dvx[b] += dx * push * wb; dvy[b] += dy * push * wb
            }
        }
        for i in x.indices where group[i] >= 0 && cnt[group[i]] >= 3 { vx[i] += dvx[group[i]]; vy[i] += dvy[group[i]] }
    }

    private func jiggle() -> Double { (Double.random(in: 0..<1) - 0.5) * 1e-6 }
}

/// Flat-array quadtree with strength-weighted centres, rebuilt each tick.
final class QuadTree {
    private var cx: [Double] = [], cy: [Double] = [], value: [Double] = [], size: [Double] = []
    private var child: [Int32] = []          // 4 per node, -1 when empty
    private var pointStart: [Int32] = [], pointCount: [Int32] = []
    private var points: [Int32] = []
    private let px: [Double], py: [Double], q: [Double]

    init(x: [Double], y: [Double], charge: [Double]) {
        px = x; py = y; q = charge
        guard !x.isEmpty else { return }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for i in x.indices { x0 = min(x0, x[i]); y0 = min(y0, y[i]); x1 = max(x1, x[i]); y1 = max(y1, y[i]) }
        let s = max(x1 - x0, y1 - y0, 1)
        var idx = Array(0..<Int32(x.count))
        points.reserveCapacity(x.count)
        _ = build(&idx[...], x0: x0, y0: y0, s: s, depth: 0)
    }

    private func build(_ idx: inout ArraySlice<Int32>, x0: Double, y0: Double, s: Double, depth: Int) -> Int32 {
        let node = Int32(cx.count)
        cx.append(0); cy.append(0); value.append(0); size.append(s)
        child.append(contentsOf: [-1, -1, -1, -1]); pointStart.append(-1); pointCount.append(0)
        if idx.count <= 1 || depth > 24 {
            pointStart[Int(node)] = Int32(points.count); pointCount[Int(node)] = Int32(idx.count)
            var v = 0.0, wx = 0.0, wy = 0.0, w = 0.0
            for i in idx { points.append(i); let c = q[Int(i)]; v += c; w += abs(c); wx += abs(c) * px[Int(i)]; wy += abs(c) * py[Int(i)] }
            value[Int(node)] = v; cx[Int(node)] = w > 0 ? wx / w : px[Int(idx.first!)]; cy[Int(node)] = w > 0 ? wy / w : py[Int(idx.first!)]
            return node
        }
        let h = s / 2, mx = x0 + h, my = y0 + h
        var quads: [[Int32]] = [[], [], [], []]
        for i in idx { quads[(px[Int(i)] >= mx ? 1 : 0) + (py[Int(i)] >= my ? 2 : 0)].append(i) }
        var v = 0.0, wx = 0.0, wy = 0.0, w = 0.0
        for k in 0..<4 where !quads[k].isEmpty {
            var slice = quads[k][...]
            let c = build(&slice, x0: k & 1 == 1 ? mx : x0, y0: k & 2 == 2 ? my : y0, s: h, depth: depth + 1)
            child[Int(node) * 4 + k] = c
            let cv = value[Int(c)], aw = abs(cv)
            v += cv; w += aw; wx += aw * cx[Int(c)]; wy += aw * cy[Int(c)]
        }
        value[Int(node)] = v; cx[Int(node)] = w > 0 ? wx / w : mx; cy[Int(node)] = w > 0 ? wy / w : my
        return node
    }

    func apply(to i: Int, x xi: Double, y yi: Double, alpha: Double, theta2: Double, distanceMax2: Double,
               vx: inout Double, vy: inout Double) {
        guard !cx.isEmpty else { return }
        var stack: [Int32] = [0]
        while let node = stack.popLast().map(Int.init) {
            let dx = cx[node] - xi, dy = cy[node] - yi
            var l = dx * dx + dy * dy
            let w = size[node]
            let leaf = pointStart[node] >= 0
            if !leaf && w * w / theta2 < l {
                // Far enough: treat the whole quad as one body.
                if l < distanceMax2 {
                    if l < 1 { l = (1 * l).squareRoot() }
                    vx += dx * value[node] * alpha / max(l, 1e-6); vy += dy * value[node] * alpha / max(l, 1e-6)
                }
                continue
            }
            if leaf {
                let start = Int(pointStart[node])
                for p in start..<(start + Int(pointCount[node])) {
                    let j = Int(points[p]); if j == i { continue }
                    var ddx = px[j] - xi, ddy = py[j] - yi
                    if ddx == 0 { ddx = (Double.random(in: 0..<1) - 0.5) * 1e-6 }
                    if ddy == 0 { ddy = (Double.random(in: 0..<1) - 0.5) * 1e-6 }
                    var ll = ddx * ddx + ddy * ddy
                    if ll >= distanceMax2 { continue }
                    if ll < 1 { ll = ll.squareRoot() }
                    vx += ddx * q[j] * alpha / ll; vy += ddy * q[j] * alpha / ll
                }
                continue
            }
            if l >= distanceMax2 + w * w { continue }
            for k in 0..<4 { let c = child[node * 4 + k]; if c >= 0 { stack.append(c) } }
        }
    }
}
