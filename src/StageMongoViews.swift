import SwiftUI

// A MongoDB call drawn like a database viewer: the namespace, the query (or pipeline), then the
// documents as cards of typed fields. Type colors follow MongoDB Compass's dark theme; surfaces
// stay the island's own black and white tints.

enum MongoPalette {
    static let string = Color(hex: "35DE7B")
    static let number = Color(hex: "2DC4FF")
    static let bool = Color(hex: "FF7DC3")
    static let objectId = Color(hex: "FF6F44")
    static let null = Color(hex: "889397")
    static let accent = Color(hex: "00ED64")

    static func color(_ kind: BsonKind) -> Color {
        switch kind {
        case .string: return string
        case .number, .date: return number
        case .bool: return bool
        case .objectId: return objectId
        case .null, .other: return null
        case .object, .array: return Theme.secondaryText
        }
    }

    /// mongosh-style query text in the same colors as the documents.
    static func attributed(_ tokens: [Token], size: CGFloat) -> AttributedString {
        tokens.reduce(into: AttributedString()) { result, token in
            var run = AttributedString(token.text)
            run.font = .system(size: size, weight: token.kind == .key ? .semibold : .regular, design: .monospaced)
            switch token.kind {
            case .key: run.foregroundColor = Theme.primaryText.opacity(0.92)
            case .string: run.foregroundColor = string
            case .number: run.foregroundColor = number
            case .literal: run.foregroundColor = bool
            default: run.foregroundColor = Theme.tertiaryText
            }
            result.append(run)
        }
    }
}

/// Parsed once per result; the stage redraws far more often than results change.
enum MongoViewCache {
    private static var entries: [String: MongoView] = [:]

    static func view(for call: ToolCall) -> MongoView? {
        let key = "\(call.id):\(call.result?.utf8.count ?? -1):\(call.isError)"
        if let cached = entries[key] { return cached }
        guard let view = MongoView(call: call) else { return nil }
        if entries.count > 40 { entries.removeAll() }
        entries[key] = view
        return view
    }
}

struct MongoStage: View {
    let call: ToolCall
    let view: MongoView
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !view.query.pipeline.isEmpty {
                MongoPipeline(stages: view.query.pipeline, large: large)
            } else if view.query.filter != nil || !view.query.options.isEmpty {
                MongoQueryBar(query: view.query, large: large)
            }
            result
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(MongoPalette.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MongoPalette.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                breadcrumb
                HStack(spacing: 6) {
                    Text(view.tool.tool)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.18)))
                    Text(view.tool.server)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            ToolStatusPill(call: call)
            ElapsedText(since: call.startedAt, until: call.finishedAt)
        }
    }

    /// `database › collection`, the collection in front.
    private var breadcrumb: some View {
        let parts = [view.query.database, view.query.collection].compactMap { $0 }
        var text = Text(parts.isEmpty ? view.tool.tool : "")
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            if index > 0 { text = text + Text("  ›  ").foregroundColor(Theme.tertiaryText) }
            text = text + Text(part).fontWeight(last ? .semibold : .regular)
                .foregroundColor(last ? Theme.primaryText : Theme.secondaryText)
        }
        return text.font(.system(size: 14)).foregroundColor(Theme.primaryText).lineLimit(1).truncationMode(.head)
    }

    @ViewBuilder private var result: some View {
        switch view.result {
        case .documents(let list)?:
            MongoDocumentList(call: call, list: list, large: large)
        case .count(let count)?:
            MongoCountCard(count: count, large: large)
            Spacer(minLength: 0)
        case .names(let names)?:
            MongoNameGrid(title: view.tool.tool.contains("database") ? L("Databases", "데이터베이스") : L("Collections", "컬렉션"),
                          names: names, large: large)
        case nil:
            if let text = call.result {
                // Other JSON (schemas, connections) keeps the generic summary; text and errors show as they are.
                if !call.isError, let digest = DigestCache.digest(for: call.id, text: text) {
                    ResultDigestView(digest: digest, large: large)
                } else {
                    ResultText(callId: call.id, text: text, isError: call.isError, large: large)
                }
            } else if call.finishedAt == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(L("Querying…", "조회하는 중…"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            } else {
                Text(L("No result", "결과 없음")).font(.system(size: 12)).foregroundColor(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Query

private struct MongoQueryBar: View {
    let query: MongoQuery
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Filter")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 44, alignment: .leading)
                filterText
                    .lineLimit(large ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.05)))
            }
            if !query.options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(query.options.enumerated()), id: \.offset) { _, option in
                        (Text(option.label + " ").foregroundColor(Theme.tertiaryText)
                            + Text(option.value).foregroundColor(Theme.primaryText.opacity(0.85)))
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
                .padding(.leading, 54)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private var filterText: Text {
        let size: CGFloat = large ? 12 : 11
        guard let filter = query.filter, filter != .object([]) else {
            return Text(L("{} (all documents)", "{} (모든 문서)")).font(.system(size: size, design: .monospaced))
                .foregroundColor(Theme.tertiaryText)
        }
        return Text(MongoPalette.attributed(MongoShell.tokens(filter), size: size))
    }
}

private struct MongoPipeline: View {
    let stages: [MongoQuery.Stage]
    let large: Bool
    @State private var open: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Pipeline").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.primaryText)
                Text(L("\(stages.count) stages", "\(stages.count)단계")).font(.system(size: 11)).foregroundColor(Theme.tertiaryText)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in stageRow(index, stage) }
                }
            }
            .frame(maxHeight: large ? 200 : 120)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stageRow(_ index: Int, _ stage: MongoQuery.Stage) -> some View {
        let expanded = open.contains(index)
        return Button {
            open = expanded ? open.subtracting([index]) : open.union([index])
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.tertiaryText)
                    .frame(width: 14, alignment: .trailing)
                Text(stage.op)
                    .font(.system(size: large ? 12 : 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(MongoPalette.accent.opacity(0.9))
                Text(MongoPalette.attributed(MongoShell.tokens(stage.body), size: large ? 11.5 : 10.5))
                    .lineLimit(expanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Results

private struct MongoDocumentList: View {
    let call: ToolCall
    let list: MongoDocuments
    let large: Bool
    @State private var json = false
    @State private var shown = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(list.documents.prefix(shown).enumerated()), id: \.offset) { _, doc in
                        MongoDocumentCard(document: doc, json: json, large: large)
                    }
                    if list.documents.count > shown {
                        Button(L("Show \(min(50, list.documents.count - shown)) more", "\(min(50, list.documents.count - shown))개 더 보기")) {
                            shown += 50
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(MongoPalette.number)
                        .padding(.vertical, 4)
                    }
                    if list.documents.isEmpty {
                        Text(L("No documents matched", "일치하는 문서가 없어요"))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.tertiaryText)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(MongoTool(name: call.name)?.tool == "aggregate" ? L("Results", "결과") : L("Documents", "문서"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.primaryText)
            Text(range)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.tertiaryText)
                .lineLimit(1)
            Spacer()
            RawToggle(raw: $json, labels: (L("List", "목록"), "JSON"))
        }
    }

    /// `1 – 10 of 42`, saying when the agent got fewer than matched or the text was cut.
    private var range: String {
        let count = list.documents.count
        guard count > 0 else { return L("0 of \(list.total)", "전체 \(list.total)개 중 0개") }
        var text = L("1 – \(count) of \(list.total)", "전체 \(list.total)개 중 1–\(count)")
        if list.truncated { text += L(" · rest cut short", " · 나머지는 잘림") }
        return text
    }
}

private struct MongoDocumentCard: View {
    let document: Bson
    let json: Bool
    let large: Bool
    @State private var fieldsShown = 25

    var body: some View {
        Group {
            if json {
                Text(MongoJSON.attributed(document, size: large ? 11.5 : 10.5))
                    .lineLimit(large ? 60 : 30)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(document.children.prefix(fieldsShown).enumerated()), id: \.offset) { _, field in
                        MongoFieldRow(field: field, depth: 0, large: large)
                    }
                    if document.children.count > fieldsShown {
                        Button(L("Show \(document.children.count - fieldsShown) more fields",
                                 "필드 \(document.children.count - fieldsShown)개 더 보기")) { fieldsShown += 1_000 }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(MongoPalette.number)
                            .padding(.leading, 18)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

/// `key: value` with a caret for objects and arrays, which open in place (closed at first).
private struct MongoFieldRow: View {
    let field: BsonField
    let depth: Int
    let large: Bool
    @State private var expanded = false
    @State private var hovered = false

    private var expandable: Bool { !field.value.children.isEmpty }
    private var isIndex: Bool { Int(field.key) != nil && depth > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { if expandable { expanded.toggle() } } label: { row }
                .buttonStyle(.plain)
            if expanded {
                ForEach(Array(field.value.children.prefix(500).enumerated()), id: \.offset) { _, child in
                    AnyView(MongoFieldRow(field: child, depth: depth + 1, large: large))
                }
            }
        }
    }

    private var row: some View {
        let size: CGFloat = large ? 12 : 11
        return HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.tertiaryText)
                .frame(width: 14)
                .opacity(expandable ? 1 : 0)
            (Text(field.key).fontWeight(isIndex ? .regular : .bold)
                .foregroundColor(isIndex ? Theme.tertiaryText : Theme.primaryText.opacity(0.92))
                + Text(": ").foregroundColor(Theme.tertiaryText)
                + Text(field.value.display).foregroundColor(MongoPalette.color(field.value.kind)))
                .font(.system(size: size, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 3).fill(hovered ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(field.value.display)
    }
}

/// A document as indented relaxed JSON, colored by type.
enum MongoJSON {
    static func attributed(_ value: Bson, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        append(value, indent: 0, into: &out, size: size)
        return out
    }

    private static func append(_ value: Bson, indent: Int, into out: inout AttributedString, size: CGFloat) {
        func put(_ text: String, _ color: Color, bold: Bool = false) {
            var run = AttributedString(text)
            run.font = .system(size: size, weight: bold ? .semibold : .regular, design: .monospaced)
            run.foregroundColor = color
            out.append(run)
        }
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch value {
        case .scalar(let kind, let text):
            put(text, MongoPalette.color(kind))
        case .object(let fields):
            guard !fields.isEmpty else { return put("{}", Theme.tertiaryText) }
            put("{\n", Theme.tertiaryText)
            for (index, field) in fields.enumerated() {
                put(pad + field.key, Theme.primaryText.opacity(0.92), bold: true)
                put(": ", Theme.tertiaryText)
                append(field.value, indent: indent + 1, into: &out, size: size)
                put(index < fields.count - 1 ? ",\n" : "\n", Theme.tertiaryText)
            }
            put(close + "}", Theme.tertiaryText)
        case .array(let items):
            guard !items.isEmpty else { return put("[]", Theme.tertiaryText) }
            put("[\n", Theme.tertiaryText)
            for (index, item) in items.enumerated() {
                put(pad, Theme.tertiaryText)
                append(item, indent: indent + 1, into: &out, size: size)
                put(index < items.count - 1 ? ",\n" : "\n", Theme.tertiaryText)
            }
            put(close + "]", Theme.tertiaryText)
        }
    }
}

private struct MongoCountCard: View {
    let count: Int
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("COUNT")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundColor(Theme.tertiaryText)
            Text(count.formatted())
                .font(.system(size: large ? 34 : 28, weight: .semibold).monospacedDigit())
                .foregroundColor(MongoPalette.number)
            Text(L("matching documents", "조건에 맞는 문서"))
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 160, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

private struct MongoNameGrid: View {
    let title: String
    let names: [String]
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.primaryText)
                Text(L("\(names.count)", "\(names.count)개")).font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.tertiaryText)
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 190 : 140), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundColor(MongoPalette.accent.opacity(0.8))
                            Text(name)
                                .font(.system(size: large ? 12 : 11, design: .monospaced))
                                .foregroundColor(Theme.primaryText.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
