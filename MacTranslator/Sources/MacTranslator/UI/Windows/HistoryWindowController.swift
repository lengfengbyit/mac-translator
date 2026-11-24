import AppKit
import Foundation
import SwiftUI

@MainActor
final class HistoryWindowController: NSObject {
    private let window: NSWindow
    private let viewModel: HistoryViewModel

    init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史与收藏"
        // Keep the window alive across close/reopen; the default true would let
        // AppKit release it on close and leave our strong property dangling.
        window.isReleasedWhenClosed = false
        // NSHostingController keeps a correct responder chain / key view loop so
        // search fields and rows stay keyboard-interactive in an accessory app.
        let hosting = NSHostingController(rootView: HistoryView(vm: viewModel))
        window.contentViewController = hosting
        window.autorecalculatesKeyViewLoop = true
        window.center()
        self.window = window
        super.init()
    }

    func show() {
        viewModel.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
