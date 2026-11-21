import Foundation
import SQLite3

enum NotesAccess { case ok, denied, missing }

struct NotesLibrary: Sendable {
    var notes: [Note]
    var storeUUID: String?
    var diagnostics: [String]
}

enum NotesStoreError: LocalizedError {
    case open(String), query(String)
    var errorDescription: String? {
        switch self {
        case .open(let m): "Couldn't open the Notes database: \(m)"
        case .query(let m): "Reading the Notes database failed: \(m)"
        }
    }
}

/// Reads Apple Notes' private Core Data store. Read-only: NoteMesh works on a copy of
/// the database and never writes to the Notes container.
enum NotesStore {
    static var containerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes")
    }
    static var databaseURL: URL { containerURL.appendingPathComponent("NoteStore.sqlite") }

    static func access() -> NotesAccess {
        let fm = FileManager.default
        do {
            _ = try fm.contentsOfDirectory(atPath: containerURL.path)
        } catch {
            let ns = error as NSError
            if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return .missing }
            return .denied
        }
        guard fm.fileExists(atPath: databaseURL.path) else { return .missing }
        guard let h = try? FileHandle(forReadingFrom: databaseURL) else { return .denied }
        try? h.close()
        return .ok
    }

    /// Latest modification time of the database or its write-ahead log; used to spot edits.
    static func lastChange() -> Date? {
        ["", "-wal"].compactMap { suffix in
            try? FileManager.default.attributesOfItem(atPath: databaseURL.path + suffix)[.modificationDate] as? Date
        }.max()
    }

    /// Copies the live database (plus WAL) somewhere we own so Notes is never locked or touched.
    static func snapshot() throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteMesh/snapshot", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("NoteStore.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: databaseURL.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }

    static func load() throws -> NotesLibrary {
        let copy = try snapshot()
        // The private copy of your notes is only needed while reading it: remove it straight
        // after, so no second copy of your library is left on disk.
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let db = try SQLiteDB(path: copy.path)
        var diag: [String] = []
        let cols = db.columns("ZICCLOUDSYNCINGOBJECT")
        func has(_ c: String) -> Bool { cols.contains(c) }
        diag.append("ZICCLOUDSYNCINGOBJECT columns: \(cols.count)")

        var storeUUID: String?
        try? db.rows("SELECT Z_UUID FROM Z_METADATA LIMIT 1") { storeUUID = $0.string(0) }
        diag.append("store UUID: \(storeUUID ?? "missing")")

        // Folders (rows with ZTITLE2). Folder type 1 is "Recently Deleted".
        var folderNames: [Int64: String] = [:]
        var trash = Set<Int64>()
        if has("ZTITLE2") {
            let type = has("ZFOLDERTYPE") ? "ZFOLDERTYPE" : "0"
            try db.rows("SELECT Z_PK, ZTITLE2, \(type) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE2 IS NOT NULL") { r in
                folderNames[r.int(0)] = r.string(1)
                if r.int(2) == 1 { trash.insert(r.int(0)) }
            }
        }
        diag.append("folders: \(folderNames.count) (trash: \(trash.count))")

        // Inline attachments: #hashtags, note-to-note links, @mentions.
        var inline: [String: (uti: String, alt: String?, token: String?)] = [:]
        let alt = has("ZALTTEXT") ? "ZALTTEXT" : "NULL"
        let token = has("ZTOKENCONTENTIDENTIFIER") ? "ZTOKENCONTENTIDENTIFIER" : "NULL"
        for utiCol in ["ZTYPEUTI1", "ZTYPEUTI"] where has(utiCol) {
            try db.rows("""
                SELECT ZIDENTIFIER, \(utiCol), \(alt), \(token) FROM ZICCLOUDSYNCINGOBJECT
                WHERE \(utiCol) LIKE 'com.apple.notes.inlinetextattachment%'
                """) { r in
                if let id = r.string(0), let uti = r.string(1) { inline[id] = (uti, r.string(2), r.string(3)) }
            }
        }
        diag.append("inline attachments: \(inline.count) (hashtags: \(inline.values.filter { $0.uti.hasSuffix("hashtag") }.count), links: \(inline.values.filter { $0.uti.hasSuffix(".link") }.count))")

        guard has("ZTITLE1"), has("ZIDENTIFIER") else {
            throw NotesStoreError.query("unrecognised schema (no ZTITLE1 column)")
        }
        let mod = ["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"].first(where: has).map { "n.\($0)" } ?? "0"
        let locked = has("ZISPASSWORDPROTECTED") ? "IFNULL(n.ZISPASSWORDPROTECTED, 0)" : "0"
        let alive = has("ZMARKEDFORDELETION") ? "IFNULL(n.ZMARKEDFORDELETION, 0) = 0" : "1"
        let folder = has("ZFOLDER") ? "n.ZFOLDER" : "NULL"
        let join = has("ZNOTEDATA") ? "d.Z_PK = n.ZNOTEDATA" : "d.ZNOTE = n.Z_PK"
        let sql = """
            SELECT n.Z_PK, n.ZIDENTIFIER, n.ZTITLE1, \(folder), \(mod), \(locked), d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICNOTEDATA d ON \(join)
            WHERE n.ZTITLE1 IS NOT NULL AND \(alive)
            """

        // Real Notes tags are inline attachments; scanning plain text for "#word" only helps
        // older libraries without them (otherwise it picks up CSS colours and code).
        let scanPlainText = !inline.values.contains { $0.uti.hasSuffix("hashtag") }
        var notes: [Note] = []
        var parsed = 0, failed = 0, lockedCount = 0, rawLinks = 0
        try db.rows(sql) { r in
            guard let id = r.string(1)?.uppercased(), let title = r.string(2) else { return }
            let folderPK: Int64? = r.isNull(3) ? nil : r.int(3)
            if let f = folderPK, trash.contains(f) { return }
            var note = Note(
                id: id, pk: r.int(0), title: title,
                folder: folderPK.flatMap { folderNames[$0] } ?? "Notes",
                modified: Date(timeIntervalSinceReferenceDate: r.double(4)),
                text: "", isLocked: r.int(5) != 0, userTags: [], linkedIDs: [])
            if note.isLocked { lockedCount += 1; return }   // locked notes stay out of the graph entirely
            guard let blob = r.data(6), let body = NoteProto.parse(blob) else {
                failed += 1; notes.append(note); return
            }
            parsed += 1
            note.text = body.text
            var tags = Set<String>(), links = Set<String>()
            for url in body.links { rawLinks += 1; if let u = noteUUID(in: url) { links.insert(u) } }
            for a in body.attachments {
                guard let info = inline[a.id] else { continue }
                if info.uti.hasSuffix("hashtag"), let t = info.alt { tags.insert(normaliseTag(t)) }
                if info.uti.hasSuffix(".link"), let t = info.token, let u = noteUUID(in: t) { links.insert(u) }
            }
            if scanPlainText { for t in plainHashtags(in: body.text) { tags.insert(t) } }
            links.remove(id)
            note.userTags = tags.filter { !$0.isEmpty }.sorted()
            note.linkedIDs = links.sorted()
            notes.append(note)
        }
        let ids = Set(notes.map(\.id))
        let resolved = notes.reduce(0) { $0 + $1.linkedIDs.filter(ids.contains).count }
        diag.append("notes: \(notes.count) (bodies parsed: \(parsed), failed: \(failed), locked: \(lockedCount))")
        diag.append("link runs: \(rawLinks), note links resolved: \(resolved)")
        diag.append("distinct hashtags: \(Set(notes.flatMap(\.userTags)).sorted().joined(separator: ", "))")
        return NotesLibrary(notes: notes, storeUUID: storeUUID, diagnostics: diag)
    }

    // MARK: helpers

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    private static let hashtagRegex = try! NSRegularExpression(pattern: "(?<![\\w#&/])#([A-Za-z][\\w-]{1,40})")

    static func noteUUID(in url: String) -> String? {
        guard url.lowercased().hasPrefix("applenotes:") || url.lowercased().hasPrefix("notes:") else { return nil }
        let ns = url as NSString
        guard let m = uuidRegex.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range).uppercased()
    }

    static func plainHashtags(in text: String) -> [String] {
        let ns = text as NSString
        return hashtagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { normaliseTag(ns.substring(with: $0.range(at: 1))) }
            .filter { !($0.count == 3 || $0.count == 6) || !$0.allSatisfy(\.isHexDigit) }
    }

    static func normaliseTag(_ t: String) -> String {
        t.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines)).lowercased()
    }
}

/// Minimal read-only SQLite wrapper.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw NotesStoreError.open(message)
        }
    }
    deinit { sqlite3_close(db) }

    func rows(_ sql: String, _ body: (Row) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw NotesStoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { try body(Row(st: st)) }
    }

    func columns(_ table: String) -> Set<String> {
        var out = Set<String>()
        try? rows("PRAGMA table_info(\(table))") { if let c = $0.string(1) { out.insert(c) } }
        return out
    }

    struct Row {
        let st: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_NULL }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
        func string(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(st, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
        }
    }
}
