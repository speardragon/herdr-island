import SwiftUI
import AppKit

// The three tabs of the settings window. Standard grouped forms, like System Settings.

private let paneWidth: CGFloat = 540
private let scrollingPaneHeight: CGFloat = 520

struct GeneralPane: View {
    @ObservedObject var settings: SettingsModel
    let hasNotch: Bool

    private var mode: DisplayMode { settings.config.mode }
    private var usesNotch: Bool { mode == .notch || mode == .both || (mode == .auto && hasNotch) }
    private var usesMenuBar: Bool { mode == .menubar || mode == .both || (mode == .auto && !hasNotch) }

    var body: some View {
        Form {
            Section {
                Picker(L("Show in", "표시 위치"), selection: $settings.config.mode) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text(modeTitle($0)).tag($0) }
                }
                ModePreview(mode: mode, hasNotch: hasNotch, panelPosition: settings.config.panelPosition)
            } footer: {
                Text(modeFooter)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(L("Notch", "노치")) {
                Picker(L("Display", "띄울 화면"), selection: $settings.config.screen) {
                    ForEach(ScreenChoice.allCases, id: \.self) { Text(screenTitle($0)).tag($0) }
                }
                Toggle(isOn: $settings.config.hoverToExpand) {
                    Text(L("Open when the pointer rests on the notch", "노치에 마우스를 올리면 펼치기"))
                    Text(L("You can always click the notch, too.", "꺼도 노치를 클릭하면 펼칠 수 있습니다."))
                }
            }
            .disabled(!usesNotch)

            Section(L("Menu bar panel", "메뉴 막대 패널")) {
                Picker(L("Display", "띄울 화면"), selection: $settings.config.panelScreen) {
                    ForEach(PanelScreen.allCases, id: \.self) { Text(panelScreenTitle($0)).tag($0) }
                }
                Picker(L("Position", "위치"), selection: $settings.config.panelPosition) {
                    ForEach(PanelPosition.allCases, id: \.self) { Text(positionTitle($0)).tag($0) }
                }
            }
            .disabled(!usesMenuBar)

            Section(L("Appearance", "표시")) {
                Toggle(isOn: $settings.config.showWorking) {
                    Text(L("List working agents", "작업 중인 에이전트 목록 보기"))
                    Text(L("Shown below the cards that need you.", "응답이 필요한 카드 아래에 표시합니다."))
                }
                Picker(L("Language", "언어"), selection: $settings.config.language) {
                    Text(L("System", "시스템 설정 따르기")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("한국어").tag(AppLanguage.korean)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        // Taller than a laptop screen allows; the grouped form scrolls inside a fixed height.
        .frame(height: scrollingPaneHeight)
    }

    private var modeFooter: String {
        guard mode == .auto else { return "" }
        return hasNotch
            ? L("This Mac has a notch, so the island lives there.", "이 Mac에는 노치가 있어서 노치에 표시합니다.")
            : L("No notch found, so the island lives in the menu bar.", "노치가 없어서 메뉴 막대에 표시합니다.")
    }

    private func screenTitle(_ screen: ScreenChoice) -> String {
        switch screen {
        case .notch: return L("Display with a notch", "노치가 있는 화면")
        case .main: return L("Main display", "주 화면")
        case .mouse: return L("Display under the pointer", "마우스가 있는 화면")
        case .all: return L("All displays", "모든 화면")
        }
    }

    private func panelScreenTitle(_ screen: PanelScreen) -> String {
        switch screen {
        case .icon: return L("Where the icon was clicked", "아이콘을 누른 화면")
        case .main: return L("Main display", "주 화면")
        case .mouse: return L("Display under the pointer", "마우스가 있는 화면")
        case .all: return L("All displays", "모든 화면")
        }
    }

    private func positionTitle(_ position: PanelPosition) -> String {
        switch position {
        case .icon: return L("Below the icon", "아이콘 아래")
        case .right: return L("Top right", "오른쪽 위")
        case .center: return L("Top center", "가운데 위")
        }
    }
}

func modeTitle(_ mode: DisplayMode) -> String {
    switch mode {
    case .auto: return L("Automatic", "자동")
    case .notch: return L("Notch", "노치")
    case .menubar: return L("Menu bar", "메뉴 막대")
    case .both: return L("Notch + Menu bar", "노치 + 메뉴 막대")
    }
}

/// A small drawing of where the island will appear.
struct ModePreview: View {
    let mode: DisplayMode
    let hasNotch: Bool
    var panelPosition: PanelPosition = .icon

    private var showsNotch: Bool { mode == .notch || mode == .both || (mode == .auto && hasNotch) }
    private var showsMenuBar: Bool { mode == .menubar || mode == .both || (mode == .auto && !hasNotch) }
    private var panelOffset: CGFloat {
        switch panelPosition {
        case .icon: return 52
        case .right: return 66
        case .center: return 0
        }
    }

    var body: some View {
        HStack {
            Spacer()
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.42, blue: 0.62), Color(red: 0.55, green: 0.7, blue: 0.82)],
                                         startPoint: .top, endPoint: .bottom))
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 11)
                HStack(spacing: 4) {
                    Spacer()
                    if showsMenuBar {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Theme.blocked)
                    }
                    Text("12:00").font(.system(size: 6.5, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 6)
                .frame(height: 11)
                if showsNotch {
                    HStack(spacing: 0) {
                        Circle().fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: 5, height: 5).padding(.leading, 5)
                        Spacer()
                        Circle().fill(Theme.blocked).frame(width: 4, height: 4).padding(.trailing, 5)
                    }
                    .frame(width: 64, height: 12)
                    .background(NotchShape(topRadius: 2, bottomRadius: 5).fill(Color.black))
                }
                if showsMenuBar {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 58, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        .offset(x: panelOffset, y: 14)
                }
            }
            .frame(width: 200, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .animation(.easeInOut(duration: 0.2), value: mode)
            .animation(.easeInOut(duration: 0.2), value: panelPosition)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct NotificationsPane: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                StatusRules(expand: $settings.config.expandOnBlocked, autoClose: $settings.config.blockedAutoClose,
                            seconds: $settings.config.blockedPeekSeconds, sound: $settings.config.blockedSound)
            } header: {
                Label(L("When an agent needs you", "에이전트가 응답을 기다릴 때"), systemImage: "hand.raised.fill")
                    .foregroundColor(Theme.blocked)
            } footer: {
                Text(L("Approval prompts and questions (blocked).", "승인 요청과 질문(blocked) 상태입니다."))
                    .font(.footnote).foregroundColor(.secondary)
            }

            Section {
                StatusRules(expand: $settings.config.expandOnDone, autoClose: $settings.config.doneAutoClose,
                            seconds: $settings.config.donePeekSeconds, sound: $settings.config.doneSound)
            } header: {
                Label(L("When an agent finishes", "에이전트가 작업을 끝냈을 때"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(Theme.done)
            }

            Section {
                Toggle(isOn: $settings.config.glowEnabled) {
                    Text(L("Light up the island's edge", "가장자리에 빛 표시"))
                    Text(L("A soft, breathing light while an agent waits for you or has finished.",
                           "응답을 기다리거나 작업을 끝낸 에이전트가 있는 동안 은은하게 숨쉬듯 빛납니다."))
                }
                Group {
                    HexColorRow(title: L("Needs you", "응답 필요"), hex: $settings.config.glowBlockedColor, fallback: Config().glowBlockedColor)
                    HexColorRow(title: L("Done", "완료"), hex: $settings.config.glowDoneColor, fallback: Config().glowDoneColor)
                    LabeledContent(L("Strength", "세기")) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { settings.config.glowIntensity },
                                                  set: { settings.config.glowIntensity = ($0 * 10).rounded() / 10 }),
                                   in: 0.1...1)
                                .frame(width: 180)
                            Text("\(Int((settings.config.glowIntensity * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                .disabled(!settings.config.glowEnabled)
            } header: {
                Text(L("Edge light", "가장자리 빛"))
            }

            Section {
                Toggle(isOn: $settings.config.fadeWhenIdle) {
                    Text(L("Fade while the pointer is away", "마우스가 없으면 투명하게"))
                    Text(L("See what is behind an open island; move the pointer onto it to bring it back.",
                           "열린 섬 뒤를 볼 수 있어요. 마우스를 올리면 다시 또렷해집니다."))
                }
                Group {
                    DurationRow(title: L("After", "투명해지기까지"), seconds: $settings.config.fadeAfterSeconds, range: 1...30, step: 1)
                    LabeledContent(L("Opacity", "남길 불투명도")) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { settings.config.fadeOpacity },
                                                  set: { settings.config.fadeOpacity = ($0 * 20).rounded() / 20 }),
                                   in: 0.1...0.9)
                                .frame(width: 180)
                            Text("\(Int((settings.config.fadeOpacity * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                .disabled(!settings.config.fadeWhenIdle)
            } header: {
                Text(L("Transparency", "투명도"))
            }

            Section {
                Toggle(L("Close when the pointer leaves", "마우스가 벗어나면 닫기"), isOn: $settings.config.closeOnLeave)
                DurationRow(title: L("After", "닫히기까지"), seconds: $settings.config.leaveDelaySeconds, range: 0...5, step: 0.1)
                    .disabled(!settings.config.closeOnLeave)
                Toggle(L("Close when clicking elsewhere", "바깥을 클릭하면 닫기"), isOn: $settings.config.closeOnClickOutside)
                Toggle(isOn: $settings.config.closeWhenClear) {
                    Text(L("Close when nothing needs you", "처리할 에이전트가 없으면 닫기"))
                    Text(L("Only for an island that opened by itself.", "저절로 펼쳐진 경우에만 적용됩니다."))
                }
            } header: {
                Text(L("Closing", "닫기"))
            } footer: {
                Text(L("With everything off, the island stays open until you close it with the toggle action or the menu bar icon.",
                       "모두 끄면 토글 액션이나 메뉴 막대 아이콘으로 직접 닫을 때까지 열려 있습니다."))
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        // Taller than a laptop screen allows; the grouped form scrolls inside a fixed height.
        .frame(height: scrollingPaneHeight)
    }
}

/// Open automatically → close automatically after N seconds (or never) → sound.
struct StatusRules: View {
    @Binding var expand: Bool
    @Binding var autoClose: Bool
    @Binding var seconds: Double
    @Binding var sound: String

    var body: some View {
        Toggle(L("Open the island automatically", "자동으로 펼치기"), isOn: $expand)
        Picker(L("Then", "펼친 뒤"), selection: $autoClose) {
            Text(L("Close after a while", "잠시 후 닫기")).tag(true)
            Text(L("Keep open", "닫지 않기")).tag(false)
        }
        .disabled(!expand)
        DurationRow(title: L("Keep open for", "펼쳐 둘 시간"), seconds: $seconds, range: 2...60, step: 1)
            .disabled(!expand || !autoClose)
        SoundPicker(selection: $sound)
    }
}

struct DurationRow: View {
    let title: String
    @Binding var seconds: Double
    var range: ClosedRange<Double> = 2...30
    var step: Double = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                // Rounded in the binding rather than `step:`, which draws a row of tick marks.
                Slider(value: Binding(get: { seconds }, set: { seconds = ($0 / step).rounded() * step }), in: range)
                    .frame(width: 180)
                Text(label)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var label: String {
        let value = step < 1 ? String(format: "%.1f", seconds) : String(Int(seconds))
        return L("\(value)s", "\(value)초")
    }
}

/// A color well bound to an "RRGGBB" config value, with a reset to the default.
struct HexColorRow: View {
    let title: String
    @Binding var hex: String
    let fallback: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if hex != fallback {
                    Button(L("Reset", "기본값")) { hex = fallback }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Text("#\(hex)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
                ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString }),
                            supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }
}

struct SoundPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker(L("Sound", "소리"), selection: $selection) {
            Text(L("None", "없음")).tag("none")
            Divider()
            ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
        }
        // Preview the sound as it is picked, like System Settings does.
        .onChange(of: selection) { SystemSounds.play($0) }
    }
}

struct AboutPane: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var store: AgentStore
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInfo.name).font(.system(size: 17, weight: .semibold))
                        Text(L("Version \(AppInfo.version)", "버전 \(AppInfo.version)"))
                            .font(.callout).foregroundColor(.secondary)
                        Text(L("Your herdr agents, living in the notch.", "herdr 에이전트가 노치에 삽니다."))
                            .font(.callout).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                LabeledContent(L("herdr", "herdr 연결")) {
                    HStack(spacing: 6) {
                        Circle().fill(store.connected ? Theme.done : Theme.danger).frame(width: 7, height: 7)
                        Text(store.connected
                             ? L("Connected · \(store.agents.count) agents", "연결됨 · 에이전트 \(store.agents.count)개")
                             : L("Not connected", "연결 안 됨"))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(L("Files", "파일")) {
                LabeledContent(L("Settings file", "설정 파일")) {
                    HStack {
                        Button(L("Open", "열기")) { openInEditor(Config.fileURL) }
                            .disabled(!FileManager.default.fileExists(atPath: Config.fileURL.path))
                        Button(L("Show in Finder", "Finder에서 보기")) { reveal(Config.fileURL) }
                    }
                }
                LabeledContent(L("Log", "로그")) {
                    Button(L("Show in Finder", "Finder에서 보기")) { reveal(AppInfo.logURL) }
                }
                if let error = settings.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.danger)
                        .font(.footnote)
                }
            }

            Section {
                HStack {
                    Button(L("Restore Defaults…", "기본값으로 되돌리기…")) { confirmReset = true }
                    Spacer()
                    Button(L("Quit Herdr Island", "Herdr Island 종료")) { NSApp.terminate(nil) }
                }
            } footer: {
                Text(L("Provider marks: LobeHub Icons (MIT). Terminal focus adapted from herdr-glow (MIT).",
                       "프로바이더 로고: LobeHub Icons(MIT). 터미널 포커스 로직은 herdr-glow(MIT)를 참고했습니다."))
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
        .alert(L("Restore default settings?", "설정을 기본값으로 되돌릴까요?"), isPresented: $confirmReset) {
            Button(L("Restore", "되돌리기"), role: .destructive) { settings.resetToDefaults() }
            Button(L("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(L("Comments and other lines in config.toml are kept.", "config.toml의 주석과 다른 항목은 그대로 둡니다."))
        }
    }

    /// .toml often has no default app; fall back to TextEdit.
    private func openInEditor(_ url: URL) {
        guard !NSWorkspace.shared.open(url),
              let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

/// The app's mark: a black island with a status dot, drawn rather than shipped as a file.
struct AppMark: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            Capsule()
                .fill(Color.black)
                .frame(width: size * 0.62, height: size * 0.22)
                .overlay(
                    HStack {
                        Circle().fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: size * 0.09)
                        Spacer()
                        Circle().fill(Theme.blocked).frame(width: size * 0.08)
                    }
                    .padding(.horizontal, size * 0.06)
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .offset(y: -size * 0.16)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
