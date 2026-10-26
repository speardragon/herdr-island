import SwiftUI

// AskUserQuestion as a form: every question with its options, and once answered,
// the picked options lit up, any typed answer and the user's notes.

struct QuestionStage: View {
    let call: ToolCall
    let large: Bool

    private enum Phase { case waiting, answered, declined }

    private var phase: Phase {
        if call.finishedAt == nil { return .waiting }
        return call.isError || call.questions.allSatisfy { $0.answer == nil } ? .declined : .answered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(call.questions.enumerated()), id: \.offset) { _, question in
                        QuestionCard(question: question, answered: phase == .answered, large: large)
                    }
                }
            }
        }
        .frame(maxWidth: large ? 860 : .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.primaryText)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            Text(call.questions.count > 1 ? L("\(call.questions.count) questions", "질문 \(call.questions.count)개") : L("Question", "질문"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.primaryText)
            Spacer(minLength: 8)
            phasePill
            ElapsedText(since: call.startedAt, until: call.finishedAt)
        }
    }

    private var phasePill: some View {
        let (title, color): (String, Color) = {
            switch phase {
            case .waiting: return (L("Waiting for your answer", "답을 기다리는 중"), Theme.blocked)
            case .answered: return (L("Answered", "답함"), Theme.done)
            case .declined: return (L("Not answered", "답하지 않음"), Theme.tertiaryText)
            }
        }()
        return HStack(spacing: 5) {
            if phase == .waiting { StatusDot(status: .blocked, size: 6) }
            if phase == .answered { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)) }
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct QuestionCard: View {
    let question: AskedQuestion
    /// False while waiting and after a decline: nothing is lit up or dimmed.
    let answered: Bool
    let large: Bool

    private var answer: QuestionAnswer { QuestionAnswer.resolve(question) }

    var body: some View {
        let answer = self.answer
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let header = question.header, !header.isEmpty { chip(header, prominent: true) }
                if question.multiSelect { chip(L("Pick any", "여러 개 선택"), prominent: false) }
                Spacer(minLength: 0)
            }
            Text(question.text)
                .font(.system(size: large ? 15.5 : 14, weight: .semibold))
                .foregroundColor(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(option, number: index + 1, picked: answer.picked.contains(option.label))
                }
                if let typed = answer.typed { typedRow(typed) }
            }
            if let notes = question.notes, !notes.isEmpty { notesRow(notes) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }

    private func chip(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(prominent ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(prominent ? 0.12 : 0.06)))
    }

    private func optionRow(_ option: AskedQuestion.Option, number: Int, picked: Bool) -> some View {
        let dimmed = answered && !picked
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                indicator(picked: picked)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.system(size: large ? 14 : 13, weight: picked ? .semibold : .medium))
                        .foregroundColor(Theme.primaryText.opacity(dimmed ? 0.5 : 1))
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: large ? 12.5 : 11.5))
                            .foregroundColor(Theme.secondaryText.opacity(dimmed ? 0.6 : 1))
                            .lineLimit(large ? 4 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.tertiaryText)
            }
            // The preview the user saw beside the option they chose.
            if picked, let preview = option.preview, !preview.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(preview)
                        .font(.system(size: large ? 11.5 : 10.5, design: .monospaced))
                        .foregroundColor(Theme.primaryText.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .frame(maxHeight: large ? 200 : 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.45)))
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight(picked))
    }

    private func indicator(picked: Bool) -> some View {
        let symbol = question.multiSelect ? (picked ? "checkmark.square.fill" : "square")
            : (picked ? "checkmark.circle.fill" : "circle")
        return Image(systemName: symbol)
            .font(.system(size: large ? 15 : 14, weight: .medium))
            .foregroundColor(picked ? Theme.done : Theme.tertiaryText)
            .frame(width: 16)
    }

    private func typedRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "pencil")
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundColor(Theme.done)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Typed answer", "직접 입력"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                Text(text)
                    .font(.system(size: large ? 14 : 13, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight(true))
    }

    private func notesRow(_ notes: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
            Text(notes)
                .font(.system(size: large ? 12.5 : 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Theme.secondaryText)
        .padding(.horizontal, 4)
    }

    private func highlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(on ? Theme.done.opacity(0.13) : Color.white.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Theme.done.opacity(0.45) : Color.clear))
    }
}
