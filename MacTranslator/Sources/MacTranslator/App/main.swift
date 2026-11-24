import AppKit

// LSUIElement + accessory policy: menu bar only, no Dock icon and no main window.
let application = NSApplication.shared
// Top-level code runs on the main thread, so entering the MainActor is safe here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
