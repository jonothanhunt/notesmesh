import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        RenameMigration.run()   // before anything touches the app's folders
        let args = CommandLine.arguments
        if args.contains("--layout") {
            LayoutPreview.run(args)
        } else if args.contains("--dump") {
            CLI.run(args)
        } else {
            NotesMeshApp.main()
        }
    }
}

struct NotesMeshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var indexer = Indexer()

    var body: some Scene {
        Window("Notes Mesh", id: "main") {
            ContentView()
                .environmentObject(indexer)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quick Open…") { indexer.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Reload Notes") { indexer.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Rebuild Index…") { indexer.confirmReindex = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Delete Notes Mesh Data…") { indexer.confirmDeleteData = true }
            }
            // No Help book: the Help menu points at the project instead.
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { NSWorkspace.shared.open(Links.feedback) }
                Button("Report a Security Issue…") { NSWorkspace.shared.open(Links.security) }
                Divider()
                Button("Notes Mesh on GitHub") { NSWorkspace.shared.open(Links.repo) }
                Button("Privacy") { NSWorkspace.shared.open(Links.privacy) }
            }
        }
    }
}

/// Where the project lives. Change `repo` if you fork it.
enum Links {
    static let repo = URL(string: "https://github.com/jonothanhunt/notesmesh")!
    static let feedback = repo.appending(path: "issues/new")
    static let security = repo.appending(path: "security/advisories/new")
    static let privacy = repo.appending(path: "blob/main/PRIVACY.md")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Indexer.removeStaleDiagnostics()
        AppAppearance.applySaved()
        if let i = CommandLine.arguments.firstIndex(of: "--click-channel"), i + 1 < CommandLine.arguments.count {
            DebugClicks.start(file: CommandLine.arguments[i + 1])
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `Notes Mesh --dump [--demo] [--ai N] [--out graph.json]`: builds the graph without UI.
enum CLI {
    static func run(_ args: [String]) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await runAsync(args)
            done.signal()
        }
        done.wait()
    }

    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func runAsync(_ args: [String]) async {
        let demo = args.contains("--demo")
        do {
            if !demo && NotesStore.access() != .ok {
                print("No access to the Notes library. Grant Full Disk Access to this process, or pass --demo.")
                return
            }
            let lib = demo ? DemoLibrary.make() : try NotesStore.load()
            lib.diagnostics.forEach { print("·", $0) }
            var cache = IndexCache.load(demo: demo)

            let tagger = AITagger()
            print("AI:", tagger.statusText)
            if let n = value(args, "--ai").flatMap(Int.init), tagger.isAvailable {
                let todo = lib.notes.filter { !$0.isLocked && cache.topics(for: $0) == nil }.prefix(n)
                for (i, note) in todo.enumerated() {
                    let start = Date()
                    let r = (try? await tagger.tags(title: note.title, text: note.text, vocabulary: cache.vocabulary(limit: 60))) ?? .init(topics: [], category: nil)
                    let topics = r.topics
                    cache.setTopics(topics, category: r.category, for: note)
                    print(String(format: "  [%d/%d] %.1fs  %@ → %@", i + 1, todo.count, Date().timeIntervalSince(start), note.title, topics.joined(separator: ", ")))
                }
            }
            let result = GraphBuilder.build(notes: lib.notes, cache: cache)
            for (note, v) in result.newEmbeddings { cache.setEmbedding(v, for: note) }
            cache.save(demo: demo)
            print("graph:", result.stats)
            print("top topics:", result.tags.prefix(15).map { "\($0.name) (\($0.count))" }.joined(separator: ", "))
            let cats = Dictionary(grouping: result.payload.nodes.compactMap(\.category), by: { $0 }).mapValues(\.count)
            print("types:", cats.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            for c in ["person", "entity"] {
                print("  \(c):", result.payload.nodes.filter { $0.category == c }.prefix(12).map(\.label).joined(separator: " | "))
            }
            if let out = value(args, "--out") {
                let data = try JSONEncoder().encode(result.payload)
                try data.write(to: URL(fileURLWithPath: out))
                print("wrote", out)
            }
        } catch {
            print("error:", error.localizedDescription)
        }
    }
}

/// One-off move from the app's old name (NoteMesh) to Notes Mesh: the index and settings carry
/// over, so nothing has to be read again. Safe to run every launch; it only acts once.
enum RenameMigration {
    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("NoteMesh"), new = support.appendingPathComponent("NotesMesh")
        if fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            // Move each file across unless the new folder already has its own copy, then tidy up.
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
                let dest = new.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: old.appendingPathComponent(name), to: dest) }
            }
            try? fm.removeItem(at: old)
        }
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("NoteMesh"))

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromNoteMesh") else { return }
        if let previous = UserDefaults(suiteName: "io.github.jonothanhunt.notemesh")?.persistentDomain(forName: "io.github.jonothanhunt.notemesh") {
            for (key, value) in previous where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromNoteMesh")
    }
}
