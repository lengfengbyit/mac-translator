import Foundation

extension Notification.Name {
    /// Posted after any persisted settings change so live UI (e.g. the result
    /// window backdrop opacity) can refresh without waiting for the next show().
    static let macTranslatorSettingsDidChange = Notification.Name("MacTranslatorSettingsDidChange")
}

/// JSON + Codable settings store. Changes take effect immediately without restart.
final class SettingsStore: SettingsStoring {
    private let fileURL: URL
    private let lock = NSLock()
    private var settings: AppSettings

    var current: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Bundle.applicationSupportDirectory
            .appendingPathComponent("settings.json", isDirectory: false)
        self.settings = AppSettings.default
        _ = load()
    }

    @discardableResult
    func load() -> AppSettings {
        let loaded: AppSettings
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        } else {
            loaded = .default
        }
        lock.lock()
        settings = loaded
        lock.unlock()
        return loaded
    }

    func update(_ newSettings: AppSettings) throws {
        let data = try JSONEncoder().encode(newSettings)
        try data.write(to: fileURL, options: .atomic)
        // API keys are plaintext here, so keep the file readable by the
        // current user only (chmod 600) rather than the default 644.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        lock.lock()
        settings = newSettings
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .macTranslatorSettingsDidChange, object: nil)
        }
    }
}
