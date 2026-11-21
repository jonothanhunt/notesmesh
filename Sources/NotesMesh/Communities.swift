import Foundation

/// Louvain community detection (weighted, undirected): finds groups of notes that are much
/// more connected to each other than to the rest. The layout turns these into islands.
enum Communities {
    static func louvain(count n: Int, edges: [(Int, Int, Double)], resolution: Double = 1.0) -> [Int] {
        var membership = Array(0..<n)
        var nodes = n
        var es = edges
        for _ in 0..<5 {
            let (local, moved) = localMoving(count: nodes, edges: es, resolution: resolution)
            if !moved { break }
            // Renumber communities densely and fold them into one node each.
            var remap: [Int: Int] = [:]
            for c in local where remap[c] == nil { remap[c] = remap.count }
            membership = membership.map { remap[local[$0]]! }
            var agg: [Int64: Double] = [:]
            for (a, b, w) in es {
                // Links inside a community become a self-loop: the merged node keeps its weight.
                let ca = remap[local[a]]!, cb = remap[local[b]]!
                let key = Int64(min(ca, cb)) << 32 | Int64(max(ca, cb))
                agg[key, default: 0] += w
            }
            es = agg.map { (Int($0.key >> 32), Int($0.key & 0xffff_ffff), $0.value) }
            nodes = remap.count
            if nodes <= 1 { break }
        }
        return membership
    }

    private static func localMoving(count n: Int, edges: [(Int, Int, Double)], resolution: Double) -> ([Int], Bool) {
        var adj = Array(repeating: [(Int, Double)](), count: n)
        var k = Array(repeating: 0.0, count: n)
        var m2 = 0.0
        for (a, b, w) in edges {
            if a == b { k[a] += 2 * w; m2 += 2 * w; continue }
            adj[a].append((b, w)); adj[b].append((a, w))
            k[a] += w; k[b] += w; m2 += 2 * w
        }
        guard m2 > 0 else { return (Array(0..<n), false) }
        var comm = Array(0..<n)
        var tot = k
        var movedAny = false
        var weightTo = [Int: Double]()
        for _ in 0..<12 {
            var moved = false
            for i in 0..<n where !adj[i].isEmpty {
                let c = comm[i]
                weightTo.removeAll(keepingCapacity: true)
                for (j, w) in adj[i] { weightTo[comm[j], default: 0] += w }
                tot[c] -= k[i]
                var best = c
                var bestGain = (weightTo[c] ?? 0) - resolution * tot[c] * k[i] / m2
                for (cc, w) in weightTo where cc != c {
                    let gain = w - resolution * tot[cc] * k[i] / m2
                    if gain > bestGain + 1e-12 { bestGain = gain; best = cc }
                }
                tot[best] += k[i]
                if best != c { comm[i] = best; moved = true; movedAny = true }
            }
            if !moved { break }
        }
        return (comm, movedAny)
    }
}
