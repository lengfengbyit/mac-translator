import Foundation

/// Source-level regression checks for the "LLM 接口输入框不好用" bug (round 2).
///
/// Two independent root causes were fixed:
///   1. Accessory (LSUIElement) apps have no menu bar, so the standard editing
///      key equivalents (Cmd-X/C/V/A/Z) have no target in the responder chain.
///      A hidden main menu with an Edit submenu must be installed at launch.
///   2. `.onDrag` / `.onMove` on the whole SwiftUI List row install pan gesture
///      recognizers over the NSTextFields, so clicks never make them first
///      responder. Drag must be confined to the numbered circle handle and
///      the row must only be a drop target.
///
/// This verifier checks the checked-in source so the regression never silently
/// reappears. Runtime click/paste/delete behaviour is verified separately on the
/// real app with CGEvent (see 07-输入框BugFix报告.md).

struct Check {
    let name: String
    let ok: Bool
}

func source(_ relative: String, root: String) -> String {
    let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

/// Strip // line comments so assertions match code, not explanatory text.
func withoutLineComments(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.map { line in
        let parts = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.first.map(String.init) ?? ""
    }.joined(separator: "\n")
}

let appDelegate = withoutLineComments(source("Sources/MacTranslator/App/AppDelegate.swift", root: root))
let pane = withoutLineComments(source("Sources/MacTranslator/UI/panes/LLMInterfacesPane.swift", root: root))
let windowController = withoutLineComments(source("Sources/MacTranslator/UI/Windows/SettingsWindowController.swift", root: root))

// MARK: Root cause 1 — hidden Edit menu restores Cmd-V / Cmd-A / Delete
let installsMainMenu = appDelegate.contains("NSApp.mainMenu = mainMenu")
let hasEditMenu = appDelegate.contains("editMenu.addItem")
let hasPasteAction = appDelegate.contains("#selector(NSText.paste(_:))")
let hasCopyAction = appDelegate.contains("#selector(NSText.copy(_:))")
let hasCutAction = appDelegate.contains("#selector(NSText.cut(_:))")
let hasSelectAll = appDelegate.contains("#selector(NSText.selectAll(_:))")
let hasPasteKey = appDelegate.contains("keyEquivalent: \"v\"")
let hasSelectAllKey = appDelegate.contains("keyEquivalent: \"a\"")
let installsAtLaunch = {
    let launch = appDelegate.range(of: "applicationDidFinishLaunching")
    let install = appDelegate.range(of: "installMainMenu()")
    guard let l = launch, let i = install else { return false }
    return l.lowerBound < i.lowerBound && appDelegate.distance(from: l.lowerBound, to: i.lowerBound) < 400
}()
let keepsAccessoryPolicy = appDelegate.contains("NSApp.setActivationPolicy(.accessory)")

// MARK: Root cause 2 — drag confined to handle, no row-level pan recognizers
let handleHasDrag = {
    // .onDrag must appear inside InterfaceCard's circle ZStack, not on the row.
    guard let card = pane.range(of: "private struct InterfaceCard") else { return false }
    let cardBody = String(pane[card.lowerBound...])
    guard let zstack = cardBody.range(of: "ZStack") else { return false }
    guard let frame = cardBody.range(of: ".frame(width: 25, height: 25)") else { return false }
    guard let drag = cardBody.range(of: ".onDrag") else { return false }
    return zstack.lowerBound < drag.lowerBound && frame.lowerBound < drag.lowerBound
}()
let noRowOnMove = !pane.contains(".onMove")
// The only .onDrag in the pane must be the handle one (exactly one occurrence).
let singleOnDrag = pane.components(separatedBy: ".onDrag").count - 1 == 1
let rowHasDrop = pane.contains(".onDrop(of: [.text]")

// MARK: Focus hardening — show() activates and promotes window to key
let showActivates = windowController.contains("NSApp.activate(ignoringOtherApps: true)")
let showOrderFrontRegardless = windowController.contains("orderFrontRegardless()")
let showMakeKey = windowController.contains("makeKeyAndOrderFront(nil)")

let checks: [Check] = [
    Check(name: "R1.1 AppDelegate installs a main menu", ok: installsMainMenu),
    Check(name: "R1.2 main menu has an Edit submenu", ok: hasEditMenu),
    Check(name: "R1.3 Edit menu wires paste: action", ok: hasPasteAction),
    Check(name: "R1.4 Edit menu wires copy: action", ok: hasCopyAction),
    Check(name: "R1.5 Edit menu wires cut: action", ok: hasCutAction),
    Check(name: "R1.6 Edit menu wires selectAll: action", ok: hasSelectAll),
    Check(name: "R1.7 Cmd+V key equivalent present", ok: hasPasteKey),
    Check(name: "R1.8 Cmd+A key equivalent present", ok: hasSelectAllKey),
    Check(name: "R1.9 menu installed at launch", ok: installsAtLaunch),
    Check(name: "R1.10 app stays accessory (no Dock icon / menu bar flash)", ok: keepsAccessoryPolicy),
    Check(name: "R2.1 .onDrag confined to numbered handle circle", ok: handleHasDrag),
    Check(name: "R2.2 no row-level .onMove pan recognizer", ok: noRowOnMove),
    Check(name: "R2.3 exactly one .onDrag in pane", ok: singleOnDrag),
    Check(name: "R2.4 row remains a drop target (drag reorder preserved)", ok: rowHasDrop),
    Check(name: "R3.1 show() activates the accessory app", ok: showActivates),
    Check(name: "R3.2 show() calls orderFrontRegardless", ok: showOrderFrontRegardless),
    Check(name: "R3.3 show() calls makeKeyAndOrderFront", ok: showMakeKey),
]

var failed = 0
for check in checks {
    print("\(check.ok ? "PASS" : "FAIL"): \(check.name)")
    if !check.ok { failed += 1 }
}
print("InputFocusVerification: \(checks.count - failed)/\(checks.count) PASS, \(failed) FAIL")
exit(failed == 0 ? 0 : 1)
