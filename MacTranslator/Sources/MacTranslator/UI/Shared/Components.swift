import SwiftUI

/// Small source badge ("划词" / "OCR").
struct Badge: View {
    let text: String
    let tint: Color

    init(text: String, tint: Color = .accentColor) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// LLM label plus optional "degraded from" hint.
struct LLMTag: View {
    let label: String
    let degradedFrom: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.primary)
            if let degradedFrom, !degradedFrom.isEmpty {
                Text("由接口 \(degradedFrom) 降级而来")
                    .font(.system(size: 10.5))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.09))
        .clipShape(Capsule())
    }
}

/// Section title used by settings panes.
struct PaneHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }
}

/// Explanatory blue banner.
struct InfoBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Color.blue.opacity(0.07))
            .cornerRadius(8)
    }
}

/// One row of permission / hotkey status.
struct StatusRow: View {
    let title: String
    let detail: String
    let status: String
    var statusColor: Color = .secondary
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Text(status)
                .font(.system(size: 11.5))
                .foregroundColor(statusColor)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
            }
        }
        .padding(.vertical, 9)
    }
}
