import Foundation
import AppKit

/// Owns the notes, the cache and the background work (loading, AI tagging, watching for edits).
@MainActor
final class Indexer: ObservableObject {
    enum State: Equatable { case idle, needsAccess, loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    /// Why your own notes aren't showing yet (sample notes show instead); nil once connected.
    enum Connect: Equatable { case needsAccess, noLibrary, failed(String) }
    @Published private(set) var connect: Connect?
    private var accessTimer: Timer?
    @Published private(set) var notes: [Note] = []
    @Published private(set) var notesByID: [String: Note] = [:]
    @Published private(set) var payload: GraphPayload?
    @Published private(set) var payloadVersion = 0
    @Published private(set) var tags: [TagInfo] = []
    @Published private(set) var adjacency: [String: [Edge]] = [:]
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var stats = ""
    @Published var benchRequested = false
    /// note id → "person" | "entity" | "note"
    @Published private(set) var categories: [String: String] = [:]
    /// Profile notes folded into another with the same title: duplicate id → the node's id,
    /// and node id → the notes folded into it.
    @Published private(set) var alias: [String: String] = [:]
    @Published private(set) var merged: [String: [String]] = [:]
    @Published private(set) var aiStatus = ""
    @Published private(set) var aiProgress: Double?
    @Published private(set) var aiPhase: AIPhase = .unavailable
    @Published private(set) var aiRead = 0
    @Published private(set) var aiTotal = 0
    @Published private(set) var aiSecondsPerNote: Double?
    @Published private(set) var aiPaused = UserDefaults.standard.bool(forKey: "ai.paused")
    /// Where topics and profiles come from: Apple Intelligence (when this Mac has it) or
    /// keywords. Switching only changes what's shown; what Apple Intelligence has already read
    /// stays cached, so switching back is instant.
    @Published private(set) var useAI = UserDefaults.standard.object(forKey: "ai.enabled") as? Bool ?? true

    func setUseAI(_ on: Bool) {
        DebugClicks.log("NMState useAI=\(on)")
        guard on != useAI else { return }
        useAI = on
        UserDefaults.standard.set(on, forKey: "ai.enabled")
        aiTask?.cancel()
        Task { await rebuild(); startTagging() }
    }
    @Published private(set) var isDemo = false
    @Published var showPalette = false
    @Published var confirmReindex = false
    @Published var confirmDeleteData = false

    private(set) var storeUUID: String?
    private var cache = IndexCache()
    private var aiTask: Task<Void, Never>?
    private var availabilityTimer: Timer?
    private var watchTimer: Timer?
    private var lastChange: Date?
    private var loading = false
    private let tagger = AITagger()

    /// Your notes if Notes Mesh can read them; otherwise sample notes, with the drawer showing
    /// how to connect yours. It keeps checking, and swaps in your notes once access is on.
    func start() {
        // `--sample`: only the sample library, never your notes (screenshots, demos, development).
        if CommandLine.arguments.contains("--sample") { load(demo: true); return }
        switch NotesStore.access() {
        case .ok:
            accessTimer?.invalidate(); accessTimer = nil
            if connect != nil { connect = nil; notes = [] }
            load(demo: false)
        case .denied:
            showSamples(because: .needsAccess)
        case .missing:
            showSamples(because: .noLibrary)
        }
    }

    private func showSamples(because reason: Connect) {
        connect = reason
        if !isDemo || notes.isEmpty { load(demo: true) }
        guard accessTimer == nil else { return }
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connect != nil, case .ok = NotesStore.access() else { return }
                if case .failed = self.connect { return }   // a read error waits for Try Again
                self.start()
            }
        }
    }

    /// From the drawer's Try Again.
    func retryConnect() { connect = nil; start() }

    func useDemo() { load(demo: true) }

    func reload() { DebugClicks.log("NMState reload"); load(demo: isDemo) }

    /// Starts over: forgets every topic, profile and embedding and reads the library again
    /// (e.g. after deleting or reorganising lots of notes). Keyword topics fill in meanwhile.
    func reindex() {
        aiTask?.cancel()
        cache = IndexCache()
        cache.save(demo: isDemo)
        KeywordCache.shared.clear()
        load(demo: isDemo)
    }

    private func load(demo: Bool) {
        guard !loading else { return }
        loading = true
        if notes.isEmpty || demo != isDemo { state = .loading }
        if demo != isDemo || cache.entries.isEmpty { cache = IndexCache.load(demo: demo) }
        isDemo = demo
        Task {
            defer { loading = false }
            do {
                let lib: NotesLibrary = try await Task.detached(priority: .userInitiated) {
                    demo ? DemoLibrary.make() : try NotesStore.load()
                }.value
                storeUUID = lib.storeUUID
                notes = lib.notes
                notesByID = Dictionary(lib.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                cache.prune(keeping: Set(notesByID.keys))
                await rebuild()
                if !demo && Self.diagnosticsEnabled {
                    writeDiagnostics(lib.diagnostics + ["graph: \(stats)",
                        "top hubs: " + tags.prefix(25).map { "\($0.name) (\($0.count))" }.joined(separator: ", ")]
                        + ["person", "entity", "note"].map { c in
                            let ns = payload?.nodes.filter { $0.category == c } ?? []
                            return "\(c) \(ns.count): " + ns.prefix(c == "note" ? 15 : 200).map(\.label).joined(separator: " | ")
                        })
                    // A local copy of the graph, handy for previewing the renderer outside the app.
                    let dir = IndexCache.url(demo: false).deletingLastPathComponent()
                    try? JSONEncoder().encode(payload).write(to: dir.appendingPathComponent("graph-snapshot.json"))
                }
                state = .ready
                if CommandLine.arguments.contains("--bench") { benchRequested = true }
                if !demo { lastChange = NotesStore.lastChange(); startWatching() }
                startTagging()
            } catch {
                writeDiagnostics(["load failed: \(error)"])
                if demo { state = .failed(error.localizedDescription) }
                else {
                    // Your library couldn't be read: keep going with sample notes and say so.
                    loading = false
                    showSamples(because: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func rebuild() async {
        let notes = self.notes, cache = self.cache, useAI = self.useAI
        let result = await Task.detached(priority: .userInitiated) {
            GraphBuilder.build(notes: notes, cache: cache, useAI: useAI)
        }.value
        for (note, v) in result.newEmbeddings { self.cache.setEmbedding(v, for: note) }
        if !result.newEmbeddings.isEmpty { self.cache.save(demo: isDemo) }
        payload = result.payload
        tags = result.tags
        adjacency = result.adjacency
        labels = Dictionary(result.payload.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        stats = result.stats
        categories = Dictionary(result.payload.nodes.compactMap { n in n.category.map { (n.id, $0) } }, uniquingKeysWith: { a, _ in a })
        merged = Dictionary(result.payload.nodes.compactMap { n in n.merged.map { (n.id, $0) } }, uniquingKeysWith: { a, _ in a })
        alias = Dictionary(merged.flatMap { canon, dups in dups.map { ($0, canon) } }, uniquingKeysWith: { a, _ in a })
        payloadVersion += 1
    }

    // MARK: Apple Intelligence tagging

    // MARK: Apple Intelligence reading (pausable)

    enum AIPhase: Equatable { case unavailable, waiting, reading, paused, done, off }

    /// Notes Apple Intelligence can read (unlocked, with some text).
    private var aiEligible: [Note] {
        notes.filter { !$0.isLocked && ($0.title.count + $0.text.count) > 20 }
    }

    private func refreshAICounts() {
        let eligible = aiEligible
        aiTotal = eligible.count
        aiRead = eligible.filter { cache.topics(for: $0) != nil }.count
    }

    func pauseTagging() {
        aiPaused = true
        UserDefaults.standard.set(true, forKey: "ai.paused")
        aiTask?.cancel()
        aiTask = nil
        cache.save(demo: isDemo)
        Task { await rebuild() }
        setPhase(.paused)
    }

    func resumeTagging() {
        aiPaused = false
        UserDefaults.standard.set(false, forKey: "ai.paused")
        startTagging()
    }

    /// Why Apple Intelligence isn't in use right now even though it's selected (nil if it is,
    /// or if you chose keywords). Drives the panel's banner and the one-time notice.
    @Published private(set) var aiBlocker: AITagger.Blocker?
    /// Shown once, the first time Notes Mesh has to fall back to keywords.
    @Published var showFallbackNotice = false
    /// Apple Intelligence can't run on this Mac at all (not just "still downloading").
    var aiUnusable: Bool { tagger.blocker.map { $0 != .downloading } ?? false }
    var aiBlockerReason: AITagger.Blocker? { tagger.blocker }

    private func setPhase(_ phase: AIPhase) {
        aiBlocker = useAI ? tagger.blocker : nil
        if aiBlocker != nil, !UserDefaults.standard.bool(forKey: "ai.fallbackNoticeShown") {
            UserDefaults.standard.set(true, forKey: "ai.fallbackNoticeShown")
            showFallbackNotice = true
        }
        aiPhase = phase
        switch phase {
        case .unavailable: aiStatus = "\(tagger.statusText) · topics from keywords"
        case .waiting: aiStatus = "Apple Intelligence model is still downloading · topics from keywords"
        case .reading: aiStatus = "Apple Intelligence is reading your notes · \(aiRead) of \(aiTotal)"
        case .paused: aiStatus = "Apple Intelligence is paused · \(aiRead) of \(aiTotal) notes read"
        case .done: aiStatus = "Topics by Apple Intelligence"
        case .off: aiStatus = "Topics from keywords"
        }
        aiProgress = phase == .reading && aiTotal > 0 ? Double(aiRead) / Double(aiTotal) : nil
    }

    private func startTagging() {
        aiTask?.cancel()
        availabilityTimer?.invalidate()
        refreshAICounts()
        guard useAI else { setPhase(.off); return }
        guard tagger.isAvailable else {
            if tagger.isDownloading {
                setPhase(.waiting)
                // Start by ourselves as soon as the model arrives.
                availabilityTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.tagger.isAvailable else { return }
                        self.availabilityTimer?.invalidate()
                        self.startTagging()
                    }
                }
            } else {
                setPhase(.unavailable)
            }
            return
        }
        let todo = aiEligible.filter { cache.topics(for: $0) == nil }.sorted { $0.modified > $1.modified }
        guard !todo.isEmpty else { setPhase(.done); return }
        guard !aiPaused else { setPhase(.paused); return }

        setPhase(.reading)
        let demo = isDemo
        aiTask = Task { [weak self] in
            var sinceSave = 0
            for note in todo {
                guard let self, !Task.isCancelled else { return }
                let start = Date()
                let vocabulary = self.cache.vocabulary(limit: 60)
                let result: AITagger.Result
                do {
                    result = try await self.tagger.tags(title: note.title, text: note.text, vocabulary: vocabulary)
                } catch {
                    result = .init(topics: [], category: nil)   // e.g. guardrail refusal; cached so we don't retry until edited
                }
                guard !Task.isCancelled else { return }
                self.cache.setTopics(result.topics, category: result.category, for: note)
                // Smoothed seconds per note, for the time-left estimate.
                let dt = Date().timeIntervalSince(start)
                self.aiSecondsPerNote = self.aiSecondsPerNote.map { $0 * 0.85 + dt * 0.15 } ?? dt
                self.aiRead += 1
                self.setPhase(.reading)
                sinceSave += 1
                if sinceSave >= 12 {
                    sinceSave = 0
                    self.cache.save(demo: demo)
                    await self.rebuild()
                }
            }
            guard let self else { return }
            self.cache.save(demo: demo)
            await self.rebuild()
            self.setPhase(.done)
        }
    }

    // MARK: Watching Notes for edits

    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isDemo, !self.loading else { return }
                let change = NotesStore.lastChange()
                if let change, change != self.lastChange {
                    self.lastChange = change
                    self.load(demo: false)
                }
            }
        }
    }

    // MARK: Helpers for the UI

    func label(_ id: String) -> String { labels[id] ?? notesByID[id]?.title ?? id }

    func open(_ id: String) {
        guard let note = notesByID[id] else { return }
        if isDemo {
            let alert = NSAlert()
            alert.messageText = note.title
            alert.informativeText = "This is a demo note. With your real library, this opens the note in Apple Notes."
            alert.runModal()
            return
        }
        if let error = NoteOpener.open(note, storeUUID: storeUUID) {
            let alert = NSAlert()
            alert.messageText = "Couldn't open “\(note.title)” in Notes"
            alert.informativeText = error
            alert.runModal()
        }
    }

    /// Diagnostics include note titles, so they're only written when you ask for them
    /// (`--diagnostics`), e.g. to debug a library that won't load. Otherwise any left over
    /// from an earlier run are removed.
    static let diagnosticsEnabled = CommandLine.arguments.contains("--diagnostics")

    static func removeStaleDiagnostics() {
        // A temporary copy of the Notes database is deleted after each read; this also clears
        // one left behind by a crash or an older version.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("NotesMesh/snapshot"))
        guard !diagnosticsEnabled else { return }
        let dir = IndexCache.url(demo: false).deletingLastPathComponent()
        for f in ["diagnostics.txt", "graph-snapshot.json", "bench.txt"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// Deletes everything Notes Mesh has stored (topics, profiles, embeddings, settings, caches)
    /// and starts again from your notes. Your notes themselves are never touched.
    func deleteAllData() {
        aiTask?.cancel()
        let fm = FileManager.default
        let support = IndexCache.url(demo: false).deletingLastPathComponent()
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotesMesh")
        try? fm.removeItem(at: support)
        try? fm.removeItem(at: caches)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        aiPaused = false
        cache = IndexCache()
        KeywordCache.shared.clear()
        load(demo: isDemo)
    }

    private func writeDiagnostics(_ lines: [String]) {
        let url = IndexCache.url(demo: false).deletingLastPathComponent().appendingPathComponent("diagnostics.txt")
        let text = (["Notes Mesh diagnostics — \(Date())", "AI: \(tagger.statusText)"] + lines).joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum NoteOpener {
    /// Opens a note in Notes via AppleScript (asks for Automation permission once),
    /// falling back to the applenotes: URL scheme.
    @MainActor
    static func open(_ note: Note, storeUUID: String?) -> String? {
        // The store id comes from the Notes database; only a plain UUID is put into the script.
        if let storeUUID, !storeUUID.isEmpty,
           storeUUID.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let source = """
                tell application "Notes"
                    show note id "x-coredata://\(storeUUID)/ICNote/p\(note.pk)"
                    activate
                end tell
                """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error == nil { return nil }
        }
        if let url = URL(string: "applenotes:note/\(note.id)"), NSWorkspace.shared.open(url) {
            return nil
        }
        return "Allow Notes Mesh to control Notes in System Settings → Privacy & Security → Automation."
    }
}
