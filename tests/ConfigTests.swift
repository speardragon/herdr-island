import Foundation

// Config round-trips through config.toml; the settings window writes on every change,
// so hand-written comments and unknown keys must survive.

func testConfigDefaultsFromEmptyFile() {
    let config = Config.decode("")
    expect(config == Config(), "empty file gives defaults")
    expect(config.blockedPeekSeconds == 9 && config.donePeekSeconds == 6, "default peeks")
    expect(config.hoverToExpand && config.showWorking, "hover and working list on by default")
    expect(config.blockedSound == "none" && config.doneSound == "none", "silent by default")
}

func testConfigDecodesEveryKey() {
    let text = """
    [display]
    mode = "both"      # notch + menu bar
    screen = "mouse"
    hover_to_expand = false
    show_working = false

    [behavior]
    expand_on_blocked = false
    expand_on_done = true
    blocked_peek_seconds = 12
    done_peek_seconds = 3.5
    blocked_sound = "Glass"
    done_sound = "Pop"
    """
    let c = Config.decode(text)
    expect(c.mode == .both && c.screen == .mouse, "display keys \(c.mode) \(c.screen)")
    expect(!c.hoverToExpand && !c.showWorking, "display toggles")
    expect(!c.expandOnBlocked && c.expandOnDone, "expand toggles")
    expect(c.blockedPeekSeconds == 12 && c.donePeekSeconds == 3.5, "peeks \(c.blockedPeekSeconds) \(c.donePeekSeconds)")
    expect(c.blockedSound == "Glass" && c.doneSound == "Pop", "sounds")
}

func testConfigLegacyPeekSeconds() {
    let c = Config.decode("[behavior]\npeek_seconds = 4\n")
    expect(c.blockedPeekSeconds == 6 && c.donePeekSeconds == 4, "legacy peek maps to 1.5x / 1x, got \(c.blockedPeekSeconds) \(c.donePeekSeconds)")
}

func testConfigEncodePreservesComments() {
    let original = """
    # my island settings
    [display]
    mode = "notch"   # I like the notch

    [extra]
    keep = "me"
    """
    var config = Config.decode(original)
    config.mode = .menubar
    config.doneSound = "Tink"
    let written = Config.encode(config, into: original)
    expect(written.contains("# my island settings"), "top comment kept")
    expect(written.contains("[extra]\nkeep = \"me\""), "unknown section kept:\n\(written)")
    expect(written.contains("mode = \"menubar\""), "mode updated:\n\(written)")
    expect(!written.contains("mode = \"notch\""), "old mode replaced")
    expect(Config.decode(written) == config, "round trip")
}

func testConfigEncodeDoesNotConfuseSimilarKeys() {
    let original = "[behavior]\nexpand_on_done = false\nexpand_on_blocked = false\n"
    var config = Config.decode(original)
    config.expandOnBlocked = true
    let written = Config.encode(config, into: original)
    let decoded = Config.decode(written)
    expect(decoded.expandOnBlocked && !decoded.expandOnDone, "only expand_on_blocked changed:\n\(written)")
    expect(written.components(separatedBy: "expand_on_blocked").count == 2, "no duplicate key:\n\(written)")
}

func testConfigEncodeFromScratch() {
    let config = Config()
    let written = Config.encode(config, into: "")
    expect(written.contains("[display]") && written.contains("[behavior]"), "both sections created")
    expect(Config.decode(written) == config, "round trip from empty")
}

func testConfigPlacementAndClosingKeys() {
    let text = """
    [display]
    screen = "all"
    language = "en"

    [menubar]
    screen = "all"
    position = "right"

    [behavior]
    blocked_auto_close = false
    done_auto_close = true
    close_on_leave = false
    leave_delay_seconds = 2.5
    close_on_click_outside = false
    close_when_clear = false
    """
    let c = Config.decode(text)
    expect(c.screen == .all, "notch on all screens")
    expect(c.language == .english, "language en")
    expect(c.panelScreen == .all && c.panelPosition == .right, "menu bar panel placement \(c.panelScreen) \(c.panelPosition)")
    expect(!c.blockedAutoClose && c.doneAutoClose, "auto close flags")
    expect(!c.closeOnLeave && c.leaveDelaySeconds == 2.5, "leave closing")
    expect(!c.closeOnClickOutside, "click outside")
    expect(!c.closeWhenClear, "keep open when nothing is left")
    expect(Config.decode(Config.encode(c, into: text)) == c, "round trip")
}

func testConfigPlacementDefaults() {
    let c = Config()
    expect(c.language == .system, "follow system language by default")
    expect(c.panelScreen == .icon && c.panelPosition == .icon, "panel drops from the icon by default")
    expect(c.blockedAutoClose && c.doneAutoClose && c.closeOnLeave && c.closeOnClickOutside && c.closeWhenClear, "closing on by default")
    expect(c.leaveDelaySeconds == 0.5, "leave delay default")
    let written = Config.encode(c, into: "")
    expect(written.contains("[menubar]"), "menubar section written:\n\(written)")
}

func testConfigGlow() {
    let defaults = Config()
    expect(defaults.glowEnabled, "glow on by default")
    expect(defaults.glowBlockedColor == "FF453A" && defaults.glowDoneColor == "30D158", "red / green defaults")
    expect(defaults.glowIntensity == 0.6, "soft by default")
    let text = "[glow]\nenabled = false\nblocked_color = \"#FF0000\"\ndone_color = \"00ff00\"\nintensity = 0.9\n"
    let c = Config.decode(text)
    expect(!c.glowEnabled && c.glowIntensity == 0.9, "glow keys")
    expect(c.glowBlockedColor == "FF0000" && c.glowDoneColor == "00FF00", "colors normalized \(c.glowBlockedColor) \(c.glowDoneColor)")
    expect(Config.decode("[glow]\nblocked_color = \"nope\"\n").glowBlockedColor == "FF453A", "invalid color falls back")
    expect(Config.decode("[glow]\nintensity = 7\n").glowIntensity == 1, "intensity clamped")
    expect(Config.decode(Config.encode(c, into: text)) == c, "glow round trip")
}

func testConfigFade() {
    let defaults = Config()
    expect(defaults.fadeWhenIdle && defaults.fadeAfterSeconds == 5 && defaults.fadeOpacity == 0.35, "fade defaults")
    let c = Config.decode("[display]\nfade_when_idle = false\nfade_after_seconds = 12\nfade_opacity = 0.5\n")
    expect(!c.fadeWhenIdle && c.fadeAfterSeconds == 12 && c.fadeOpacity == 0.5, "fade keys")
    expect(Config.decode("[display]\nfade_opacity = 0\n").fadeOpacity == 0.1, "never fully invisible")
    expect(Config.decode("[display]\nfade_opacity = 3\n").fadeOpacity == 0.9, "never fully opaque either")
    expect(Config.decode(Config.encode(c, into: "")) == c, "fade round trip")
}

func runConfigTests() {
    testConfigFade()
    testConfigGlow()
    testConfigPlacementAndClosingKeys()
    testConfigPlacementDefaults()
    testConfigDefaultsFromEmptyFile()
    testConfigDecodesEveryKey()
    testConfigLegacyPeekSeconds()
    testConfigEncodePreservesComments()
    testConfigEncodeDoesNotConfuseSimilarKeys()
    testConfigEncodeFromScratch()
}
