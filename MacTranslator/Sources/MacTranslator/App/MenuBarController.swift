import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    var onSelection: (() -> Void)?
    var onOCR: (() -> Void)?
    var onInput: (() -> Void)?
    var onHistory: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let permissions: PermissionService?

    init(permissions: PermissionService? = nil) {
        self.permissions = permissions
        super.init()
        buildMenu()
    }

    func buildMenu() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "划译")
                ?? NSImage(named: NSImage.statusAvailableName)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "划译"
        }

        menu.removeAllItems()

        let selection = menu.addItem(withTitle: "划词翻译", action: #selector(selectText(_:)), keyEquivalent: "d")
        selection.keyEquivalentModifierMask = [.option]
        selection.target = self
        selection.tag = 1

        let ocr = menu.addItem(withTitle: "OCR 翻译", action: #selector(ocrTranslate(_:)), keyEquivalent: "s")
        ocr.keyEquivalentModifierMask = [.option, .shift]
        ocr.target = self
        ocr.tag = 2

        let input = menu.addItem(withTitle: "输入翻译", action: #selector(inputTranslate(_:)), keyEquivalent: "i")
        input.keyEquivalentModifierMask = [.option, .shift]
        input.target = self
        input.tag = 3

        menu.addItem(NSMenuItem.separator())

        let notice = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        notice.tag = 90
        notice.isEnabled = false
        notice.isHidden = true
        menu.addItem(notice)

        let history = menu.addItem(withTitle: "历史与收藏", action: #selector(openHistory(_:)), keyEquivalent: "")
        history.target = self

        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self

        menu.addItem(NSMenuItem.separator())

        let quit = menu.addItem(withTitle: "退出划译", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self

        statusItem.menu = menu
        updatePermissionStates()
    }

    /// Permission state is surfaced in the item titles, never by disabling
    /// them: a greyed-out OCR item gives the user no way to discover why the
    /// feature failed. Clicking it reaches the coordinator, which shows an
    /// actionable card with a "open Screen Recording settings" button.
    func updatePermissionStates() {
        guard let permissions else { return }
        let accessibility = permissions.status(type: .accessibility)
        let screenRecording = permissions.status(type: .screenRecording)
        menu.item(withTag: 1)?.isEnabled = true
        menu.item(withTag: 2)?.isEnabled = true
        menu.item(withTag: 1)?.title = accessibility.isGranted
            ? "划词翻译" : "划词翻译 · 需辅助功能权限"
        menu.item(withTag: 2)?.title = screenRecording.isGranted
            ? "OCR 翻译" : "OCR 翻译 · 需屏幕录制权限"
    }

    /// Shows a visible hint when a hotkey had to be moved off its default.
    func setHotkeyNotice(_ message: String?) {
        guard let item = menu.item(withTag: 90) else { return }
        item.title = message ?? ""
        item.isHidden = (message == nil)
    }

    @objc private func selectText(_ sender: NSMenuItem) {
        onSelection?()
    }

    @objc private func ocrTranslate(_ sender: NSMenuItem) {
        onOCR?()
    }

    @objc private func inputTranslate(_ sender: NSMenuItem) {
        onInput?()
    }

    @objc private func openHistory(_ sender: NSMenuItem) {
        onHistory?()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onSettings?()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        onQuit?()
    }
}
