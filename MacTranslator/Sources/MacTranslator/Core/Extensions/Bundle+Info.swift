import Foundation

extension Bundle {
    /// Stable fallback identifier for toolchain builds without an Info.plist.
    static var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.mactranslator.app"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// ~/Library/Application Support/mac_translator (created on demand).
    static var applicationSupportDirectory: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let directory = base.appendingPathComponent("mac_translator", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
