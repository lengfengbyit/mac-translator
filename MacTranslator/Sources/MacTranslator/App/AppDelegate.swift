import AppKit
import Combine
import Foundation

/// Composition root: owns all services, builds the menu bar and registers global hotkeys.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let permissionService = PermissionService()
    private let captureService = ScreenCaptureService()
    private let visionService = VisionOCRService()

    private lazy var cacheService: CacheService = CacheService(
        maxEntries: settingsStore.current.maxCacheEntries
    )
    private lazy var gateway: LLMGateway = LLMGateway(
        settingsStore: settingsStore,
        cache: cacheService
    )
    private lazy var textSelector = TextSelectionService(permission: permissionService)
    private lazy var ocrService = OCRService(
        capture: captureService,
        vision: visionService,
        gateway: gateway,
        settingsStore: settingsStore,
        permission: permissionService
    )
    private lazy var historyStore: HistoryStore = HistoryStore(
        retentionLimit: settingsStore.current.historyRetentionLimit
    )
    private lazy var resultWindow = ResultWindowController(settingsStore: settingsStore)
    private lazy var hotkeyService = HotkeyService(settingsStore: settingsStore)
    private lazy var settingsViewModel = SettingsViewModel(
        store: settingsStore,
        gateway: gateway,
        cache: cacheService,
        history: historyStore,
        permissions: permissionService,
        hotkeyService: hotkeyService
    )
    private lazy var settingsWindow = SettingsWindowController(viewModel: settingsViewModel)
    private lazy var historyViewModel = HistoryViewModel(store: historyStore)
    private lazy var historyWindow = HistoryWindowController(viewModel: historyViewModel)
    private lazy var menuBar = MenuBarController(permissions: permissionService)
    private lazy var coordinator = AppCoordinator(
        gateway: gateway,
        selector: textSelector,
        ocrService: ocrService,
        historyStore: historyStore,
        settingsStore: settingsStore,
        permissions: permissionService,
        resultWindow: resultWindow
    )

    private var permissionObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        setupCompositionRoot()
        permissionService.refresh()
        menuBar.updatePermissionStates()
    }

    /// Accessory (LSUIElement) apps have no visible menu bar, which also removes
    /// the standard text-editing key equivalents (Cmd-X/C/V/A/Z) from the
    /// responder chain. Without a nil-targeted Edit menu, ⌘V / ⌘A / Delete in
    /// the Settings text fields just beep. A hidden main menu restores those
    /// actions; it never appears in the menu bar because the policy is `.accessory`.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Hide",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func setupCompositionRoot() {
        hotkeyService.onHotkeyAction = { [weak self] action in
            guard let self else { return }
            Task { @MainActor in
                switch action {
                case .selection: await self.coordinator.handleSelection()
                case .ocr: await self.coordinator.handleOCR()
                }
            }
        }
        _ = hotkeyService.register()
        settingsViewModel.hotkeyConflict = hotkeyService.conflictMessage
        if let notice = hotkeyService.conflictMessage {
            let bindings = settingsStore.current.hotkeys
            menuBar.setHotkeyNotice(
                "⚠️ 快捷键已调整：划词 \(bindings.selection.displayString) · OCR \(bindings.ocr.displayString)"
            )
            UserDefaults.standard.set(notice, forKey: "MacTranslator.HotkeyNotice")
        } else {
            menuBar.setHotkeyNotice(nil)
            UserDefaults.standard.removeObject(forKey: "MacTranslator.HotkeyNotice")
        }

        menuBar.onSelection = { [weak self] in
            Task { await self?.coordinator.handleSelection() }
        }
        menuBar.onOCR = { [weak self] in
            Task { await self?.coordinator.handleOCR() }
        }
        menuBar.onHistory = { [weak self] in
            self?.historyWindow.show()
        }
        menuBar.onSettings = { [weak self] in
            self?.settingsWindow.show()
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        permissionObserver = permissionService.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.menuBar.updatePermissionStates()
            }

        // Pre-create the windows so menu actions are instant on first click.
        _ = settingsWindow
        _ = historyWindow
        _ = coordinator
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.unregister()
        permissionService.stopPolling()
        gateway.cancelActiveTask()
        permissionObserver?.cancel()
    }
}
