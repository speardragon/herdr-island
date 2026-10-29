import Foundation

// MongoDB MCP calls, drawn like a database viewer: the namespace and query from the input,
// and the result as typed documents (EJSON wrappers such as `{"$oid": …}` read as their type).

/// `mcp__<server>__<tool>` where the server name says it is MongoDB.
struct MongoTool: Equatable {
    let server: String
    let tool: String

    init?(name: String) {
        guard let mcp = McpTool(name: name), mcp.server.lowercased().contains("mongo") else { return nil }
        server = mcp.server
        tool = mcp.tool
    }
}

// MARK: - Values

enum BsonKind: Equatable {
    case string, number, date, objectId, bool, null, other, object, array
}

struct BsonField: Equatable {
    let key: String
    let value: Bson
}

indirect enum Bson: Equatable {
    case scalar(BsonKind, String)
    case object([BsonField])
    case array([Bson])

    static let null = Bson.scalar(.null, "null")
    static let stringLimit = 1_000

    init(_ value: JValue) {
        switch value {
        case .string(let text):
            let cut = text.count > Self.stringLimit ? String(text.prefix(Self.stringLimit)) + "…" : text
            self = .scalar(.string, "\"\(cut)\"")
        case .number(let text): self = .scalar(.number, text)
        case .bool(let flag): self = .scalar(.bool, flag ? "true" : "false")
        case .null: self = .null
        case .array(let items): self = .array(items.map(Bson.init))
        case .object(let pairs):
            self = ExtendedJSON.wrapped(pairs) ?? .object(pairs.map { BsonField(key: $0.key, value: Bson($0.value)) })
        }
    }

    var kind: BsonKind {
        switch self {
        case .scalar(let kind, _): return kind
        case .object: return .object
        case .array: return .array
        }
    }

    /// As a database viewer writes it: `ObjectId('…')`, `Long('…')`, `Object (3)`, `Array (empty)`.
    var display: String {
        switch self {
        case .scalar(_, let text): return text
        case .object(let fields): return fields.isEmpty ? "Object (empty)" : "Object (\(fields.count))"
        case .array(let items): return items.isEmpty ? "Array (empty)" : "Array (\(items.count))"
        }
    }

    /// Nested values keyed by field name, or by index for arrays.
    var children: [BsonField] {
        switch self {
        case .scalar: return []
        case .object(let fields): return fields
        case .array(let items): return items.enumerated().map { BsonField(key: String($0.offset), value: $0.element) }
        }
    }
}

/// Single-key `$` objects that stand for one typed value.
private enum ExtendedJSON {
    static func wrapped(_ pairs: [JPair]) -> Bson? {
        guard pairs.count == 1, let pair = pairs.first, pair.key.hasPrefix("$") else { return nil }
        switch (pair.key, pair.value) {
        case ("$oid", .string(let hex)): return .scalar(.objectId, "ObjectId('\(hex)')")
        case ("$date", let value): return date(value).map { .scalar(.date, $0) }
        case ("$numberLong", .string(let n)): return .scalar(.number, "Long('\(n)')")
        case ("$numberInt", .string(let n)), ("$numberDouble", .string(let n)): return .scalar(.number, n)
        case ("$numberDecimal", .string(let n)): return .scalar(.number, "Decimal128('\(n)')")
        case ("$uuid", .string(let id)): return .scalar(.other, "UUID('\(id)')")
        case ("$binary", .object(let fields)):
            let base64 = string(fields, "base64") ?? ""
            let cut = base64.count > 100 ? String(base64.prefix(100)) + "…" : base64
            return .scalar(.other, "Binary.createFromBase64('\(cut)', \(Int(string(fields, "subType") ?? "0", radix: 16) ?? 0))")
        case ("$regularExpression", .object(let fields)):
            return .scalar(.other, "/\(string(fields, "pattern") ?? "")/\(string(fields, "options") ?? "")")
        case ("$timestamp", .object(let fields)):
            return .scalar(.other, "Timestamp({ t: \(string(fields, "t") ?? "0"), i: \(string(fields, "i") ?? "0") })")
        default:
            return nil
        }
    }

    private static func string(_ fields: [JPair], _ key: String) -> String? {
        switch fields.first(where: { $0.key == key })?.value {
        case .string(let text)?, .number(let text)?: return text
        default: return nil
        }
    }

    private static let isoOptions: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
    private static let isoIn: [ISO8601DateFormatter] = isoOptions.map {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = $0
        return formatter
    }
    private static let isoOut: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'+00:00'"
        return formatter
    }()

    /// `{"$date": "…Z"}` or `{"$date": {"$numberLong": "ms"}}`, written in UTC.
    private static func date(_ value: JValue) -> String? {
        switch value {
        case .string(let text):
            return isoIn.lazy.compactMap { $0.date(from: text) }.first.map(isoOut.string) ?? text
        case .object(let pairs):
            guard let ms = string(pairs, "$numberLong").flatMap(Double.init) else { return nil }
            return isoOut.string(from: Date(timeIntervalSince1970: ms / 1000))
        case .number(let ms):
            return Double(ms).map { isoOut.string(from: Date(timeIntervalSince1970: $0 / 1000)) }
        default:
            return nil
        }
    }
}

// MARK: - mongosh-style query text

enum MongoShell {
    static func text(_ value: JValue) -> String {
        tokens(value).map(\.text).joined()
    }

    /// One line: `{ grade: { $gte: 3 }, _id: ObjectId("…") }`.
    static func tokens(_ value: JValue) -> [Token] {
        switch value {
        case .string(let text): return [Token(text: quoted(text), kind: .string)]
        case .number(let text): return [Token(text: text, kind: .number)]
        case .bool(let flag): return [Token(text: flag ? "true" : "false", kind: .literal)]
        case .null: return [Token(text: "null", kind: .literal)]
        case .array(let items):
            guard !items.isEmpty else { return [Token(text: "[]", kind: .punct)] }
            return [Token(text: "[", kind: .punct)] + joined(items.map(tokens)) + [Token(text: "]", kind: .punct)]
        case .object(let pairs):
            if let call = wrapperCall(pairs) { return call }
            guard !pairs.isEmpty else { return [Token(text: "{}", kind: .punct)] }
            let members = pairs.map { [Token(text: key($0.key), kind: .key), Token(text: ": ", kind: .punct)] + tokens($0.value) }
            return [Token(text: "{ ", kind: .punct)] + joined(members) + [Token(text: " }", kind: .punct)]
        }
    }

    private static func joined(_ parts: [[Token]]) -> [Token] {
        parts.enumerated().flatMap { index, part in index == 0 ? part : [Token(text: ", ", kind: .punct)] + part }
    }

    /// Extended JSON in a filter reads as the shell constructor.
    private static func wrapperCall(_ pairs: [JPair]) -> [Token]? {
        guard pairs.count == 1, case .string(let text) = pairs[0].value else { return nil }
        let name = ["$oid": "ObjectId", "$date": "ISODate", "$numberLong": "NumberLong", "$uuid": "UUID"][pairs[0].key]
        return name.map { [Token(text: "\($0)(", kind: .literal), Token(text: quoted(text), kind: .string), Token(text: ")", kind: .literal)] }
    }

    private static func key(_ name: String) -> String {
        let plain = name.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        return plain ? name : quoted(name)
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Calls

struct MongoQuery: Equatable {
    struct Option: Equatable {
        let label: String
        let value: String
    }

    struct Stage: Equatable {
        let op: String
        let body: JValue
    }

    let database: String?
    let collection: String?
    let filter: JValue?
    let options: [Option]
    let pipeline: [Stage]

    init(input: String) {
        let pairs: [JPair]
        if case .object(let top)? = OrderedJSON.parse(input)?.value { pairs = top } else { pairs = [] }
        func value(_ key: String) -> JValue? { pairs.first { $0.key == key }?.value }
        func name(_ key: String) -> String? {
            if case .string(let text)? = value(key) { return text }
            return nil
        }
        database = name("database")
        collection = name("collection")
        filter = value("filter") ?? value("query")
        options = [("projection", "Project"), ("sort", "Sort"), ("skip", "Skip"), ("limit", "Limit")].compactMap { key, label in
            value(key).map { Option(label: label, value: MongoShell.text($0)) }
        }
        if case .array(let stages)? = value("pipeline") {
            pipeline = stages.compactMap { stage in
                guard case .object(let ops) = stage, let op = ops.first else { return nil }
                return Stage(op: op.key, body: op.value)
            }
        } else {
            pipeline = []
        }
    }
}

struct MongoDocuments: Equatable {
    let documents: [Bson]
    /// Matched documents as the tool reported them, or the number returned.
    let total: Int
    /// The result was cut short before it reached here; later documents are missing.
    let truncated: Bool
}

enum MongoResult: Equatable {
    case documents(MongoDocuments)
    case count(Int)
    case names([String])

    /// find/aggregate `{documents, queryResultsCount | count}`, count `{count}`,
    /// list-collections/databases `{collections | databases: [{name}]}`; nil for text.
    static func parse(_ text: String) -> MongoResult? {
        // `Truncate` marks a cut with "\n…"; without it the cut is a plain end of input.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uncut = trimmed.hasSuffix("\n…") ? String(trimmed.dropLast(2)) : trimmed
        guard let parsed = OrderedJSON.parse(uncut),
              case .object(let pairs) = parsed.value else { return nil }
        func value(_ key: String) -> JValue? { pairs.first { $0.key == key }?.value }
        func int(_ key: String) -> Int? {
            if case .number(let n)? = value(key) { return Int(n) }
            return nil
        }
        if case .array(let docs)? = value("documents") {
            return .documents(MongoDocuments(documents: docs.map(Bson.init),
                                             total: int("queryResultsCount") ?? int("count") ?? docs.count,
                                             truncated: parsed.truncated))
        }
        if let count = int("count"), pairs.count == 1 { return .count(count) }
        for key in ["collections", "databases"] {
            guard case .array(let items)? = value(key) else { continue }
            return .names(items.compactMap { item in
                guard case .object(let fields) = item, case .string(let name)? = fields.first(where: { $0.key == "name" })?.value else { return nil }
                return name
            })
        }
        return nil
    }
}

/// What the stage shows for one MongoDB call; `result` is nil until it returns, or for text results.
struct MongoView: Equatable {
    let tool: MongoTool
    let query: MongoQuery
    let result: MongoResult?

    init?(call: ToolCall) {
        guard let tool = MongoTool(name: call.name) else { return nil }
        self.tool = tool
        query = MongoQuery(input: call.input)
        result = call.isError ? nil : call.result.flatMap(MongoResult.parse)
    }
}
