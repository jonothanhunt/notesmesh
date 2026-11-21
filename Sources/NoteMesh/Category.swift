import Foundation
import NaturalLanguage

/// Finds profile notes — a note that IS a person ("Sam Taylor", "Alex", "Mum") or an
/// organisation ("Acme", "Northwind") — and the notes that mention them.
///
/// Only profiles are typed person / entity; a "Catch-up with Alex" is a plain note that gets
/// linked to Alex's profile. Apple Intelligence decides when it has read a note; otherwise a
/// title that is nothing but a name is a profile, and how that name is used across all your
/// notes (the tagger sees "with Alex" as a person, "the Acme pitch" as an organisation)
/// decides which kind.
enum NoteCategory {
    static let all: Set<String> = ["person", "entity", "note"]
    private static let family: Set<String> = ["mum", "mom", "mother", "dad", "father", "nan", "nana", "gran", "grandma",
                                              "grandad", "grandpa", "granny", "auntie", "aunt", "uncle"]
    private static let profileTags: Set<String> = ["person", "people", "contact"]
    /// Tags that mark a short-titled note as an organisation's profile.
    private static let orgTags: Set<String> = ["organisation", "organization", "company", "business"]

    struct Result { var categories: [String: String]; var mentions: [(note: String, profile: String)] }

    static func analyse(_ notes: [Note], ai: (Note) -> String?) -> Result {
        // How each name is used across the library.
        var personUse: [String: Int] = [:], orgUse: [String: Int] = [:], lowerUse: [String: Int] = [:]
        var terms: [String: NoteTerms] = [:]
        for n in notes where !n.isLocked {
            let t = KeywordCache.shared.terms(for: n)
            terms[n.id] = t
            for p in t.people { personUse[p, default: 0] += 1 }
            for o in t.orgs { orgUse[o, default: 0] += 1 }
            for w in t.lowercaseWords { lowerUse[w, default: 0] += 1 }
        }

        var categories: [String: String] = [:]
        var aliases: [(profile: String, names: [String])] = []
        for n in notes {
            let c = classify(n, ai: ai(n), personUse: personUse, orgUse: orgUse, lowerUse: lowerUse)
            categories[n.id] = c
            if c != "note" { aliases.append((n.id, names(for: n.title, person: c == "person"))) }
        }

        // Every other note that mentions a profile's name links to it.
        var mentions: [(String, String)] = []
        for n in notes where !n.isLocked {
            guard let t = terms[n.id] else { continue }
            let lowered = n.title.lowercased() + "\n" + n.text.prefix(6000).lowercased()
            for (profile, names) in aliases where profile != n.id {
                let hit = names.contains { name in
                    name.contains(" ") ? lowered.contains(name) : t.tokens.contains(name)
                }
                if hit { mentions.append((n.id, profile)) }
            }
        }
        return Result(categories: categories, mentions: mentions.map { (note: $0.0, profile: $0.1) })
    }

    private static func classify(_ n: Note, ai: String?, personUse: [String: Int], orgUse: [String: Int],
                                 lowerUse: [String: Int]) -> String {
        if let ai, all.contains(ai) { return ai }
        if !Set(n.userTags).isDisjoint(with: profileTags) { return "person" }
        if !Set(n.userTags).isDisjoint(with: orgTags),
           (1...4).contains(n.title.split(separator: " ").count) { return "entity" }

        let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }).map(String.init)
        guard (1...3).contains(words.count) else { return "note" }
        let name = words.joined(separator: " ").lowercased()
        if words.count == 1, family.contains(name) { return "person" }

        // A name is capitalised (or an acronym), has no numbers, and isn't a word you also write
        // in lowercase ("Garden", "Recipes"); "the plan" or "Phase 2 plan" is not a profile.
        guard words.allSatisfy({ $0.first?.isUppercase == true || $0.count <= 2 }),
              !title.contains(where: \.isNumber) else { return "note" }

        // What the tagger thinks of the title on its own…
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = title
        var nameWords = 0, isPerson = false, isOrg = false
        tagger.enumerateTags(in: title.startIndex..<title.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            if tag == .personalName { isPerson = true; nameWords += title[r].split(separator: " ").count }
            if tag == .organizationName { isOrg = true; nameWords += title[r].split(separator: " ").count }
            return true
        }
        // …and how the name (or a first name) is used across the rest of the library.
        // A first name counts only when the title itself reads as a person's name; a title
        // that starts with a brand ("Acme rebrand") is about a project, not a profile.
        let first = words[0].lowercased()
        let p = (personUse[name] ?? 0) + (words.count > 1 && first.count >= 3 ? (personUse[first] ?? 0) : 0)
        // An organisation profile is titled with just its name ("IKEA", not "Ikea Catalog").
        let o = orgUse[name] ?? 0
        // A single word you mostly write in lowercase is a thing, not a name ("garden").
        if words.count == 1, (lowerUse[name] ?? 0) >= max(1, p + o) { return "note" }
        if words.count > 1, (orgUse[first] ?? 0) > (personUse[first] ?? 0) { return o > 0 ? "entity" : "note" }
        let lastIsInitial = words.count == 2 && words[1].count <= 2

        if p > o, p >= 1 { return "person" }
        if o > p, o >= 1 { return "entity" }
        if isPerson && (nameWords >= words.count || lastIsInitial) { return "person" }
        if isOrg && nameWords >= words.count { return "entity" }
        return "note"
    }

    /// The names other notes would use: the full title, plus a first name for people.
    private static func names(for title: String, person: Bool) -> [String] {
        let full = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var out = [full]
        let first = full.split(separator: " ").first.map(String.init) ?? full
        if person, first != full, first.count >= 3 { out.append(first) }
        return out.filter { $0.count >= 2 }
    }
}
