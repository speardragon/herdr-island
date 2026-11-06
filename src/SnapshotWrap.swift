import SwiftUI

// `--snapshot` previews of the wrap toggle: the same long command, file and diff
// scrolling sideways and wrapped. Every line is made-up demo text.

extension Snapshot {
    static func renderWrapPreview(into directory: URL) {
        let now = Date()
        let long = "curl -sS -X POST https://api.example.dev/v1/demo/reports?include=summary,owners,history "
            + "-H 'Content-Type: application/json' -d '{\"range\": \"last-30-days\", \"format\": \"csv\", \"notify\": false}' | jq '.items[] | {id, title}'"
        let shell = ToolCall(id: "preview-wrap-shell", name: "Bash", kind: .shell, summary: "Fetch a report", input: "",
                             result: "{\"id\": 1, \"title\": \"A made-up report whose title is long enough to run past the edge of the stage\"}",
                             startedAt: now.addingTimeInterval(-2), finishedAt: now,
                             fields: ["command": long, "description": "Fetch a report"])
        let content = "struct DemoReport {\n    let title: String\n"
            + "    func summary() -> String { \"\\(title) — a made-up summary line that keeps going well past the width of the stage\" }\n}\n"
        let write = ToolCall(id: "preview-wrap-write", name: "Write", kind: .write, summary: "Report.swift", input: "",
                             result: "ok", startedAt: now.addingTimeInterval(-1), finishedAt: now,
                             fields: ["file_path": "/tmp/demo/Report.swift", "content": content])
        var edit = ToolCall(id: "preview-wrap-edit", name: "Edit", kind: .edit, summary: "Report.swift", input: "",
                            result: "ok", startedAt: now.addingTimeInterval(-1), finishedAt: now,
                            fields: ["file_path": "/tmp/demo/Report.swift", "old_string": "a", "new_string": "b"])
        edit.patch = [PatchHunk(oldStart: 2, newStart: 2, lines: [
            .init(kind: .context, text: "    let title: String", oldNumber: 2, newNumber: 2),
            .init(kind: .removed, text: "    func summary() -> String { title }", oldNumber: 3, newNumber: nil),
            .init(kind: .added, text: "    func summary() -> String { \"\\(title) — now with a much longer made-up description that wraps\" }",
                  oldNumber: nil, newNumber: 3),
        ])]
        let code = content.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) }
        var short = shell
        short.fields = ["command": "git status", "description": "Check the tree"]
        short.result = "nothing to commit"
        let stages: [(String, AnyView)] = [
            ("shell", AnyView(ShellStage(call: shell, large: false))),
            ("shell-short", AnyView(ShellStage(call: short, large: false))),
            ("write", AnyView(WriteStage(call: write, large: false))),
            ("edit", AnyView(EditStage(call: edit, large: false))),
            ("read", AnyView(CodeDocument(lines: code, highlight: ReadRange(start: 2, count: 2, total: 4), large: false))),
        ]
        for (name, stage) in stages {
            for wrap in [false, true] {
                let view = VStack(alignment: .trailing, spacing: 10) {
                    WrapToggle(wrap: .constant(wrap))
                    stage
                }
                render(view.environment(\.stageWrap, .constant(wrap)).padding(16).background(Color.black),
                       size: NSSize(width: 520, height: 320),
                       to: directory.appendingPathComponent("preview-wrap-\(name)\(wrap ? "-on" : "-off").png"))
            }
        }
    }
}
