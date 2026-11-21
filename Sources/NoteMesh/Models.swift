import Foundation

/// One Apple Note, as read from NoteStore.sqlite (or the demo library).
struct Note: Identifiable, Hashable, Sendable {
    let id: String          // ZIDENTIFIER (uppercase UUID)
    let pk: Int64           // Z_PK, used to build the AppleScript x-coredata id
    var title: String
    var folder: String
    var modified: Date
    var text: String
    var isLocked: Bool
    var userTags: [String]  // lowercase, without "#"
    var linkedIDs: [String] // identifiers of notes this note links to

    var snippet: String {
        var body = text
        if let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
           firstLine.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
            body = String(body.dropFirst(firstLine.count))
        }
        let collapsed = body.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 220 ? String(collapsed.prefix(220)) + "…" : collapsed
    }
}

// MARK: - Graph payload sent to the web view

struct GraphNode: Codable, Hashable, Sendable {
    let id: String
    let kind: String      // "note" | "tag" | "topic"
    let label: String
    let group: String     // folder for notes, kind for tags
    let count: Int        // number of notes for tags, 0 for notes
    let snippet: String?
    let source: String?   // for topics: "ai" | "keywords"
    var category: String? = nil   // for notes: "person" | "entity" | "note"
    var merged: [String]? = nil   // for profiles: other notes with the same title, folded into this node
}

struct GraphLink: Codable, Hashable, Sendable {
    let source: String
    let target: String
    let kind: String      // "notelink" (your >> links) | "link" (mentions) | "tag" | "topic" | "similar"
    let w: Double         // similarity score for "similar", 1 otherwise
    let rank: Int         // nearest-neighbour rank for "similar", 0 otherwise
}

struct GraphPayload: Codable, Sendable {
    var nodes: [GraphNode]
    var links: [GraphLink]
    var groups: [String]  // folders, most notes first (drives the colour palette)
}

struct Edge: Hashable, Sendable {
    let other: String
    let kind: String
    let w: Double
}

struct TagInfo: Identifiable, Hashable, Sendable {
    let id: String        // node id, e.g. "tag:work" or "topic:home automation"
    let name: String
    let kind: String      // "tag" | "topic"
    let count: Int
}
