import Foundation

/// OpenAI-compatible endpoint configuration.
///
/// The app is a local, single-user tool. API keys are stored in plaintext in
/// the local settings.json on purpose: the user explicitly chose this over the
/// system Keychain to avoid repeated authorization prompts. No key is ever
/// printed to logs or shown in full in the UI.
struct LLMInterface: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String?
    var model: String
    var enabled: Bool
    var priority: Int
    var supportsVision: Bool

    init(
        id: UUID = UUID(),
        name: String = "新接口",
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String? = nil,
        model: String = "gpt-4o-mini",
        enabled: Bool = true,
        priority: Int = 1,
        supportsVision: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.enabled = enabled
        self.priority = priority
        self.supportsVision = supportsVision
    }

    /// Trims whitespace and removes trailing slashes. Keeps an already complete path.
    func normalizedBaseURL() -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// Resolved /chat/completions URL. Ollama (http://localhost:11434/v1) works unchanged.
    func resolvedURL() -> URL? {
        let base = normalizedBaseURL()
        guard !base.isEmpty else { return nil }
        let path = base.contains("/chat/completions") ? base : base + "/chat/completions"
        return URL(string: path)
    }

    /// Safe display form; the full key is never shown or logged.
    var maskedAPIKey: String {
        guard let key = apiKey, !key.isEmpty else { return "未设置" }
        return String(key.prefix(3)) + "****"
    }

    /// Label shown in the result window.
    var displayLabel: String { "\(name) · \(model)" }
}
