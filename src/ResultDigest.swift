import Foundation

// MCP results are often large JSON documents (issue searches, database queries). Drawing them
// whole is slow and hard to read, so they are boiled down to what matters: the records of the
// main list, each with a title, a status, a line of detail and a few facts, or an object's fields.

struct ResultDigest: Equatable {
    struct Field: Equatable {
        let label: String
        let value: String
    }

    struct Record: Equatable {
        let badge: String?
        /// nil for records with nothing like a title (database rows); their fields are in `meta`.
        let title: String?
        let status: String?
        let subtitle: String?
        let meta: [Field]
    }

    struct Collection: Equatable {
        let name: String
        let total: Int
        let records: [Record]
    }

    static let recordLimit = 50
    static let fieldLimit = 40

    /// Text before JSON that follows a sentence ("Found 3 documents:\n[…]").
    let preface: String?
    /// Short top-level values beside the list (counts, flags).
    let facts: [Field]
    let collection: Collection?
    /// An object's own values, when it is not a list.
    let fields: [Field]

    static func make(_ text: String) -> ResultDigest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = parse(trimmed) { return digest(value, preface: nil) }
        // JSON after a sentence: start at the first line that opens an object or a list.
        let lines = trimmed.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }), start > 0,
              let value = parse(lines[start...].joined(separator: "\n")) else { return nil }
        return digest(value, preface: lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parse(_ text: String) -> Any? {
        guard text.first == "{" || text.first == "[", let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return value
    }

    private static func digest(_ value: Any, preface: String?) -> ResultDigest {
        let object = value as? [String: Any]
        let titled = object.map { Leaf.flatten($0, depth: 1).contains { Leaf.titleNames.contains($0.key) } } ?? false
        let list = titled ? nil : mainList(value, name: "", depth: 0)
        let facts = list == nil ? [] : object.map { top in
            Leaf.flatten(top, depth: 1).filter {
                $0.path.count == 1 && $0.value.count <= 60 && list?.path.first != $0.path.first && !Leaf.noise.contains($0.key)
            }
        } ?? []
        let collection = list.map { found in
            Collection(name: found.name, total: found.items.count,
                       records: found.items.prefix(recordLimit).map(Record.init(item:)))
        }
        let fields = collection == nil ? object.map(objectFields) ?? [] : []
        return ResultDigest(preface: preface?.isEmpty == true ? nil : preface,
                            facts: facts.prefix(6).map { Field(label: $0.name, value: $0.value) },
                            collection: collection, fields: fields)
    }

    private struct FoundList {
        let name: String
        let path: [String]
        let items: [Any]
    }

    /// The largest list of objects (or values) within a few levels, named after its key.
    private static func mainList(_ value: Any, name: String, depth: Int, path: [String] = []) -> FoundList? {
        if let array = value as? [Any], !array.isEmpty {
            return FoundList(name: name, path: path, items: array)
        }
        guard let object = value as? [String: Any], depth < 3 else { return nil }
        let generic: Set<String> = ["nodes", "items", "data", "results", "edges", "values", "list"]
        return object.keys.sorted().compactMap { key -> FoundList? in
            let label = generic.contains(key) && !name.isEmpty ? name : key
            return mainList(object[key] as Any, name: label, depth: depth + 1, path: path + [key])
        }
        .max { $0.items.count < $1.items.count }
    }

    private static func objectFields(_ object: [String: Any]) -> [Field] {
        var seen: Set<String> = []
        return Leaf.flatten(object, depth: 3)
            .filter { !Leaf.noise.contains($0.key) && seen.insert($0.name).inserted }
            // The title first, then the rest by name.
            .sorted { lhs, rhs in
                let (l, r) = (Leaf.titleNames.contains(lhs.key), Leaf.titleNames.contains(rhs.key))
                return l != r ? l : lhs.name < rhs.name
            }
            .prefix(fieldLimit)
            .map { Field(label: $0.name, value: $0.value) }
    }
}

extension ResultDigest.Record {
    private static let badgeNames: Set<String> = ["key", "number", "identifier", "ref"]
    private static let statusNames: Set<String> = ["status", "state", "상태"]
    private static let detailNames = ["description", "snippet", "highlight", "preview", "body", "content", "text", "message", "설명", "내용"]
    private static let dateNames: Set<String> = ["created", "updated", "createdat", "updatedat", "start", "end", "time",
                                                 "timestamp", "date", "due", "duedate", "modified", "lastmodified"]
    private static let peopleNames: Set<String> = ["assignee", "reporter", "organizer", "creator", "author", "owner", "from", "to", "user"]

    init(item: Any) {
        guard let object = item as? [String: Any] else {
            self.init(badge: nil, title: Leaf.format(item) ?? "", status: nil, subtitle: nil, meta: [])
            return
        }
        let leaves = Leaf.flatten(object, depth: 3).filter { !Leaf.noise.contains($0.key) }
        func first(_ names: [String], in pool: [Leaf]) -> Leaf? {
            names.lazy.compactMap { name in pool.first { $0.key == name } }.first
        }
        let badge = leaves.first { Self.badgeNames.contains($0.key) && $0.value.count <= 24 }
        let title = first(Leaf.titleOrder, in: leaves) ?? Self.nestedTitle(object)
        let status = leaves.first { Self.statusNames.contains($0.key) && $0.value.count <= 30 }
        let detail = first(Self.detailNames.filter { $0 != title?.key }, in: leaves)
        let used = Set([badge, title, status, detail].compactMap { $0?.key })
        // Records without a title show more of their fields instead, and may be longer.
        let short = leaves.filter { !used.contains($0.key) && $0.value.count <= (title == nil ? 80 : 40) }
        // Only long values: show the first, cut short, rather than an empty row.
        let rest = short.isEmpty && title == nil
            ? leaves.filter { !used.contains($0.key) }.prefix(1).map { Leaf(path: $0.path, name: $0.name, value: Leaf.oneLine($0.value, limit: 120)) }
            : short
        let ranked = rest.filter { Self.dateNames.contains($0.key) } + rest.filter { Self.peopleNames.contains($0.key) }
            + rest.filter { !Self.dateNames.contains($0.key) && !Self.peopleNames.contains($0.key) }.sorted { $0.name < $1.name }
        self.init(badge: badge?.value,
                  title: title.map { Leaf.oneLine($0.value, limit: 140) },
                  status: status?.value,
                  subtitle: detail.map { Leaf.oneLine($0.value, limit: 180) },
                  meta: ranked.prefix(title == nil ? 6 : 3).map { ResultDigest.Field(label: $0.name, value: $0.value) })
    }

    /// A thread's subject lives on its first message: look one list down for a title.
    private static func nestedTitle(_ object: [String: Any]) -> Leaf? {
        for key in object.keys.sorted() {
            guard let items = object[key] as? [[String: Any]], let first = items.first else { continue }
            let leaves = Leaf.flatten(first, depth: 2)
            if let title = Leaf.titleOrder.lazy.compactMap({ name in leaves.first { $0.key == name } }).first { return title }
        }
        return nil
    }
}

/// One scalar inside a JSON object, named by its key, or by its parent key for wrappers such
/// as `status.name`, `assignee.displayName`, `start.dateTime` or Mongo's `createdAt.$date`.
private struct Leaf {
    let path: [String]
    let name: String
    let value: String
    /// The name lowercased, for matching against the name lists below.
    var key: String { name.lowercased() }

    static let titleOrder = ["summary", "title", "name", "subject", "displayname", "display_name", "filename", "label",
                             "headline", "제목", "이름"]
    static let titleNames = Set(titleOrder)
    static let noise: Set<String> = ["id", "_id", "self", "expand", "__v", "etag", "kind", "iconurl", "avatarurl", "avatarurls",
                                     "htmllink", "weburl", "url", "href", "link", "viewurl", "icaluid", "sequence", "cloudid",
                                     "descriptioneditable", "jsdpublic", "accountid", "hangoutlink"]
    private static let wrappers: Set<String> = ["name", "value", "displayName", "dateTime", "date", "email", "$date", "$oid",
                                                "$numberLong", "$numberInt", "$numberDouble", "text"]

    static func flatten(_ object: [String: Any], depth: Int, path: [String] = []) -> [Leaf] {
        object.keys.sorted().flatMap { key -> [Leaf] in
            let value = object[key] as Any
            let here = path + [key]
            if let nested = value as? [String: Any] {
                return depth > 1 ? flatten(nested, depth: depth - 1, path: here) : []
            }
            if let array = value as? [Any] {
                let scalars = array.compactMap(format)
                let text = scalars.count == array.count && array.count <= 5 ? scalars.joined(separator: ", ") : "[\(array.count)]"
                return text.isEmpty ? [] : [Leaf(path: here, name: name(here), value: text)]
            }
            guard let text = format(value), !text.isEmpty else { return [] }
            return [Leaf(path: here, name: name(here), value: text)]
        }
    }

    private static func name(_ path: [String]) -> String {
        guard let last = path.last else { return "" }
        return path.count > 1 && wrappers.contains(last) ? path[path.count - 2] : last
    }

    static func format(_ value: Any) -> String? {
        switch value {
        case let text as String: return shortDate(text) ?? text
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default: return nil
        }
    }

    /// "2026-10-20T09:15:00.000+0900" → "2026-10-20 09:15", as written (no time zone change).
    private static func shortDate(_ text: String) -> String? {
        let chars = Array(text)
        guard chars.count >= 16, chars[4] == "-", chars[7] == "-", chars[10] == "T", chars[13] == ":",
              chars[0..<4].allSatisfy(\.isNumber) else { return nil }
        return String(chars[0..<10]) + " " + String(chars[11..<16])
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
