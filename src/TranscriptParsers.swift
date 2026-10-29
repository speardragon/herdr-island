import Foundation

// Incremental JSONL readers: feed lines as the agent appends them and read `detail` any time.
// Lines that cannot hold anything we show are skipped before JSON decoding, because
// request blobs and attachments make up most of a long transcript's bytes.

protocol TranscriptParser {
    var detail: SessionDetail { get }
    mutating func consume(_ line: String)
}

private func decodeLine(_ line: String) -> JSON? {
    guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON
}

/// Text of a tool result, which is either a string or a list of text blocks.
private func resultText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    guard let blocks = value as? [JSON] else { return nil }
    let texts = blocks.compactMap { $0["text"] as? String }
    return texts.isEmpty ? nil : texts.joined(separator: "\n")
}

private func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
    return text
}

private func firstLine(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
}

private extension SessionDetail {
    mutating func touch(_ date: Date?) {
        guard let date = date else { return }
        if startedAt.map({ date < $0 }) ?? true { startedAt = date }
        if updatedAt.map({ date > $0 }) ?? true { updatedAt = date }
    }

    mutating func file(_ path: String, at date: Date?, _ change: (inout FileActivity) -> Void) {
        var activity = files[path] ?? FileActivity(path: path)
        change(&activity)
        activity.lastTouched = date ?? activity.lastTouched
        files[path] = activity
    }
}

// MARK: - Claude Code

struct ClaudeTranscriptParser: TranscriptParser {
    private(set) var detail = SessionDetail(provider: .claude)
    /// Usage per message id: Claude Code writes one line per content block, each repeating the usage.
    private var usageByMessage: [String: TokenUsage] = [:]
    private var toolIndex: [String: Int] = [:]

    static func shouldSkip(_ line: String) -> Bool {
        let head = line.prefix(64)
        return ["\"type\":\"api-request", "\"type\":\"attachment", "\"type\":\"file-history-", "\"type\":\"queue-operation"]
            .contains { head.contains($0) }
    }

    mutating func consume(_ line: String) {
        guard !Self.shouldSkip(line), let object = decodeLine(line) else { return }
        let date = Timestamp.parse(object["timestamp"])
        let subagent = object["isSidechain"] as? Bool ?? false
        switch object["type"] as? String {
        case "assistant":
            detail.touch(date)
            assistant(object["message"] as? JSON ?? [:], at: date, subagent: subagent)
        case "user":
            detail.touch(date)
            user(object, at: date, subagent: subagent)
        case "system":
            if object["subtype"] as? String == "turn_duration" {
                detail.activeMilliseconds += object["durationMs"] as? Int ?? 0
            }
        default:
            break
        }
    }

    private mutating func assistant(_ message: JSON, at date: Date?, subagent: Bool) {
        if let model = message["model"] as? String, !model.hasPrefix("<") { detail.model = model }
        if let id = message["id"] as? String, let usage = message["usage"] as? JSON {
            let parsed = TokenUsage(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0
            )
            usageByMessage[id] = parsed
            detail.usage = usageByMessage.values.reduce(TokenUsage(), +)
            if !subagent { detail.contextTokens = parsed.prompt }
        }
        for block in message["content"] as? [JSON] ?? [] {
            switch block["type"] as? String {
            case "tool_use":
                toolUse(block, at: date, subagent: subagent)
            case "text" where !subagent:
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detail.lastText = Truncate.text(text, limit: Truncate.contentLimit)
                    detail.lastTextAt = date
                }
            default:
                break
            }
        }
    }

    private mutating func user(_ object: JSON, at date: Date?, subagent: Bool) {
        let message = object["message"] as? JSON ?? [:]
        let content = message["content"]
        if let blocks = content as? [JSON], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            for block in blocks where block["type"] as? String == "tool_result" {
                toolResult(block, extra: object["toolUseResult"] as? JSON, at: date)
            }
            return
        }
        let isPrompt = content is String || (content as? [JSON])?.contains { $0["type"] as? String == "text" } == true
        if isPrompt && !subagent && object["isMeta"] as? Bool != true { detail.turns += 1 }
    }

    private mutating func toolUse(_ block: JSON, at date: Date?, subagent: Bool) {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
        let input = block["input"] as? JSON ?? [:]
        let (kind, summary) = Self.describe(name, input)
        var call = ToolCall(id: id, name: name, kind: kind, summary: summary,
                            input: Truncate.text(prettyJSON(input), limit: kind == .mcp ? Truncate.contentLimit : Truncate.resultLimit),
                            startedAt: date, isSubagent: subagent)
        call.fields = Self.fields(input)
        call.todos = Self.todos(input)
        call.questions = Self.questions(input)
        if kind == .read { call.readRange = ReadRange.from(input: call.fields, result: nil) }
        toolIndex[id] = detail.toolCalls.count
        detail.toolCalls.append(call)
        recordFiles(name, input, at: date)
    }

    private mutating func toolResult(_ block: JSON, extra: JSON?, at date: Date?) {
        guard let id = block["tool_use_id"] as? String, let index = toolIndex[id] else { return }
        // MCP results are often long JSON documents; keep enough of them to read, and more of
        // database results, whose documents are parsed once and drawn lazily.
        let call = detail.toolCalls[index]
        let limit = MongoTool(name: call.name) != nil ? Truncate.databaseLimit
            : call.kind == .mcp ? Truncate.contentLimit : Truncate.resultLimit
        detail.toolCalls[index].result = resultText(block["content"]).map { Truncate.text($0, limit: limit) }
        detail.toolCalls[index].resultImages = (block["content"] as? [JSON])?.filter { $0["type"] as? String == "image" }.count ?? 0
        detail.toolCalls[index].isError = block["is_error"] as? Bool ?? false
        detail.toolCalls[index].finishedAt = date
        if let extra = extra, call.kind == .read {
            detail.toolCalls[index].image = ReadImage.from(result: extra, path: call.fields["file_path"])
        }
        if let file = extra?["file"] as? JSON, file["startLine"] != nil {
            detail.toolCalls[index].readRange = ReadRange.from(input: detail.toolCalls[index].fields, result: file)
            detail.toolCalls[index].excerpt = (file["content"] as? String).map { Truncate.text($0, limit: Truncate.contentLimit) }
        }
        if let patch = extra?["structuredPatch"] { detail.toolCalls[index].patch = PatchHunk.parse(patch) }
        if let answers = extra?["answers"] as? JSON {
            let notes = extra?["annotations"] as? JSON ?? [:]
            detail.toolCalls[index].questions = detail.toolCalls[index].questions.map { question in
                var answered = question
                answered.answer = answers[question.text] as? String
                answered.notes = (notes[question.text] as? JSON)?["notes"] as? String
                return answered
            }
        }
        // A Read result carries the file text; keep it so later edits can be shown in place.
        if let file = extra?["file"] as? JSON, let path = file["filePath"] as? String, let text = file["content"] as? String {
            detail.file(path, at: date) { $0.content = Truncate.text(text, limit: Truncate.contentLimit) }
        }
    }

    private mutating func recordFiles(_ name: String, _ input: JSON, at date: Date?) {
        guard let path = (input["file_path"] ?? input["notebook_path"]) as? String else { return }
        switch name {
        case "Read", "NotebookRead":
            detail.file(path, at: date) { $0.reads += 1 }
        case "Write":
            let text = input["content"] as? String ?? ""
            detail.file(path, at: date) {
                $0.writes += 1
                $0.linesAdded += Truncate.lineCount(text)
                $0.content = Truncate.text(text, limit: Truncate.contentLimit)
            }
        case "Edit", "MultiEdit", "NotebookEdit":
            let edits = (input["edits"] as? [JSON]) ?? [input]
            for edit in edits {
                let removed = edit["old_string"] as? String ?? ""
                let added = edit["new_string"] as? String ?? (edit["new_source"] as? String ?? "")
                let all = edit["replace_all"] as? Bool ?? false
                detail.file(path, at: date) {
                    $0.edits += 1
                    $0.linesAdded += Truncate.lineCount(added)
                    $0.linesRemoved += Truncate.lineCount(removed)
                    $0.changes.append(FileChange(removed: Truncate.text(removed, limit: Truncate.resultLimit),
                                                 added: Truncate.text(added, limit: Truncate.resultLimit)))
                    if let content = $0.content, !removed.isEmpty, let range = content.range(of: removed) {
                        $0.content = all ? content.replacingOccurrences(of: removed, with: added)
                            : content.replacingCharacters(in: range, with: added)
                    }
                }
            }
        default:
            break
        }
    }

    /// String and number inputs, kept whole (up to the content cap) for the stage renderers.
    static func fields(_ input: JSON) -> [String: String] {
        input.reduce(into: [:]) { result, pair in
            if let text = pair.value as? String {
                result[pair.key] = Truncate.text(text, limit: Truncate.contentLimit)
            } else if let number = pair.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                result[pair.key] = number.stringValue
            }
        }
    }

    static func questions(_ input: JSON) -> [AskedQuestion] {
        (input["questions"] as? [JSON] ?? []).compactMap { question in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [JSON] ?? []).compactMap { option -> AskedQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return AskedQuestion.Option(label: label, detail: option["description"] as? String,
                                            preview: (option["preview"] as? String).map { Truncate.text($0, limit: Truncate.resultLimit) })
            }
            return AskedQuestion(header: question["header"] as? String, text: text, options: options,
                                 multiSelect: question["multiSelect"] as? Bool ?? false)
        }
    }

    static func todos(_ input: JSON) -> [TodoItem] {
        (input["todos"] as? [JSON] ?? []).compactMap { todo in
            guard let content = todo["content"] as? String else { return nil }
            let status: TodoItem.Status
            switch todo["status"] as? String {
            case "completed": status = .completed
            case "in_progress": status = .inProgress
            default: status = .pending
            }
            return TodoItem(content: content, status: status, activeForm: todo["activeForm"] as? String)
        }
    }

    static func describe(_ name: String, _ input: JSON) -> (ToolKind, String) {
        func string(_ key: String) -> String? { (input[key] as? String).map(firstLine) }
        switch name {
        case "Read", "NotebookRead": return (.read, string("file_path") ?? string("notebook_path") ?? name)
        case "Write": return (.write, string("file_path") ?? name)
        case "Edit", "MultiEdit", "NotebookEdit": return (.edit, string("file_path") ?? string("notebook_path") ?? name)
        case "Bash", "BashOutput", "KillShell":
            // Heredocs and long pipelines read badly as one line; the agent's own description says what it does.
            let command = input["command"] as? String ?? ""
            let readable = !command.contains("\n") && command.count <= 80
            return (.shell, (readable ? string("command") : nil) ?? string("description") ?? string("command") ?? name)
        case "Grep", "Glob": return (.search, [string("pattern"), string("path")].compactMap { $0 }.joined(separator: "  in  "))
        case "WebFetch": return (.web, string("url") ?? name)
        case "WebSearch": return (.web, string("query") ?? name)
        case "Task", "Agent": return (.agent, string("description") ?? string("subagent_type") ?? name)
        case "TodoWrite":
            let items = todos(input)
            let active = items.first { $0.status == .inProgress }
            let done = items.filter { $0.status == .completed }.count
            return (.todo, active.map { $0.activeForm ?? $0.content } ?? "\(done)/\(items.count)")
        case "Skill": return (.skill, string("skill") ?? string("command") ?? name)
        case "AskUserQuestion":
            let first = (input["questions"] as? [JSON])?.first?["question"] as? String
            return (.question, first ?? name)
        default:
            let value = input.keys.sorted().lazy.compactMap { input[$0] as? String }.first
            return (name.hasPrefix("mcp__") ? .mcp : .other, value.map(firstLine) ?? name)
        }
    }
}

// MARK: - Codex

struct CodexRolloutParser: TranscriptParser {
    private(set) var detail: SessionDetail = {
        var detail = SessionDetail(provider: .codex)
        detail.isInferred = true
        return detail
    }()
    private var toolIndex: [String: Int] = [:]

    mutating func consume(_ line: String) {
        guard let object = decodeLine(line) else { return }
        let date = Timestamp.parse(object["timestamp"])
        let payload = object["payload"] as? JSON ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            detail.touch(Timestamp.parse(payload["timestamp"]) ?? date)
        case "turn_context":
            if let model = payload["model"] as? String { detail.model = model }
        case "event_msg":
            event(payload)
            detail.touch(date)
        case "response_item":
            item(payload, at: date)
            detail.touch(date)
        default:
            break
        }
    }

    private mutating func event(_ payload: JSON) {
        switch payload["type"] as? String {
        case "task_started":
            detail.turns += 1
            if let window = payload["model_context_window"] as? Int { detail.contextWindow = window }
        case "task_complete":
            detail.activeMilliseconds += payload["duration_ms"] as? Int ?? 0
        case "token_count":
            guard let info = payload["info"] as? JSON else { return }
            // Cumulative already; OpenAI counts cached tokens inside input_tokens.
            if let total = info["total_token_usage"] as? JSON {
                let input = total["input_tokens"] as? Int ?? 0
                let cached = total["cached_input_tokens"] as? Int ?? 0
                detail.usage = TokenUsage(input: max(0, input - cached), output: total["output_tokens"] as? Int ?? 0,
                                          cacheRead: cached, cacheWrite: total["cache_write_input_tokens"] as? Int ?? 0,
                                          reasoning: total["reasoning_output_tokens"] as? Int ?? 0)
            }
            if let last = info["last_token_usage"] as? JSON { detail.contextTokens = last["input_tokens"] as? Int ?? 0 }
            if let window = info["model_context_window"] as? Int { detail.contextWindow = window }
        default:
            break
        }
    }

    private mutating func item(_ payload: JSON, at date: Date?) {
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call":
            guard let id = payload["call_id"] as? String, let name = payload["name"] as? String else { return }
            let raw = (payload["arguments"] ?? payload["input"]) as? String ?? ""
            let (kind, summary) = Self.describe(name, raw)
            toolIndex[id] = detail.toolCalls.count
            detail.toolCalls.append(ToolCall(id: id, name: name, kind: kind, summary: summary,
                                             input: Truncate.text(raw, limit: Truncate.resultLimit), startedAt: date))
            recordPatch(raw, at: date)
        case "function_call_output", "custom_tool_call_output":
            guard let id = payload["call_id"] as? String, let index = toolIndex[id] else { return }
            detail.toolCalls[index].result = resultText(payload["output"]).map { Truncate.text($0, limit: Truncate.resultLimit) }
            detail.toolCalls[index].finishedAt = date
        default:
            break
        }
    }

    private static let cmdPattern = try! NSRegularExpression(pattern: #"cmd\s*:\s*"((?:[^"\\]|\\.)*)""#)
    private static let patchFile = try! NSRegularExpression(pattern: #"\*\*\* (Update|Add|Delete) File: ([^\n\\]+)"#)

    static func describe(_ name: String, _ raw: String) -> (ToolKind, String) {
        if let file = patchFiles(raw).first { return (.edit, file.path) }
        if let args = decodeLine(raw) {
            if let command = args["command"] as? [String] { return (.shell, command.last.map(firstLine) ?? name) }
            if let command = (args["cmd"] ?? args["command"]) as? String { return (.shell, firstLine(command)) }
            if name.contains("user_input") { return (.question, name) }
            let value = args.keys.sorted().lazy.compactMap { args[$0] as? String }.first
            return (.other, value.map(firstLine) ?? name)
        }
        let range = NSRange(raw.startIndex..., in: raw)
        if let match = cmdPattern.firstMatch(in: raw, range: range), let cmd = Range(match.range(at: 1), in: raw) {
            return (.shell, firstLine(raw[cmd].replacingOccurrences(of: "\\\"", with: "\"")))
        }
        return (.other, firstLine(raw).prefix(120).description)
    }

    private static func patchFiles(_ raw: String) -> [(action: String, path: String)] {
        patchFile.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { match in
            guard let action = Range(match.range(at: 1), in: raw), let path = Range(match.range(at: 2), in: raw) else { return nil }
            return (String(raw[action]), raw[path].trimmingCharacters(in: .whitespaces))
        }
    }

    /// apply_patch text: count +/- lines per file section.
    private mutating func recordPatch(_ raw: String, at date: Date?) {
        let files = Self.patchFiles(raw)
        guard !files.isEmpty else { return }
        var current: String?
        var counts: [String: (added: Int, removed: Int)] = [:]
        for line in raw.components(separatedBy: "\n") {
            if let file = files.first(where: { line.hasSuffix("File: \($0.path)") }) { current = file.path; continue }
            guard let path = current, !line.hasPrefix("+++"), !line.hasPrefix("---"), !line.hasPrefix("***") else { continue }
            if line.hasPrefix("+") { counts[path, default: (0, 0)].added += 1 }
            if line.hasPrefix("-") { counts[path, default: (0, 0)].removed += 1 }
        }
        for file in files {
            let count = counts[file.path] ?? (0, 0)
            detail.file(file.path, at: date) {
                if file.action == "Add" { $0.writes += 1 } else { $0.edits += 1 }
                $0.linesAdded += count.added
                $0.linesRemoved += count.removed
            }
        }
    }
}
