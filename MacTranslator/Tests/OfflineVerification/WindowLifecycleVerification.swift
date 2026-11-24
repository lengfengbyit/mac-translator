import AppKit
import Foundation

/// Offline regression for the menu-bar crash: programmatically created NSWindow
/// instances default to `isReleasedWhenClosed = true`. Closing such a window
/// lets AppKit release it behind Swift's back, so a later `makeKeyAndOrderFront:`
/// from a menu action dereferences a freed object (EXC_BAD_ACCESS, SIGSEGV).
/// This harness exercises the real AppKit lifecycle with the fix applied.

final class LifecycleProbeWindow: NSWindow {
    static var deinitCount = 0
    deinit { LifecycleProbeWindow.deinitCount += 1 }
}

private var failureCount = 0

private func expect(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL"): \(message)")
    if !condition { failureCount += 1 }
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let defaultWindow = LifecycleProbeWindow(
    contentRect: NSRect(x: 0, y: 0, width: 120, height: 90),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
expect(defaultWindow.isReleasedWhenClosed, "root cause: a programmatic NSWindow defaults to isReleasedWhenClosed = true")

let fixedWindow = LifecycleProbeWindow(
    contentRect: NSRect(x: 0, y: 0, width: 120, height: 90),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
fixedWindow.isReleasedWhenClosed = false
fixedWindow.close()
expect(LifecycleProbeWindow.deinitCount == 0, "fixed window survives close()")
fixedWindow.makeKeyAndOrderFront(nil)
expect(LifecycleProbeWindow.deinitCount == 0, "fixed window survives makeKeyAndOrderFront after reopen")
expect(fixedWindow.isVisible, "fixed window is visible after reopen")
fixedWindow.orderOut(nil)

for relativePath in [
    "Sources/MacTranslator/UI/Windows/SettingsWindowController.swift",
    "Sources/MacTranslator/UI/Windows/HistoryWindowController.swift"
] {
    let path = (root as NSString).appendingPathComponent(relativePath)
    let source = try? String(contentsOfFile: path, encoding: .utf8)
    expect(source?.contains("isReleasedWhenClosed = false") == true,
           "\(relativePath) opts out of release-on-close")
}

print("WindowLifecycleVerification: \(failureCount == 0 ? "ALL PASS" : "\(failureCount) FAILURE(S)")")
exit(failureCount == 0 ? 0 : 1)
