import Foundation

// A side panel drawn next to the agent (a file explorer, a diff) shares every screen row
// with it behind a vertical divider. The parser must read the agent's side only.

/// Pads `left` to `column` display cells, then draws the divider and `right`.
func besidePanel(_ left: String, _ right: String, column: Int) -> String {
    let pad = max(0, column - ScreenRegions.displayWidth(left))
    return left + String(repeating: " ", count: pad) + "│" + right
}

/// The agent's UI narrows to make room, so the divider sits right of its widest row.
func withSidePanel(_ screen: String) -> String {
    let rows = screen.components(separatedBy: "\n")
    let column = (rows.map(ScreenRegions.displayWidth).max() ?? 0) + 2
    let panel = ["   Explorer   │  CHANGES  4 files  +128 −1", "─────────────────────────────",
                 " EXPLORER                  │  src › 설정.swift +1 −1", "   src/                    ││ @@ -1,1 +1,1 @@",
                 "      main.swift        A ││ 1    - \"[]\"", "      설정.swift        M ││    1 + [{\"a\":1}]"]
    return rows.enumerated()
        .map { besidePanel($0.element, panel[$0.offset % panel.count], column: column) }
        .joined(separator: "\n")
}

func testDisplayWidth() {
    expect(ScreenRegions.displayWidth("abc") == 3, "ascii is one cell each")
    expect(ScreenRegions.displayWidth("한글 ok") == 7, "hangul is two cells each")
    expect(ScreenRegions.displayWidth("❯ 1. ☐ ●") == 8, "prompt glyphs are one cell")
}

func testSidePanelIsCropped() {
    let plain = fixture("claude-ask-single.txt")
    guard let p = PromptParser.parse(withSidePanel(plain)) else {
        expect(false, "question beside a side panel parses")
        return
    }
    expect(p == PromptParser.parse(plain), "same prompt as without the panel")
    expect(p.options.first?.detail == "따뜻하고 강렬한 색", "detail without panel text: \(p.options.first?.detail ?? "nil")")
}

func testPermissionBesidePanelParses() {
    let plain = fixture("claude-bash-permission.txt")
    let parsed = PromptParser.parse(withSidePanel(plain))
    expect(parsed != nil && parsed == PromptParser.parse(plain), "permission beside a side panel parses")
}

func testQuoteBarIsNotADivider() {
    let screen = """
      ● Done.
    ─────────────────────────────────────────────
      │ A long question drawn in a quote box,
      │ wrapped over a few lines so the bar
      │ repeats in one column?
    ❯ 1. Yes
      2. No
    """
    expect(ScreenRegions.agentSide(screen) == screen, "a quote bar near the left edge is not a panel divider")
}

func runScreenRegionTests() {
    testDisplayWidth()
    testSidePanelIsCropped()
    testPermissionBesidePanelParses()
    testQuoteBarIsNotADivider()
}
