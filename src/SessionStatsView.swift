import SwiftUI

// Headline numbers for a session: a KPI row, the token composition as one stacked bar,
// and meters for cache hits and context use. Series colors are the dataviz reference
// palette's dark steps, validated against the card surface (#0f0f0f).

enum SeriesColor {
    static let cacheRead = Color(hex: "3987E5")
    static let cacheWrite = Color(hex: "D95926")
    static let input = Color(hex: "199E70")
    static let output = Color(hex: "C98500")
}

enum Format {
    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: v >= 10_000_000 ? "%.0fM" : "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: v >= 10_000 ? "%.0fK" : "%.1fK", v / 1_000)
        default: return "\(value)"
        }
    }

    static func percent(_ value: Double) -> String {
        value >= 0.995 || value < 0.1 ? String(format: "%.1f%%", value * 100) : String(format: "%.0f%%", value * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return L("\(s)s", "\(s)초") }
        if s < 3600 { return L("\(s / 60)m \(s % 60)s", "\(s / 60)분 \(s % 60)초") }
        return L("\(s / 3600)h \(s % 3600 / 60)m", "\(s / 3600)시간 \(s % 3600 / 60)분")
    }

    static func toolDuration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0fms", seconds * 1000) : seconds < 60 ? String(format: "%.1fs", seconds) : duration(seconds)
    }
}

struct SessionStatsView: View {
    let detail: SessionDetail

    var body: some View {
        VStack(spacing: 10) {
            kpiRow
            TokenCompositionCard(usage: detail.usage)
            HStack(spacing: 8) {
                MeterCard(title: L("Cache hits", "캐시 히트"),
                          value: detail.usage.cacheHitRate.map(Format.percent) ?? "–",
                          fraction: detail.usage.cacheHitRate ?? 0,
                          caption: L("of prompt tokens read from cache", "프롬프트 토큰 중 캐시에서 읽은 비율"))
                contextMeter
            }
        }
    }

    private var kpiRow: some View {
        HStack(spacing: 8) {
            StatTile(label: L("Tokens", "토큰"), value: Format.tokens(detail.usage.total),
                     caption: L("out \(Format.tokens(detail.usage.output))", "출력 \(Format.tokens(detail.usage.output))"))
            StatTile(label: L("Active time", "작업 시간"), value: Format.duration(Double(detail.activeMilliseconds) / 1000),
                     caption: L("\(detail.turns) turns", "턴 \(detail.turns)회"))
            StatTile(label: L("Tool calls", "도구 호출"), value: "\(detail.toolCalls.count)",
                     caption: detail.toolHistogram.first.map { "\($0.name) ×\($0.count)" } ?? "–")
            StatTile(label: L("Files changed", "수정한 파일"), value: "\(detail.modifiedFiles.count)",
                     caption: L("\(detail.readFiles.count) read", "읽은 파일 \(detail.readFiles.count)"))
        }
    }

    @ViewBuilder private var contextMeter: some View {
        if let window = detail.contextWindow, window > 0 {
            MeterCard(title: L("Context", "컨텍스트"),
                      value: "\(Format.tokens(detail.contextTokens)) / \(Format.tokens(window))",
                      fraction: min(1, Double(detail.contextTokens) / Double(window)),
                      caption: L("latest prompt vs. window", "마지막 요청 / 컨텍스트 창"))
        } else {
            // Claude Code does not record the window size, so show the size alone rather than guess.
            MeterCard(title: L("Context", "컨텍스트"), value: Format.tokens(detail.contextTokens), fraction: nil,
                      caption: L("tokens in the latest prompt", "마지막 요청의 프롬프트 토큰"))
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Theme.tertiaryText)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// Part-to-whole: one stacked bar (2pt gaps, rounded ends) and a legend that carries the numbers.
struct TokenCompositionCard: View {
    let usage: TokenUsage

    private var segments: [(label: String, value: Int, color: Color)] {
        [
            (L("Cache read", "캐시 읽기"), usage.cacheRead, SeriesColor.cacheRead),
            (L("Cache write", "캐시 쓰기"), usage.cacheWrite, SeriesColor.cacheWrite),
            (L("Input", "입력"), usage.input, SeriesColor.input),
            (L("Output", "출력"), usage.output, SeriesColor.output),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("Token mix", "토큰 구성"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                Spacer()
                Text(Format.tokens(usage.total))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundColor(Theme.secondaryText)
            }
            bar
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(segments, id: \.label) { segment in
                    legendRow(segment)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var bar: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.value > 0 }
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            let total = max(1, visible.reduce(0) { $0 + $1.value })
            HStack(spacing: 2) {
                ForEach(visible, id: \.label) { segment in
                    // Tiny shares stay visible as a sliver instead of vanishing.
                    let width = max(3, (geo.size.width - gaps) * CGFloat(segment.value) / CGFloat(total))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.color)
                        .frame(width: width)
                        .help("\(segment.label) \(Format.tokens(segment.value)) · \(Format.percent(share(segment.value)))")
                }
            }
        }
        .frame(height: 10)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func legendRow(_ segment: (label: String, value: Int, color: Color)) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 8, height: 8)
            Text(segment.label)
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryText)
            Spacer(minLength: 4)
            Text(Format.tokens(segment.value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.primaryText)
            Text(Format.percent(share(segment.value)))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(Theme.tertiaryText)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func share(_ value: Int) -> Double {
        usage.total > 0 ? Double(value) / Double(usage.total) : 0
    }
}

/// A single ratio against its limit, drawn on a track of the same hue.
struct MeterCard: View {
    let title: String
    let value: String
    let fraction: Double?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.primaryText)
            }
            if let fraction = fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SeriesColor.cacheRead.opacity(0.18))
                        Capsule().fill(SeriesColor.cacheRead)
                            .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                    }
                }
                .frame(height: 6)
            }
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.tertiaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
