import Foundation

// MCP results boiled down to what is worth showing: the records of the main list
// (a title, a status, a line of detail and a few facts each), or an object's fields.

private func json(_ object: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

func testDigestIssueList() {
    let issue: (Int, String, String) -> [String: Any] = { n, summary, status in
        ["id": "1000\(n)", "key": "DEMO-\(n)", "self": "https://example.atlassian.net/rest/api/3/issue/1000\(n)", "expand": "names",
         "fields": ["summary": summary, "status": ["name": status], "assignee": ["displayName": "Alex Kim"],
                    "updated": "2026-10-20T09:15:00.000+0900", "description": "Made-up issue body\nwith two lines"]]
    }
    let text = json(["issues": ["nodes": [issue(1, "Fix the parser", "In Progress"), issue(2, "Ship 0.7.5", "Done")]],
                     "queryResultsCount": 2, "context": ["cloudId": "abc"]])
    guard let digest = ResultDigest.make(text), let list = digest.collection else {
        expect(false, "issue list digests")
        return
    }
    expect(list.name == "issues" && list.total == 2, "collection named by its parent \(list.name) \(list.total)")
    let first = list.records[0]
    expect(first.badge == "DEMO-1" && first.title == "Fix the parser", "badge and title \(first)")
    expect(first.status == "In Progress", "nested status name \(String(describing: first.status))")
    expect(first.subtitle == "Made-up issue body with two lines", "one-line detail \(String(describing: first.subtitle))")
    expect(first.meta.contains(ResultDigest.Field(label: "updated", value: "2026-10-20 09:15")), "short date \(first.meta)")
    expect(first.meta.contains(ResultDigest.Field(label: "assignee", value: "Alex Kim")), "person \(first.meta)")
    expect(!first.meta.contains { $0.label == "self" || $0.label == "expand" || $0.label == "id" }, "noise dropped \(first.meta)")
    expect(digest.facts == [ResultDigest.Field(label: "queryResultsCount", value: "2")], "top-level facts \(digest.facts)")
}

func testDigestDocumentsWithoutTitles() {
    let docs: [[String: Any]] = (0..<80).map { ["_id": ["$oid": "65f0c0ffee\($0)"], "grade": 3, "subject": "math-\($0)",
                                                 "createdAt": ["$date": "2026-09-01T00:00:00Z"]] }
    guard let list = ResultDigest.make(json(["documents": docs, "count": 80]))?.collection else {
        expect(false, "documents digest")
        return
    }
    expect(list.total == 80 && list.records.count == ResultDigest.recordLimit, "capped records \(list.records.count)")
    expect(list.records[0].title == "math-0", "subject is a title \(list.records[0].title ?? "nil")")
    expect(list.records[0].meta.contains(ResultDigest.Field(label: "createdAt", value: "2026-09-01 00:00")), "extended JSON date")
    let untitled = ResultDigest.make(json([["n": 1, "grade": 2, "createdAt": "2026-09-01T00:00:00Z"]]))?.collection?.records.first
    expect(untitled?.title == nil, "no made-up title \(String(describing: untitled?.title))")
    expect(untitled?.meta.map(\.label) == ["createdAt", "grade", "n"], "untitled records list their fields \(String(describing: untitled?.meta))")
    let long = ResultDigest.make(json([["blob": String(repeating: "x", count: 300)]]))?.collection?.records.first
    expect(long?.meta.first?.label == "blob" && (long?.meta.first?.value.count ?? 0) <= 121, "long-only records still show something")
    let thread = ResultDigest.make(json(["threads": [["id": "t1", "messages": [["subject": "Weekly sync", "from": "a@example.com"]]]]]))
    expect(thread?.collection?.records.first?.title == "Weekly sync", "title from the first nested item")
    let notion = ResultDigest.make(json(["results": [["이름": "로드맵", "상태": "진행 중"], ["Name": "Backlog"]]]))
    expect(notion?.collection?.records.map(\.title) == ["로드맵", "Backlog"], "Korean and capitalized title keys")
    expect(notion?.collection?.records.first?.status == "진행 중", "Korean status key")
}

func testDigestSingleObject() {
    let text = json(["id": "evt1", "summary": "Sprint review", "start": ["dateTime": "2026-10-24T14:00:00+09:00"],
                     "attendees": [["email": "a@example.com"], ["email": "b@example.com"]], "self": "https://x"])
    guard let digest = ResultDigest.make(text) else {
        expect(false, "object digest")
        return
    }
    // An object with a title of its own is one record: show its fields, not its attendee list.
    expect(digest.collection == nil, "a titled object is not a list")
    expect(digest.facts.isEmpty, "no fact chips repeating the fields \(digest.facts)")
    expect(digest.fields.first?.label == "summary", "title field first \(digest.fields.map(\.label))")
    expect(digest.fields.contains(ResultDigest.Field(label: "summary", value: "Sprint review")), "title field \(digest.fields)")
    expect(digest.fields.contains(ResultDigest.Field(label: "start", value: "2026-10-24 14:00")), "nested date")
    expect(digest.fields.contains(ResultDigest.Field(label: "attendees", value: "[2]")), "list size")
    expect(!digest.fields.contains { $0.label == "self" || $0.label == "id" }, "noise dropped \(digest.fields)")
    let plain = ResultDigest.make(json(["title": "Roadmap", "owner": ["name": "Sam"], "tags": ["a", "b"]]))
    expect(plain?.collection == nil, "no list of objects")
    expect(plain?.fields == [ResultDigest.Field(label: "title", value: "Roadmap"), ResultDigest.Field(label: "owner", value: "Sam"),
                             ResultDigest.Field(label: "tags", value: "a, b")], "fields \(String(describing: plain?.fields))")
}

func testDigestTextWithEmbeddedJSON() {
    let digest = ResultDigest.make("Found 1 document in lessons:\n[{\"title\": \"Fractions\", \"grade\": 3}]")
    expect(digest?.preface == "Found 1 document in lessons:", "text before the JSON \(String(describing: digest?.preface))")
    expect(digest?.collection?.records.first?.title == "Fractions", "embedded records")
    expect(ResultDigest.make("Took a screenshot of the page") == nil, "plain text has no digest")
    expect(ResultDigest.make("{\"a\": 1, \"b\": \"cut\n…") == nil, "cut-off JSON")
}

func runDigestTests() {
    testDigestIssueList()
    testDigestDocumentsWithoutTitles()
    testDigestSingleObject()
    testDigestTextWithEmbeddedJSON()
}
