import Foundation

/// OCR processing strategy. Persisted as raw value in AppSettings.
enum OCRMode: String, Codable, CaseIterable, Identifiable {
    case localVision
    case multimodalLLM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localVision: return "本地 Vision 优先"
        case .multimodalLLM: return "多模态 LLM 优先"
        }
    }

    var detail: String {
        switch self {
        case .localVision:
            return "使用系统 VNRecognizeTextRequest 本地识别文字，再交给 LLM 翻译。离线可用、零 OCR 成本。"
        case .multimodalLLM:
            return "将截图直接发送给支持视觉的模型识别并翻译。复杂版式效果更好，按图计费且需联网。"
        }
    }
}

/// Where the translated text came from.
enum SourceType: String, Codable, CaseIterable, Identifiable {
    case selection
    case ocr
    /// Text typed into the result window's editable source card.
    case input

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selection: return "划词"
        case .ocr: return "OCR"
        case .input: return "输入"
        }
    }
}

/// Text acquisition tier that finally succeeded.
enum SelectionLevel: String, Codable {
    case ax
    case appleScript
    case cmdC

    var displayName: String {
        switch self {
        case .ax: return "辅助功能"
        case .appleScript: return "浏览器脚本"
        case .cmdC: return "模拟复制"
        }
    }
}

/// Category of a single failed endpoint attempt.
enum GatewayFailureCategory: String, Codable {
    case network
    case timeout
    case http
    case invalidResponse
    case cancelled

    var displayName: String {
        switch self {
        case .network: return "网络错误"
        case .timeout: return "请求超时"
        case .http: return "HTTP 错误"
        case .invalidResponse: return "响应不合法"
        case .cancelled: return "已取消"
        }
    }
}

/// One failed attempt inside a failover chain. Never contains secrets.
struct GatewayFailure: Error, Codable, Equatable, Identifiable {
    let id: UUID
    let endpointName: String
    let category: GatewayFailureCategory
    let message: String

    init(
        id: UUID = UUID(),
        endpointName: String,
        category: GatewayFailureCategory,
        message: String
    ) {
        self.id = id
        self.endpointName = endpointName
        self.category = category
        self.message = message
    }
}

/// Errors surfaced by the LLM gateway.
enum GatewayError: Error, LocalizedError, Equatable {
    case noEnabledEndpoint
    case noVisionEndpoint
    case allFailed(attemptedCount: Int, lastError: GatewayFailure?, failures: [GatewayFailure])
    case cancelled
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noEnabledEndpoint:
            return "请先配置并启用至少一个 LLM 接口"
        case .noVisionEndpoint:
            return "没有启用支持视觉的模型，请在设置中勾选接口的「支持视觉」"
        case .allFailed(let attemptedCount, let lastError, _):
            let reason = lastError?.message ?? "未知错误"
            return "已尝试 \(attemptedCount) 个接口，均失败：\(reason)"
        case .cancelled:
            return "已取消本次翻译"
        case .invalidResponse(let detail):
            return "接口响应不合法：\(detail)"
        }
    }
}

/// System permission kinds required by the app.
enum PermissionType: String, Codable, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case automation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .automation: return "自动化"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return "读取选中文本（AXUIElement）与模拟 ⌘C 兜底"
        case .screenRecording: return "区域截图与 OCR 识别必需"
        case .automation: return "从浏览器读取选中文字（可选）"
        }
    }

    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        switch self {
        case .accessibility: return URL(string: base + "Accessibility")
        case .screenRecording: return URL(string: base + "ScreenCapture")
        case .automation: return URL(string: base + "Automation")
        }
    }
}

/// Permission check result. `unknown` means the system API cannot tell reliably.
enum PermissionStatus: String, Codable {
    case granted
    case denied
    case unknown

    var displayText: String {
        switch self {
        case .granted: return "● 已授权"
        case .denied: return "○ 未授权"
        case .unknown: return "◌ 需确认"
        }
    }

    var isGranted: Bool { self == .granted }
}

/// Errors produced by the OCR pipeline before any LLM request is made.
enum OCRServiceError: Error, LocalizedError {
    case captureCancelled
    case screenRecordingDenied
    case captureFailed(String)
    case emptyRecognition
    case imageConversionFailed

    /// Permission errors get a dedicated call-to-action in the result window.
    var isPermissionIssue: Bool {
        if case .screenRecordingDenied = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            return "已取消截图"
        case .screenRecordingDenied:
            return "屏幕录制权限未开启。请在「系统设置 › 隐私与安全性 › 屏幕录制」中打开「划译」，然后重试 OCR。"
        case .captureFailed(let detail):
            return "截图失败：\(detail)"
        case .emptyRecognition:
            return "框选区域没有识别到文字。请框得更贴近文字一些，或在设置中切换为「多模态 LLM」识别。"
        case .imageConversionFailed:
            return "图片转换失败，请重试"
        }
    }
}
