import Foundation

struct BuildResult: Sendable {
    var payload: GraphPayload
    var tags: [TagInfo]
    var adjacency: [String: [Edge]]
    var newEmbeddings: [(Note, [Float])]
    var stats: String
}

/// Turns notes + cached intelligence into the graph: explicit links, your #tags,
/// topics (Apple Intelligence, or keywords as a fallback) and nearest-neighbour similarity.
enum GraphBuilder {
    static let similarPerNote = 5

    static func build(notes: [Note], cache: IndexCache, useAI: Bool = true) -> BuildResult {
        let ids = Set(notes.map(\.id))
        var nodes: [GraphNode] = []
        var links: [GraphLink] = []
        var adjacency: [String: [Edge]] = [:]
        func connect(_ a: String, _ b: String, _ kind: String, w: Double = 1, rank: Int = 0) {
            links.append(GraphLink(source: a, target: b, kind: kind, w: w, rank: rank))
            adjacency[a, default: []].append(Edge(other: b, kind: kind, w: w))
            adjacency[b, default: []].append(Edge(other: a, kind: kind, w: w))
        }

        // Folders, biggest first, drive the colour palette.
        var folderCounts: [String: Int] = [:]
        for n in notes { folderCounts[n.folder, default: 0] += 1 }
        let groups = folderCounts.keys.sorted { (folderCounts[$0]!, $1) > (folderCounts[$1]!, $0) }

        // What sort of note each one is. Only colours the node; it never creates hubs or links,
        // so the layout stays about content.
        let profiles = NoteCategory.analyse(notes, ai: { useAI ? cache.category(for: $0) : nil })
        let categories = profiles.categories
        for n in notes {
            nodes.append(GraphNode(id: n.id, kind: "note", label: n.title.isEmpty ? "Untitled" : n.title,
                                   group: n.folder, count: 0, snippet: n.isLocked ? "🔒 Locked note" : n.snippet, source: nil,
                                   category: categories[n.id] ?? "note"))
        }

        // 1. Explicit note → note links (deduplicated, either direction).
        var seenPairs = Set<String>()
        var explicit = 0
        for n in notes {
            for t in n.linkedIDs where ids.contains(t) && t != n.id {
                let key = n.id < t ? n.id + "|" + t : t + "|" + n.id
                if seenPairs.insert(key).inserted { connect(n.id, t, "notelink"); explicit += 1 }
            }
        }

        // 1b. Notes that mention a person or entity profile link to it.
        var mentionCount = 0
        for m in profiles.mentions where ids.contains(m.profile) {
            let key = m.note < m.profile ? m.note + "|" + m.profile : m.profile + "|" + m.note
            if seenPairs.insert(key).inserted { connect(m.note, m.profile, "link"); mentionCount += 1 }
        }

        // 2. Your own #tags.
        var userTagNotes: [String: [String]] = [:]
        for n in notes { for t in n.userTags { userTagNotes[t, default: []].append(n.id) } }
        var tagInfos: [TagInfo] = []
        for (tag, members) in userTagNotes {
            let id = "tag:" + tag
            nodes.append(GraphNode(id: id, kind: "tag", label: "#" + tag, group: "tag", count: members.count, snippet: nil, source: nil))
            tagInfos.append(TagInfo(id: id, name: "#" + tag, kind: "tag", count: members.count))
            for m in members { connect(m, id, "tag") }
        }

        // 3. Topics: Apple Intelligence where cached, keywords otherwise.
        var rawTopics: [String: [String]] = [:]   // note id → topics
        var topicSource: [String: String] = [:]    // note id → "ai" | "keywords"
        var aiCounts: [String: Int] = [:]
        for n in notes {
            if useAI, let t = cache.topics(for: n), !t.isEmpty {
                rawTopics[n.id] = t; topicSource[n.id] = "ai"
                for x in t { aiCounts[x, default: 0] += 1 }
            }
        }
        let canonical = TagMerge.canonicalMap(aiCounts)
        let keywordTopics = keywordFallback(notes.filter { rawTopics[$0.id] == nil && !$0.isLocked })
        for (id, t) in keywordTopics { rawTopics[id] = t; topicSource[id] = "keywords" }

        var topicNotes: [String: Set<String>] = [:]
        for (noteID, ts) in rawTopics {
            for t in ts { topicNotes[canonical[t] ?? t, default: []].insert(noteID) }
        }
        var topicCount = 0
        for (topic, members) in topicNotes {
            // A topic only earns a node if it actually connects notes.
            guard members.count >= 2 else { continue }
            let id = "topic:" + topic
            let aiShare = members.filter { topicSource[$0] == "ai" }.count
            let source = aiShare * 2 >= members.count ? "ai" : "keywords"
            nodes.append(GraphNode(id: id, kind: "topic", label: topic, group: "topic", count: members.count, snippet: nil, source: source))
            tagInfos.append(TagInfo(id: id, name: topic, kind: "topic", count: members.count))
            for m in members.sorted() { connect(m, id, "topic") }
            topicCount += 1
        }

        // 4. Similar notes: TF-IDF word overlap blended with a mean-centred sentence embedding.
        var newEmbeddings: [(Note, [Float])] = []
        let simNotes = notes.filter { !$0.isLocked && ($0.text.count + $0.title.count) > 25 }
        var vectors: [[Float]?] = []
        for n in simNotes {
            if let v = cache.embedding(for: n) { vectors.append(v) }
            else if let v = Embeddings.vector(for: n) { vectors.append(v); newEmbeddings.append((n, v)) }
            else { vectors.append(nil) }
        }
        let semantic = Embeddings.centredSimilarity(vectors)
        let lexical = LexicalSimilarity.scores(simNotes.map { KeywordCache.shared.terms(for: $0).words })
        var similarPairs: [String: (Int, Float)] = [:]
        for i in simNotes.indices {
            var row: [(Int, Float)] = []
            for j in simNotes.indices where j != i {
                let lex = lexical[i][j] ?? 0
                let sem = max(0, semantic(i, j))
                let score = 0.7 * lex + 0.3 * sem
                if score > 0.12 { row.append((j, score)) }
            }
            row.sort { $0.1 > $1.1 }
            for (rank, (j, score)) in row.prefix(similarPerNote).enumerated() {
                let a = simNotes[i].id, b = simNotes[j].id
                let key = a < b ? a + "|" + b : b + "|" + a
                if let existing = similarPairs[key], existing.0 <= rank { continue }
                similarPairs[key] = (rank, score)
            }
        }
        for (key, (rank, score)) in similarPairs where !seenPairs.contains(key) {
            let parts = key.split(separator: "|").map(String.init)
            connect(parts[0], parts[1], "similar", w: Double(score), rank: rank)
        }

        // 5. One node per person or entity: profile notes with the same title (three notes called
        //    "Alex") fold into the fullest one, and everything that pointed at them points there.
        let alias = profileAliases(notes: notes, categories: categories)
        if !alias.isEmpty {
            var mergedInto: [String: [String]] = [:]
            for (dup, canon) in alias { mergedInto[canon, default: []].append(dup) }
            let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            nodes = nodes.compactMap { n in
                if alias[n.id] != nil { return nil }
                guard let dups = mergedInto[n.id] else { return n }
                var m = n
                m.merged = dups.sorted()
                if (m.snippet ?? "").isEmpty, let s = dups.compactMap({ byID[$0]?.snippet }).first(where: { !$0.isEmpty }) {
                    m = GraphNode(id: m.id, kind: m.kind, label: m.label, group: m.group, count: m.count, snippet: s,
                                  source: m.source, category: m.category, merged: m.merged)
                }
                return m
            }
            var best: [String: GraphLink] = [:]
            for l in links {
                let a = alias[l.source] ?? l.source, b = alias[l.target] ?? l.target
                guard a != b else { continue }
                let key = (a < b ? a + "|" + b : b + "|" + a) + "|" + l.kind
                let moved = GraphLink(source: a, target: b, kind: l.kind, w: l.w, rank: l.rank)
                if let e = best[key], e.w >= l.w { continue }
                best[key] = moved
            }
            links = best.values.sorted { ($0.source, $0.target, $0.kind) < ($1.source, $1.target, $1.kind) }
            adjacency = [:]
            for l in links {
                adjacency[l.source, default: []].append(Edge(other: l.target, kind: l.kind, w: l.w))
                adjacency[l.target, default: []].append(Edge(other: l.source, kind: l.kind, w: l.w))
            }
        }

        tagInfos.sort { ($0.count, $1.name) > ($1.count, $0.name) }
        let stats = "\(notes.count) notes · \(explicit) links · \(mentionCount) mentions · \(userTagNotes.count) tags · \(topicCount) topics · \(similarPairs.count) similar pairs"
        return BuildResult(payload: GraphPayload(nodes: nodes, links: links, groups: groups),
                           tags: tagInfos, adjacency: adjacency, newEmbeddings: newEmbeddings, stats: stats)
    }

    /// Duplicate profile note → the profile it folds into. Same type and same title (ignoring
    /// case and spacing); the note with the most text wins, then the most recently edited.
    static func profileAliases(notes: [Note], categories: [String: String]) -> [String: String] {
        var groups: [String: [Note]] = [:]
        for n in notes {
            guard let c = categories[n.id], c == "person" || c == "entity" else { continue }
            let key = c + "|" + n.title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard key.count > c.count + 1 else { continue }
            groups[key, default: []].append(n)
        }
        var alias: [String: String] = [:]
        for (_, g) in groups where g.count > 1 {
            let canon = g.max { ($0.text.count, $0.modified) < ($1.text.count, $1.modified) }!
            for n in g where n.id != canon.id { alias[n.id] = canon.id }
        }
        return alias
    }

    /// TF-IDF over nouns/entities; keeps up to 3 terms per note that are shared by a few other notes.
    static func keywordFallback(_ notes: [Note]) -> [String: [String]] {
        guard notes.count > 2 else { return [:] }
        let all = notes.map { KeywordCache.shared.terms(for: $0) }
        // A topic is an ordinary word: something you also write in lowercase somewhere, and not
        // a name the tagger recognised. That keeps names like "Alex" and "Acme" out.
        var lowercase = Set<String>(), names = Set<String>()
        for t in all { lowercase.formUnion(t.lowercaseWords.map { $0.lowercased() }); names.formUnion(t.people); names.formUnion(t.orgs) }
        let terms = all.map { $0.topics.filter { lowercase.contains($0.key) && !names.contains($0.key) } }
        var df: [String: Int] = [:]
        for t in terms { for k in t.keys { df[k, default: 0] += 1 } }
        let n = Double(notes.count)
        let maxDF = max(3, Int(n * 0.12))
        var out: [String: [String]] = [:]
        for (i, note) in notes.enumerated() {
            let scored = terms[i].compactMap { (term, tf) -> (String, Double)? in
                guard let d = df[term], d >= 2, d <= maxDF else { return nil }
                return (term, Double(tf).squareRoot() * log(n / Double(d)))
            }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
            let top = scored.prefix(3).map(\.0)
            if !top.isEmpty { out[note.id] = top }
        }
        return out
    }
}
