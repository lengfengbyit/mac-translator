import Combine
import Foundation
import SwiftUI

enum HistoryTab: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        }
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []
    @Published var searchText: String = ""
    @Published var tab: HistoryTab = .all

    private let store: HistoryStoring
    private var changeObserver: AnyCancellable?

    init(store: HistoryStoring) {
        self.store = store
        reload()
        changeObserver = NotificationCenter.default
            .publisher(for: .historyDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    var filteredRecords: [HistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            if tab == .favorites && !record.isFavorite { return false }
            guard !query.isEmpty else { return true }
            return record.original.lowercased().contains(query)
                || record.translated.lowercased().contains(query)
        }
    }

    func reload() {
        records = (try? store.fetchAll()) ?? []
    }

    func toggleFavorite(id: UUID) {
        do {
            try store.toggleFavorite(id: id)
            reload()
        } catch {
            reload()
        }
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
            reload()
        } catch {
            reload()
        }
    }

    func clearAll() {
        do {
            try store.clearAll()
            reload()
        } catch {
            reload()
        }
    }
}
