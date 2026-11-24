import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

/// Checks, requests and presents system permissions. Authorization is never cached across launches.
@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var states: [PermissionType: PermissionStatus] = [:]

    private var pollingTimer: Timer?

    init() {
        refresh()
    }

    deinit {
        pollingTimer?.invalidate()
    }

    func status(type: PermissionType) -> PermissionStatus {
        states[type] ?? .unknown
    }

    /// Accessibility is prompted via AXIsProcessTrustedWithOptions; screen
    /// recording is prompted with the dedicated CoreGraphics API. Automation is
    /// system-prompted the first time an AppleScript is executed.
    func requestIfNeeded(type: PermissionType) {
        switch type {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() {
                // Presents the system prompt while the decision is still
                // "not determined". If the user already denied it, TCC
                // suppresses the prompt; openSystemSettings lets them flip
                // the toggle manually.
                _ = CGRequestScreenCaptureAccess()
            }
        case .automation:
            break
        }
        refresh()
    }

    func openSettings(type: PermissionType) {
        guard let url = type.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Convenience for the floating result window's permission error card.
    func openScreenRecordingSettings() {
        openSettings(type: .screenRecording)
    }

    /// Polls every 1.5s while settings are open so a newly granted permission unlocks features.
    func startPolling(interval: TimeInterval = 1.5) {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func refresh() {
        var next: [PermissionType: PermissionStatus] = [:]
        for type in PermissionType.allCases {
            next[type] = check(type)
        }
        states = next
    }

    private func check(_ type: PermissionType) -> PermissionStatus {
        switch type {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return checkScreenRecording()
        case .automation:
            return checkAutomation()
        }
    }

    /// The old implementation guessed permission by taking a full-screen
    /// screenshot and counting "mostly black" pixels. On macOS 15 a denied app
    /// still receives the desktop wallpaper, so the heuristic reported
    /// `.granted` while every captured window was blank -> OCR always failed
    /// with "no text" and no hint was ever shown to the user. TCC now has a
    /// first-party, side-effect-free answer: CGPreflightScreenCaptureAccess.
    private func checkScreenRecording() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private func checkAutomation() -> PermissionStatus {
        let source = "tell application \"System Events\" to get name of first process whose frontmost is true"
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if result != nil { return .granted }
        if let code = errorInfo?[NSAppleScript.errorNumber] as? Int, code == -1743 {
            return .denied
        }
        return .unknown
    }
}
