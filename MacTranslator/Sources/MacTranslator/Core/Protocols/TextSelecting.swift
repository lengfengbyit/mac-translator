import Foundation

/// Text acquisition contract. Implementations must run AX / clipboard work on the main thread.
protocol TextSelecting {
    func selectText() async -> SelectionResult
}
