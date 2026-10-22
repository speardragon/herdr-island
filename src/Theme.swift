import SwiftUI
import AppKit

enum Theme {
    static let background = Color.black
    static let card = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.08)
    static let row = Color.white.opacity(0.07)
    static let rowHover = Color.white.opacity(0.13)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.4)

    // Follow the edge-light colors so dots, labels and the glow always agree.
    private(set) static var blocked = Color(hex: Config().glowBlockedColor)
    private(set) static var done = Color(hex: Config().glowDoneColor)
    static let working = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let idle = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)

    static let expandedWidth: CGFloat = 500
    /// The card column inside the island (expandedWidth minus its padding).
    static let listWidth: CGFloat = expandedWidth - 28
    static let detailGutter: CGFloat = 29
    static let detailPaneWidth: CGFloat = 520
    /// Island width while an agent's detail pane is open.
    static let detailWidth: CGFloat = listWidth + detailGutter + detailPaneWidth + 28
    static let detailHeight: CGFloat = 560

    /// The full-size live stage: as large as the display comfortably allows.
    static func stageSize(for screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        return CGSize(width: min(max(visible.width - 160, detailWidth), 1320),
                      height: min(max(visible.height - 130, detailHeight), 820))
    }
    static let maxContentHeight: CGFloat = 600
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    static func apply(_ config: Config) {
        blocked = Color(hex: config.glowBlockedColor)
        done = Color(hex: config.glowDoneColor)
    }

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .blocked: return blocked
        case .done: return done
        case .working: return working
        case .idle, .unknown: return idle
        }
    }

    static func statusLabel(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: return L("Needs you", "응답 필요")
        case .done: return L("Done", "완료")
        case .working: return L("Working", "작업 중")
        case .idle: return L("Idle", "대기")
        case .unknown: return L("Unknown", "알 수 없음")
        }
    }
}

func relativeTime(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 10 { return L("now", "방금") }
    if seconds < 60 { return L("\(seconds)s", "\(seconds)초") }
    if seconds < 3600 { return L("\(seconds / 60)m", "\(seconds / 60)분") }
    return L("\(seconds / 3600)h", "\(seconds / 3600)시간")
}
