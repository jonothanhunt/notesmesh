import Foundation
import FoundationModels
import NaturalLanguage
import Accelerate

// MARK: - Apple Intelligence topic tagging

/// Tags notes with short topics using the on-device Foundation Models "content tagging" model.
/// Uses a runtime GenerationSchema (no @Generable macro) so it builds with the Command Line Tools.
final class AITagger: @unchecked Sendable {
    private let model = SystemLanguageModel(useCase: .contentTagging)

    private lazy var schema: GenerationSchema? = try? GenerationSchema(
        root: DynamicGenerationSchema(name: "NoteTopics", properties: [
            .init(name: "topics",
                  description: "2 to 5 short topics, 1 to 3 words each, lowercase",
                  schema: DynamicGenerationSchema(
                      arrayOf: DynamicGenerationSchema(type: String.self),
                      minimumElements: 1, maximumElements: 5)),
            .init(name: "kind",
                  description: "person only if the note is a profile of one person (things to remember about them); organisation only if it is a profile of a company, client or brand; otherwise note. Meetings, catch-ups and chats with someone are note.",
                  schema: DynamicGenerationSchema(name: "Kind", anyOf: ["person", "organisation", "note"]))
        ]),
        dependencies: [])

    /// Device management (an organisation's restrictions profile) has switched Apple
    /// Intelligence off. macOS then reports "model not ready" for ever, so we check directly.
    static var isRestrictedByOrganisation: Bool {
        let v = CFPreferencesCopyAppValue("_isAppleIntelligenceRestricted" as CFString, "com.apple.applicationaccess" as CFString)
        return (v as? Bool) == true
    }

    /// The model exists for this Mac but hasn't finished downloading yet.
    var isDownloading: Bool {
        if Self.isRestrictedByOrganisation { return false }
        if case .unavailable(.modelNotReady) = model.availability { return true }
        return false
    }

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// Why Apple Intelligence can't be used on this Mac right now (nil when it can).
    enum Blocker: Equatable { case downloading, restricted, notEnabled, unsupported, other }
    var blocker: Blocker? {
        if isAvailable { return nil }
        if Self.isRestrictedByOrganisation { return .restricted }
        switch model.availability {
        case .unavailable(.modelNotReady): return .downloading
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.deviceNotEligible): return .unsupported
        default: return .other
        }
    }

    var statusText: String {
        if !isAvailable && Self.isRestrictedByOrganisation { return "Apple Intelligence is turned off by your organisation" }
        switch model.availability {
        case .available: return "Apple Intelligence ready"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off"
        case .unavailable(.modelNotReady): return "Apple Intelligence model is still downloading"
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence"
        case .unavailable: return "Apple Intelligence unavailable"
        }
    }

    private static let instructions = """
        You organise a personal notes library into a knowledge graph. \
        For each note, give 2 to 5 short topics (1 to 3 words, lowercase) describing what it is about. \
        Topics should be general enough that related notes share them: prefer "home automation" over "zigbee bulb pairing". \
        When an existing topic fits, reuse it exactly. Never use generic topics like "note", "notes", "list" or "misc". \
        Also say whether the note is a profile of a person, a profile of an organisation, or a general note. \
        A meeting or catch-up with someone is a general note.
        """

    struct Result: Sendable { var topics: [String]; var category: String? }

    func tags(title: String, text: String, vocabulary: [String]) async throws -> Result {
        guard let schema else { return Result(topics: [], category: nil) }
        do {
            return try await ask(title: title, text: String(text.prefix(3500)), vocabulary: vocabulary, schema: schema)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await ask(title: title, text: String(text.prefix(1200)), vocabulary: Array(vocabulary.prefix(25)), schema: schema)
        }
    }

    private func ask(title: String, text: String, vocabulary: [String], schema: GenerationSchema) async throws -> Result {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        var prompt = ""
        if !vocabulary.isEmpty { prompt += "Existing topics: \(vocabulary.joined(separator: ", "))\n\n" }
        prompt += "Title: \(title)\n\n\(text)"
        let response = try await session.respond(
            to: prompt, schema: schema, options: GenerationOptions(temperature: 0.2))
        let topics = try response.content.value([String].self, forProperty: "topics")
        let kind = try? response.content.value(String.self, forProperty: "kind")
        let category = kind.map { $0 == "organisation" ? "entity" : $0 }.flatMap { NoteCategory.all.contains($0) ? $0 : nil }
        return Result(topics: TagMerge.clean(topics), category: category)
    }
}

// MARK: - Keyword fallback (no Apple Intelligence needed)

/// Extracts, per note, topic candidates (nouns + named entities) and content lemmas
/// (nouns, verbs, adjectives) used for TF-IDF similarity. Cached by note id + modified date.
struct NoteTerms: Sendable {
    var topics: [String: Int] = [:]
    var words: [String: Int] = [:]
    var people: Set<String> = []   // personal names the tagger found in context
    var orgs: Set<String> = []     // organisation names the tagger found in context
    var tokens: Set<String> = []   // every lowercased word, for name mentions
    var lowercaseWords: Set<String> = []   // words written in lowercase somewhere ("garden", not "Garden")
}

final class KeywordCache: @unchecked Sendable {
    static let shared = KeywordCache()
    private var store: [String: (Date, NoteTerms)] = [:]
    private let lock = NSLock()

    func clear() { lock.lock(); store.removeAll(); lock.unlock() }

    func terms(for note: Note) -> NoteTerms {
        lock.lock(); defer { lock.unlock() }
        if let (date, terms) = store[note.id], date == note.modified { return terms }
        let terms = Self.extract(note.title + "\n" + note.text.prefix(6000))
        store[note.id] = (note.modified, terms)
        return terms
    }

    static let stopwords: Set<String> = [
        "thing", "time", "way", "lot", "day", "week", "today", "tomorrow", "yesterday", "note", "list", "idea",
        "stuff", "something", "anything", "everything", "nothing", "people", "person", "year", "month", "part", "bit", "kind",
        "sort", "point", "use", "need", "one", "two", "three", "item", "todo", "http", "https", "www",
        "com", "etc", "version", "hour", "minute", "second", "morning", "evening", "night", "weekend", "monday", "tuesday",
        "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december", "check", "test", "plan", "start", "end", "number", "place",
        "line", "side", "top", "back", "front", "body", "request", "work", "help", "good", "great", "new",
        "old", "big", "small", "first", "last", "next", "make", "get", "go", "take", "put", "set",
        "try", "want", "look", "see", "know", "think", "be", "have", "do", "say", "come", "give",
        "keep", "let", "feel", "tip", "step", "level", "quarter", "rest", "record", "data", "fast", "slow",
        "every", "other", "more", "most", "less", "able",
    ]

    static func extract(_ text: String) -> NoteTerms {
        var out = NoteTerms()
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .lemma])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        // Named entities, multi-word names kept together.
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let t = text[r].lowercased()
                if tag == .personalName { out.people.insert(t) }
                if tag == .organizationName { out.orgs.insert(t) }
                // Names help similarity, but people and companies are nodes of their own, never topics.
                if t.count >= 3 { out.words[t, default: 0] += 2 }
            }
            return true
        }
        let rawWords = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        out.tokens = Set(rawWords.map { $0.lowercased() })
        out.lowercaseWords = Set(rawWords.filter { $0.first?.isLowercase == true }.map(String.init))
        // Lemmatised nouns (topic candidates) plus verbs/adjectives (similarity only).
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, r in
            guard let tag, [.noun, .verb, .adjective].contains(tag) else { return true }
            let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? String(text[r])
            let t = lemma.lowercased()
            guard t.count >= 3, t.count <= 24, t.allSatisfy({ $0.isLetter || $0 == "-" }), !stopwords.contains(t) else { return true }
            out.words[t, default: 0] += 1
            if tag == .noun { out.topics[t, default: 0] += 1 }
            return true
        }
        return out
    }
}

/// Sparse TF-IDF cosine similarity between notes, via an inverted index.
enum LexicalSimilarity {
    static func scores(_ terms: [[String: Int]]) -> [[Int: Float]] {
        let n = terms.count
        guard n > 1 else { return Array(repeating: [:], count: n) }
        var df: [String: Int] = [:]
        for t in terms { for k in t.keys { df[k, default: 0] += 1 } }
        let maxDF = max(2, Int(Double(n) * 0.25))
        var vectors: [[String: Float]] = []
        for t in terms {
            var v: [String: Float] = [:]
            for (k, tf) in t { guard let d = df[k], d >= 2, d <= maxDF else { continue }
                v[k] = (1 + log(Float(tf))) * log(Float(n) / Float(d)) }
            let norm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { for k in v.keys { v[k]! /= norm } }
            vectors.append(v)
        }
        var postings: [String: [(Int, Float)]] = [:]
        for (i, v) in vectors.enumerated() { for (k, w) in v { postings[k, default: []].append((i, w)) } }
        var out = Array(repeating: [Int: Float](), count: n)
        for list in postings.values where list.count > 1 {
            for a in 0..<list.count { for b in (a + 1)..<list.count {
                let (i, wi) = list[a], (j, wj) = list[b]
                out[i][j, default: 0] += wi * wj
                out[j][i, default: 0] += wi * wj
            } }
        }
        return out
    }
}

// MARK: - Sentence embeddings for "similar note" links

enum Embeddings {
    private static let model = NLEmbedding.sentenceEmbedding(for: .english)
    private static let lock = NSLock()

    static var isAvailable: Bool { model != nil }

    static func vector(for note: Note) -> [Float]? {
        vector(for: note.title + ". " + note.snippet + " " + note.text.prefix(800))
    }

    static func vector(for text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let model, let v = model.vector(for: text) else { return nil }
        var f = v.map(Float.init)
        var norm: Float = 0
        vDSP_svesq(f, 1, &norm, vDSP_Length(f.count))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        vDSP_vsdiv(f, 1, &norm, &f, 1, vDSP_Length(f.count))
        return f
    }

    /// Cosine similarity after subtracting the corpus mean vector. Sentence embeddings are
    /// anisotropic (everything looks similar); centring spreads the scores out.
    static func centredSimilarity(_ vectors: [[Float]?]) -> (Int, Int) -> Float {
        let present = vectors.compactMap { $0 }
        guard let d = present.first?.count, present.count > 2 else { return { _, _ in 0 } }
        var mean = [Float](repeating: 0, count: d)
        for v in present { vDSP_vadd(mean, 1, v, 1, &mean, 1, vDSP_Length(d)) }
        var div = Float(present.count)
        vDSP_vsdiv(mean, 1, &div, &mean, 1, vDSP_Length(d))
        let centred: [[Float]?] = vectors.map { v in
            guard let v else { return nil }
            var c = [Float](repeating: 0, count: d)
            vDSP_vsub(mean, 1, v, 1, &c, 1, vDSP_Length(d))
            var norm: Float = 0
            vDSP_svesq(c, 1, &norm, vDSP_Length(d))
            norm = sqrt(norm)
            guard norm > 0 else { return nil }
            vDSP_vsdiv(c, 1, &norm, &c, 1, vDSP_Length(d))
            return c
        }
        return { i, j in
            guard let a = centred[i], let b = centred[j] else { return 0 }
            var dot: Float = 0
            vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(d))
            return dot
        }
    }
}

// MARK: - Keeping topics consistent

enum TagMerge {
    static let banned: Set<String> = ["note", "notes", "misc", "miscellaneous", "list", "lists", "general", "other", "personal note"]

    static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let t = raw.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#.,;:\"'").union(.whitespacesAndNewlines))
                .split(separator: " ").joined(separator: " ")
            guard t.count >= 2, t.count <= 32, !banned.contains(t), seen.insert(t).inserted else { return nil }
            return t
        }
    }

    /// Maps every topic to a canonical spelling: plurals fold into singulars, and near-identical
    /// topics (by embedding similarity) fold into whichever is used more.
    static func canonicalMap(_ counts: [String: Int]) -> [String: String] {
        var map: [String: String] = [:]
        let byFrequency = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        for t in byFrequency {
            if t.hasSuffix("s"), counts[String(t.dropLast())] != nil { map[t] = String(t.dropLast()) }
        }
        let remaining = byFrequency.filter { map[$0] == nil }
        if remaining.count > 1, remaining.count <= 3000, Embeddings.isAvailable {
            let vecs = remaining.map { Embeddings.vector(for: $0) }
            for (i, t) in remaining.enumerated() where map[t] == nil {
                guard let vi = vecs[i] else { continue }
                for j in 0..<i {
                    let other = remaining[j]
                    guard map[other] == nil, let vj = vecs[j] else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(vi, 1, vj, 1, &dot, vDSP_Length(vi.count))
                    if dot > 0.93 { map[t] = other; break }
                }
            }
        }
        // Resolve chains.
        func root(_ t: String) -> String { var r = t; var hops = 0; while let n = map[r], n != r, hops < 8 { r = n; hops += 1 }; return r }
        var out: [String: String] = [:]
        for t in counts.keys { out[t] = root(t) }
        return out
    }
}

// MARK: - Persistent index (AI topics + embeddings), keyed by note id + modification date

struct IndexCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var modified: Double
        var topics: [String]?
        var category: String?
        var embedding: Data?
    }
    var entries: [String: Entry] = [:]

    static func url(demo: Bool) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteMesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(demo ? "index-demo.json" : "index.json")
    }

    static func load(demo: Bool) -> IndexCache {
        guard let data = try? Data(contentsOf: url(demo: demo)),
              let cache = try? JSONDecoder().decode(IndexCache.self, from: data) else { return IndexCache() }
        return cache
    }

    func save(demo: Bool) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url(demo: demo), options: .atomic) }
    }

    private func entry(_ note: Note) -> Entry? {
        guard let e = entries[note.id], e.modified == note.modified.timeIntervalSinceReferenceDate else { return nil }
        return e
    }
    private mutating func update(_ note: Note, _ change: (inout Entry) -> Void) {
        var e = entry(note) ?? Entry(modified: note.modified.timeIntervalSinceReferenceDate)
        change(&e)
        entries[note.id] = e
    }

    func topics(for note: Note) -> [String]? { entry(note)?.topics }
    func category(for note: Note) -> String? { entry(note)?.category }
    mutating func setTopics(_ topics: [String], category: String? = nil, for note: Note) {
        update(note) { $0.topics = topics; $0.category = category }
    }

    func embedding(for note: Note) -> [Float]? {
        guard let data = entry(note)?.embedding else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    mutating func setEmbedding(_ v: [Float], for note: Note) {
        update(note) { $0.embedding = v.withUnsafeBufferPointer { Data(buffer: $0) } }
    }

    /// Most-used topics so far, fed back into the prompt so the model reuses them.
    func vocabulary(limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for e in entries.values { for t in e.topics ?? [] { counts[t, default: 0] += 1 } }
        return counts.filter { $0.value >= 1 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key)
    }

    mutating func prune(keeping ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }
}
