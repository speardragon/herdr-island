import Foundation

// MongoDB MCP calls: the query from the input, documents in source order with EJSON types.

private func mongoCall(_ tool: String, input: String, result: String?) -> ToolCall {
    ToolCall(id: "mongo-\(tool)", name: "mcp__edu-mongodb__\(tool)", kind: .mcp, summary: tool, input: input,
             result: result, startedAt: nil)
}

func testMongoDetection() {
    for name in ["mcp__mongodb__find", "mcp__edu-mongodb__aggregate", "mcp__plugin_aidt-workflow_xAPI-mongodb__count",
                 "mcp__stg-edu-mongodb__list-collections"] {
        expect(MongoTool(name: name) != nil, "mongo server \(name)")
    }
    expect(MongoTool(name: "mcp__claude_ai_Notion__notion-search") == nil, "not mongo")
    expect(MongoTool(name: "mcp__plugin_aidt-workflow_xAPI-mongodb__count")?.server == "xAPI-mongodb", "server name")
    expect(MongoTool(name: "mcp__mongodb__find")?.tool == "find", "tool name")
}

func testOrderedJSON() {
    guard case .object(let pairs)? = OrderedJSON.parse(#"{"z": 1, "a": [true, null, "x\"yé"], "m": {"k": -2.5e3}}"#)?.value else {
        return expect(false, "object parses")
    }
    expect(pairs.map(\.key) == ["z", "a", "m"], "source order kept \(pairs.map(\.key))")
    expect(pairs[1].value == .array([.bool(true), .null, .string("x\"yé")]), "escapes \(pairs[1].value)")
    expect(pairs[2].value == .object([.init(key: "k", value: .number("-2.5e3"))]), "number text kept")
    let cut = OrderedJSON.parse(#"{"documents": [{"a": 1}, {"a": 2}, {"a": 3, "b": "cut"#)
    expect(cut?.truncated == true, "cut-off input is marked")
    if case .object(let top)? = cut?.value, case .array(let docs) = top.first?.value {
        expect(docs.count == 2, "only complete documents kept \(docs.count)")
    } else {
        expect(false, "partial documents salvaged")
    }
    expect(OrderedJSON.parse("Error running find: not authorized") == nil, "plain text is not JSON")
}

func testBsonValues() {
    let doc = #"{"_id": {"$oid": "65f0c0ffee0000000000aa01"}, "at": {"$date": "2026-10-21T08:00:00Z"}, "#
        + #""ms": {"$date": {"$numberLong": "1792569600000"}}, "big": {"$numberLong": "9007199254740993"}, "#
        + #""dec": {"$numberDecimal": "1.10"}, "n": 3, "ok": false, "none": null, "s": "hi", "#
        + #""tags": [], "nested": {"a": 1, "b": 2}}"#
    guard let value = OrderedJSON.parse(doc)?.value, case .object(let fields) = Bson(value) else {
        return expect(false, "document converts")
    }
    let shown = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
    expect(fields.first?.key == "_id" && shown["_id"]?.display == "ObjectId('65f0c0ffee0000000000aa01')", "object id")
    expect(shown["_id"]?.kind == .objectId && shown["at"]?.kind == .date, "kinds")
    expect(shown["at"]?.display == "2026-10-21T08:00:00.000+00:00", "date \(shown["at"]?.display ?? "")")
    expect(shown["ms"]?.display == "2026-10-21T08:00:00.000+00:00", "date from millis \(shown["ms"]?.display ?? "")")
    expect(shown["big"]?.display == "Long('9007199254740993')" && shown["big"]?.kind == .number, "long")
    expect(shown["dec"]?.display == "Decimal128('1.10')", "decimal")
    expect(shown["n"]?.display == "3" && shown["ok"]?.display == "false" && shown["none"]?.display == "null", "scalars")
    expect(shown["s"]?.display == "\"hi\"" && shown["s"]?.kind == .string, "string quoted")
    expect(shown["tags"]?.display == "Array (empty)" && shown["nested"]?.display == "Object (2)", "containers")
    expect(shown["nested"]?.children.map(\.key) == ["a", "b"], "children keyed")
    expect(Bson.array([.null, .null]).children.map(\.key) == ["0", "1"], "array children by index")
}

func testMongoFindResult() {
    let input = #"{"database": "school", "collection": "lessons", "filter": {"grade": {"$gte": 3}, "title": "Fractions"}, "#
        + #""projection": {"title": 1}, "sort": {"createdAt": -1}, "limit": 10}"#
    let docs = (1...3).map { #"{"_id": {"$oid": "65f0c0ffee000000000000a\#($0)"}, "title": "Lesson \#($0)"}"# }
    let call = mongoCall("find", input: input, result: #"{"documents": [\#(docs.joined(separator: ","))], "queryResultsCount": 42, "appliedLimits": []}"#)
    guard let view = MongoView(call: call) else { return expect(false, "find view") }
    expect(view.query.database == "school" && view.query.collection == "lessons", "namespace")
    expect(MongoShell.text(view.query.filter!) == #"{ grade: { $gte: 3 }, title: "Fractions" }"#, "mongosh filter \(MongoShell.text(view.query.filter!))")
    expect(view.query.options.map(\.label) == ["Project", "Sort", "Limit"], "option pills \(view.query.options.map(\.label))")
    expect(view.query.options.last?.value == "10", "limit value")
    guard case .documents(let list)? = view.result else { return expect(false, "documents result") }
    expect(list.documents.count == 3 && list.total == 42 && !list.truncated, "count and total \(list.total)")
}

func testMongoAggregateAndCount() {
    let input = #"{"database": "school", "collection": "events", "pipeline": [{"$match": {"kind": "quiz"}}, "#
        + #"{"$group": {"_id": "$student", "n": {"$sum": 1}}}, {"$limit": 5}]}"#
    let aggregate = MongoView(call: mongoCall("aggregate", input: input, result: #"{"documents": [{"_id": "s1", "n": 4}], "count": 1}"#))
    expect(aggregate?.query.pipeline.map(\.op) == ["$match", "$group", "$limit"], "stage operators")
    expect(aggregate?.query.pipeline.first.map { MongoShell.text($0.body) } == #"{ kind: "quiz" }"#, "stage body")
    if case .documents(let list)? = aggregate?.result { expect(list.total == 1, "aggregate count") } else { expect(false, "aggregate docs") }
    let count = MongoView(call: mongoCall("count", input: #"{"database": "school", "collection": "events"}"#, result: #"{"count": 1234}"#))
    expect(count?.result == .count(1234), "count result")
    let names = MongoView(call: mongoCall("list-collections", input: #"{"database": "school"}"#,
                                          result: #"{"collections": [{"name": "lessons"}, {"name": "events"}]}"#))
    expect(names?.result == .names(["lessons", "events"]), "collection names")
    let failed = MongoView(call: mongoCall("find", input: "{}", result: "Error running find: not authorized"))
    expect(failed != nil && failed?.result == nil, "text results fall back to raw text")
}

/// A long result cut by `Truncate` (which appends "\n…") keeps its whole documents.
func testMongoCutResult() {
    let docs = (1...200).map { #"{"_id": {"$oid": "65f0c0ffee0000000000\#(String(format: "%04d", $0))"}, "n": \#($0 * 12)}"# }
    let full = #"{"documents": [\#(docs.joined(separator: ", "))], "queryResultsCount": 200}"#
    for limit in [3_000, 3_001, 3_002, 3_003, 3_010, 3_020] {
        guard case .documents(let list)? = MongoResult.parse(Truncate.text(full, limit: limit)) else {
            expect(false, "cut result at \(limit) still parses")
            continue
        }
        expect(list.truncated && !list.documents.isEmpty && list.documents.count < 200, "partial documents at \(limit): \(list.documents.count)")
        expect(list.documents.last?.children.map(\.key) == ["_id", "n"], "last kept document is whole at \(limit)")
    }
}

func runMongoTests() {
    testMongoCutResult()
    testMongoDetection()
    testOrderedJSON()
    testBsonValues()
    testMongoFindResult()
    testMongoAggregateAndCount()
}
