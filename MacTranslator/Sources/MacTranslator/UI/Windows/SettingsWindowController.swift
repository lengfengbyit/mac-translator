import AppKit
import Foundation
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.minSize = NSSize(width: 700, height: 480)
        // Programmatically created NSWindow defaults to isReleasedWhenClosed = true.
        // AppKit then calls release on close, invalidating our strong `window` property
        // and crashing on the next show() with makeKeyAndOrderFront: on a freed object.
        window.isReleasedWhenClosed = false
        // Assigning a bare NSHostingView to contentView leaves the window without a
        // proper responder chain / key view loop. In an accessory app that makes
        // embedded TextFields unable to become first responder (no click-to-focus,
        // Cmd+V, or Delete). NSHostingController wires the chain correctly.
        let hosting = NSHostingController(rootView: SettingsView(vm: viewModel))
        window.contentViewController = hosting
        window.autorecalculatesKeyViewLoop = true
        window.center()
        self.window = window
        super.init()
        window.delegate = self
    }

    func show() {
        viewModel.refreshPermissions()
        // An accessory (LSUIElement) app is not automatically activated when a
        // menu item is chosen, so its window can end up visible but NOT key.
        // A non-key window never routes mouse-down to NSTextField, making the
        // edit fields unselectable / uneditable. Activate, then promote the
        // window to key on the next run-loop turn once AppKit has finished
        // processing the status-item menu dismissal.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        window.orderOut(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            viewModel.stopPermissionPolling()
        }
    }
}
