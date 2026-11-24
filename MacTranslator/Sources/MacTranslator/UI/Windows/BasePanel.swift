import AppKit

/// Non-activating floating panel: visible above other apps without stealing focus.
///
/// The panel is deliberately borderless. The standard `.titled/.closable` traffic
/// lights do not receive clicks on a `nonactivatingPanel` whose `canBecomeKey` is
/// false, and `.fullSizeContentView` lets the SwiftUI hosting view cover the
/// titlebar. We render our own close button and drag handle in SwiftUI instead.
final class BasePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Programmatically created NSWindow defaults to isReleasedWhenClosed = true.
        // AppKit then calls release on close, invalidating our strong `panel`
        // property and crashing on the next show() / makeKeyAndOrderFront:.
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // AppKit's background dragging fights with SwiftUI hit-testing on a
        // borderless panel. Dragging is handled explicitly by DragHandleView.
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
