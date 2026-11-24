import Combine
import SwiftUI

/// Lightweight toast center shared by settings and result views.
final class ToastCenter: ObservableObject {
    @Published var message: String?

    private var timer: Timer?

    func show(_ message: String) {
        self.message = message
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.9, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.message = nil
            }
        }
    }
}

struct ToastView: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        Group {
            if let message = center.message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.82))
                    )
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.message)
    }
}

extension View {
    func toast(center: ToastCenter) -> some View {
        overlay(
            VStack {
                Spacer()
                ToastView(center: center)
                    .padding(.bottom, 20)
            },
            alignment: .bottom
        )
    }
}
