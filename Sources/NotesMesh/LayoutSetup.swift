import Foundation

/// Sets up the force layout for a graph: charges, springs, islands (Louvain communities) and
/// optional folder regions. Shared by the Metal view and the headless `--layout` tool.
enum LayoutSetup {
    struct Edge { let s: Int, t: Int, kind: String, w: Double }
    struct Result { var folderNames: [String]; var folderOf: [Int]; var groups: [Int]; var looseGroups: Set<Int> }

    struct Tuning {
        var groupPull = 0.18, groupGap = 2.0
        var betweenStrength = 0.1, betweenDistance = 2.6
        var anchorPull = 0.08
    }
    static var tuning = Tuning()

    static func configure(_ sim: ForceSim, isHub: [Bool], folder: [String], edges: [Edge],
                          islands: Bool, byFolder: Bool) -> Result {
        let n = isHub.count
        let t = tuning

        // Folders: each note's folder (hubs have none), largest first.
        var folderSize: [String: Int] = [:]
        for i in 0..<n where !isHub[i] { folderSize[folder[i], default: 0] += 1 }
        let folderNames = folderSize.keys.sorted { (folderSize[$0]!, $1) > (folderSize[$1]!, $0) }
        let folderIndex = Dictionary(uniqueKeysWithValues: folderNames.enumerated().map { ($1, $0) })
        let folderOf = (0..<n).map { isHub[$0] ? -1 : (folderIndex[folder[$0]] ?? -1) }
        let cross = { (e: Edge) -> Bool in
            byFolder && folderOf[e.s] >= 0 && folderOf[e.t] >= 0 && folderOf[e.s] != folderOf[e.t]
        }

        // Islands: Louvain communities. In folder mode, links across folders barely count.
        let weight: [String: Double] = ["notelink": 1.2, "link": 1.0, "topic": 0.5, "tag": 0.3, "similar": 1.0]
        var community = Communities.louvain(count: n, edges: edges.map { e in
            var w = (weight[e.kind] ?? 0.3) * (e.kind == "similar" ? e.w * 1.5 : 1)
            if cross(e) { w *= 0.1 }
            return (e.s, e.t, w)
        })
        var size: [Int: Int] = [:]
        for c in community { size[c, default: 0] += 1 }
        // Notes with nothing in common with anything gather per folder, rather than drifting
        // out into a ring around the graph.
        var degree = [Int](repeating: 0, count: n)
        for e in edges { degree[e.s] += 1; degree[e.t] += 1 }
        community = community.enumerated().map { i, c in
            if size[c, default: 0] >= 3 { return c }
            return degree[i] == 0 && folderOf[i] >= 0 ? -(folderOf[i] + 2) : -1   // "loose notes" group per folder
        }
        let keys = Set(community.filter { $0 != -1 }).sorted()
        let ids = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let groups = community.map { $0 == -1 ? -1 : ids[$0]! }

        sim.charge = isHub.map { $0 ? -150 : -46 }
        sim.group = groups
        sim.groupPull = islands ? t.groupPull : 0
        sim.groupGap = t.groupGap

        // Folder anchors on a ring.
        if byFolder && folderNames.count > 1 {
            let ring = 22 * Double(n).squareRoot()
            let anchors = folderNames.indices.map { k -> (Double, Double) in
                let a = Double(k) / Double(folderNames.count) * 2 * .pi - .pi / 2
                return (cos(a) * ring, sin(a) * ring)
            }
            sim.anchorX = folderOf.map { $0 >= 0 ? anchors[$0].0 : .nan }
            sim.anchorY = folderOf.map { $0 >= 0 ? anchors[$0].1 : .nan }
            sim.anchorPull = t.anchorPull
        } else {
            sim.anchorX = []; sim.anchorY = []; sim.anchorPull = 0
        }

        let distance: [String: Double] = ["notelink": 36, "link": 40, "tag": 70, "topic": 60, "similar": 76]
        let strength: [String: Double] = ["notelink": 0.8, "link": 0.7, "tag": 0.12, "topic": 0.3, "similar": 0.08]
        sim.setLinks(edges.map { e in
            // Links between islands are longer and weaker, so islands keep some sea between them.
            let between = islands && (groups[e.s] != groups[e.t] || groups[e.s] < 0)
            let soften = (between ? t.betweenStrength : 1) * (cross(e) ? 0.2 : 1)
            return ForceSim.Link(s: e.s, t: e.t, distance: (distance[e.kind] ?? 55) * (between ? t.betweenDistance : 1),
                                 strength: (strength[e.kind] ?? 0.2) * (e.kind == "similar" ? max(0.4, e.w) : 1) * soften)
        })
        let loose = Set(keys.filter { $0 < -1 }.map { ids[$0]! })
        return Result(folderNames: folderNames, folderOf: folderOf, groups: groups, looseGroups: loose)
    }
}
