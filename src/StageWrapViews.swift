import SwiftUI

// Long commands and code lines scroll sideways by default; the wrap toggle in the live
// stage's header folds them to the stage's width instead. The choice is `stage.wrap_lines`
// in config.toml, handed down through the environment so every text stage follows it.

private struct StageWrapKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var stageWrap: Binding<Bool> {
        get { self[StageWrapKey.self] }
        set { self[StageWrapKey.self] = newValue }
    }
}

/// Lines keep their full width when scrolling sideways and fold to the stage when wrapping.
struct StageLineFit: ViewModifier {
    @Environment(\.stageWrap) private var wrap

    func body(content: Content) -> some View {
        content.fixedSize(horizontal: !wrap.wrappedValue, vertical: true)
    }
}

extension View {
    func stageLineFit() -> some View { modifier(StageLineFit()) }

    /// Content of a stage's scroll area: at least the visible size, and exactly its width when wrapping.
    func stageCanvasFrame(_ size: CGSize, wrap: Bool) -> some View {
        frame(minWidth: wrap ? nil : size.width, maxWidth: wrap ? size.width : nil, alignment: .topLeading)
            .frame(minHeight: size.height, alignment: .topLeading)
    }
}

/// The header button that switches the stage between wrapping and sideways scrolling.
struct WrapToggle: View {
    @Binding var wrap: Bool

    var body: some View {
        Button { wrap.toggle() } label: {
            Label(L("Wrap", "줄바꿈"), systemImage: "arrow.turn.down.left")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(wrap ? .black : Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(wrap ? Color.white.opacity(0.9) : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(wrap ? L("Scroll long lines sideways", "긴 줄을 가로로 스크롤해서 보기")
                   : L("Wrap long lines to the stage's width", "긴 줄을 화면 너비에 맞춰 줄바꿈"))
    }
}

/// Numbered lines for a wrapped stage: one row per source line, so a folded line keeps its number beside it.
struct WrappedGutterText: View {
    let text: String
    let firstLine: Int
    let caret: Bool
    let fontSize: CGFloat

    var body: some View {
        let rows = StageWrap.numberedRows(text, firstLine: firstLine)
        let lastNumber = rows.last?.number ?? firstLine
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.number) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(row.number))
                        .foregroundColor(Theme.tertiaryText.opacity(0.7))
                        .frame(width: numberWidth(lastNumber), alignment: .trailing)
                    let showsCaret = caret && row.number == lastNumber
                    (Text(row.text.isEmpty && !showsCaret ? " " : row.text)
                        + Text(showsCaret ? "▍" : "").foregroundColor(Theme.working))
                        .foregroundColor(Theme.primaryText.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 10)
    }

    /// Wide enough for the largest number in a monospaced font, never narrower than the scrolling gutter.
    private func numberWidth(_ number: Int) -> CGFloat {
        max(34, CGFloat(String(number).count) * fontSize * 0.62)
    }
}
