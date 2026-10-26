import SwiftUI

// A tool result drawn from its digest: the records of its main list, or an object's fields.
// Rows are lazy and capped, so a thousand-item search stays smooth.

/// Digests are built once per result; the stage redraws far more often than results change.
enum DigestCache {
    private static var entries: [String: ResultDigest?] = [:]

    static func digest(for callId: String, text: String) -> ResultDigest? {
        let key = "\(callId):\(text.count)"
        if let cached = entries[key] { return cached }
        let digest = ResultDigest.make(text)
        if entries.count > 60 { entries.removeAll() }
        entries[key] = digest
        return digest
    }
}

struct RawToggle: View {
    @Binding var raw: Bool

    var body: some View {
        HStack(spacing: 2) {
            option(L("Summary", "요약"), selected: !raw) { raw = false }
            option(L("Raw", "원본"), selected: raw) { raw = true }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(selected ? Theme.primaryText : Theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.white.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

struct ResultDigestView: View {
    let digest: ResultDigest
    let large: Bool

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let preface = digest.preface {
                    Text(preface)
                        .font(.system(size: large ? 12.5 : 11.5))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(3)
                }
                if !digest.facts.isEmpty { facts }
                if let collection = digest.collection {
                    collectionHeader(collection)
                    ForEach(Array(collection.records.enumerated()), id: \.offset) { _, record in
                        RecordRow(record: record, large: large)
                    }
                    if collection.total > collection.records.count {
                        Text(L("\(collection.total - collection.records.count) more — see Raw",
                               "\(collection.total - collection.records.count)개 더 있음 · 원본에서 확인"))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.tertiaryText)
                            .padding(.top, 2)
                    }
                } else {
                    ForEach(Array(digest.fields.enumerated()), id: \.offset) { _, field in fieldRow(field) }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }

    private var facts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(digest.facts.enumerated()), id: \.offset) { _, fact in
                    (Text(fact.label + " ").foregroundColor(Theme.tertiaryText) + Text(fact.value).foregroundColor(Theme.primaryText))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
            }
        }
    }

    private func collectionHeader(_ collection: ResultDigest.Collection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .semibold))
            Text(collection.name.isEmpty ? L("Items", "항목") : collection.name)
                .font(.system(size: 12, weight: .semibold))
            Text(L("\(collection.total)", "\(collection.total)개"))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(Theme.tertiaryText)
        }
        .foregroundColor(Theme.secondaryText)
    }

    private func fieldRow(_ field: ResultDigest.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(field.label)
                .font(.system(size: large ? 12 : 11, design: .monospaced))
                .foregroundColor(HighlightStyle.soft)
                .frame(width: large ? 170 : 120, alignment: .trailing)
                .lineLimit(1)
                .truncationMode(.head)
            Text(field.value)
                .font(.system(size: large ? 13 : 12))
                .foregroundColor(Theme.primaryText.opacity(0.9))
                .lineLimit(large ? 6 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecordRow: View {
    let record: ResultDigest.Record
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if record.title != nil || record.badge != nil || record.status != nil { headline }
            if record.title == nil {
                fieldList
            } else if let subtitle = record.subtitle {
                Text(subtitle)
                    .font(.system(size: large ? 12.5 : 11.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(2)
            }
            if record.title != nil, !record.meta.isEmpty {
                Text(record.meta.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  "))
                    .font(.system(size: large ? 11.5 : 10.5).monospacedDigit())
                    .foregroundColor(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let badge = record.badge {
                Text(badge)
                    .font(.system(size: large ? 11.5 : 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(HighlightStyle.soft)
            }
            if let title = record.title {
                Text(title)
                    .font(.system(size: large ? 13.5 : 12.5, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if let status = record.status { StatusChip(text: status) }
        }
    }

    /// A row with nothing like a title (a database document): its fields, one per line.
    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if record.meta.isEmpty && record.badge == nil && record.status == nil {
                Text(L("(only ids and links)", "(id·링크만 있는 항목)"))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.tertiaryText)
            }
            ForEach(Array(record.meta.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.label)
                        .font(.system(size: large ? 11.5 : 10.5, design: .monospaced))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(1)
                    Text(field.value)
                        .font(.system(size: large ? 12.5 : 11.5, design: .monospaced))
                        .foregroundColor(Theme.primaryText.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

/// Finished-sounding states read green, ongoing ones blue, the rest neutral.
private struct StatusChip: View {
    let text: String

    private var color: Color {
        let lower = text.lowercased()
        if ["done", "closed", "resolved", "complete", "success", "merged", "완료", "해결"].contains(where: lower.contains) {
            return Theme.done
        }
        if ["progress", "review", "running", "active", "open", "진행", "검토"].contains(where: lower.contains) {
            return Theme.working
        }
        return Theme.secondaryText
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
