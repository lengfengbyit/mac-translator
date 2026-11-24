import CoreData
import Foundation

extension Notification.Name {
    static let historyDidChange = Notification.Name("historyDidChange")
}

enum HistoryStoreError: Error, LocalizedError {
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "历史记录不存在：\(id.uuidString)"
        }
    }
}

/// Internal Core Data entity. UI only sees the HistoryRecord value type.
@objc(HistoryRecordEntity)
final class HistoryRecordEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var timestamp: Date
    @NSManaged var original: String
    @NSManaged var translated: String
    @NSManaged var sourceTypeRaw: String
    @NSManaged var interfaceName: String
    @NSManaged var degradedFrom: String?
    @NSManaged var isFavorite: Bool
    @NSManaged var ocrModeRaw: String?

    func toDTO() -> HistoryRecord {
        HistoryRecord(
            id: id,
            timestamp: timestamp,
            original: original,
            translated: translated,
            sourceType: SourceType(rawValue: sourceTypeRaw) ?? .selection,
            interfaceName: interfaceName,
            degradedFrom: degradedFrom,
            isFavorite: isFavorite,
            ocrMode: ocrModeRaw.flatMap { OCRMode(rawValue: $0) }
        )
    }
}

/// Single write entry point for history and favorites.
final class HistoryStore: HistoryStoring {
    private let stack: CoreDataStack
    private let retentionLimit: Int

    init(stack: CoreDataStack = .shared, retentionLimit: Int = 500) {
        self.stack = stack
        self.retentionLimit = max(1, retentionLimit)
    }

    func save(_ record: HistoryRecord) throws {
        try performOnContext { context in
            let entity = try self.find(record.id, in: context) ?? HistoryRecordEntity(context: context)
            entity.id = record.id
            entity.timestamp = record.timestamp
            entity.original = record.original
            entity.translated = record.translated
            entity.sourceTypeRaw = record.sourceTypeRaw
            entity.interfaceName = record.interfaceName
            entity.degradedFrom = record.degradedFrom
            entity.isFavorite = record.isFavorite
            entity.ocrModeRaw = record.ocrModeRaw
            try self.stack.save()
            self.trimIfNeeded(in: context)
        }
    }

    func fetchAll() throws -> [HistoryRecord] {
        let context = stack.context
        var result: [HistoryRecord] = []
        var caught: Error?
        context.performAndWait {
            let request = NSFetchRequest<HistoryRecordEntity>(entityName: "HistoryRecordEntity")
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryRecordEntity.timestamp), ascending: false)]
            do {
                result = try context.fetch(request).map { $0.toDTO() }
            } catch {
                caught = error
            }
        }
        if let caught { throw caught }
        return result
    }

    /// Toggling a favorite never deletes the history record.
    func toggleFavorite(id: UUID) throws {
        try performOnContext { context in
            guard let entity = try self.find(id, in: context) else {
                throw HistoryStoreError.notFound(id)
            }
            entity.isFavorite.toggle()
            try self.stack.save()
        }
    }

    func delete(id: UUID) throws {
        try performOnContext { context in
            guard let entity = try self.find(id, in: context) else {
                throw HistoryStoreError.notFound(id)
            }
            context.delete(entity)
            try self.stack.save()
        }
    }

    func clearAll() throws {
        try performOnContext { context in
            // NSBatchDeleteRequest is unsupported on in-memory stores (throws
            // NSInternalInconsistencyException), so fetch+delete instead.
            // History is capped at retentionLimit records, so this is cheap.
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryRecordEntity")
            for case let object as NSManagedObject in try context.fetch(request) {
                context.delete(object)
            }
            try self.stack.save()
        }
    }

    func isFavorite(id: UUID) -> Bool {
        let context = stack.context
        var result = false
        context.performAndWait {
            result = (try? find(id, in: context))?.isFavorite ?? false
        }
        return result
    }

    // MARK: Internals

    private func performOnContext(_ body: (NSManagedObjectContext) throws -> Void) throws {
        let context = stack.context
        var caught: Error?
        context.performAndWait {
            do {
                try body(context)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .historyDidChange, object: self)
                }
            } catch {
                caught = error
            }
        }
        if let caught { throw caught }
    }

    private func find(_ id: UUID, in context: NSManagedObjectContext) throws -> HistoryRecordEntity? {
        let request = NSFetchRequest<HistoryRecordEntity>(entityName: "HistoryRecordEntity")
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(HistoryRecordEntity.id), id as NSUUID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func trimIfNeeded(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<HistoryRecordEntity>(entityName: "HistoryRecordEntity")
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryRecordEntity.timestamp), ascending: false)]
        guard let all = try? context.fetch(request), all.count > retentionLimit else { return }
        for record in all.dropFirst(retentionLimit) {
            context.delete(record)
        }
        try? stack.save()
    }
}
