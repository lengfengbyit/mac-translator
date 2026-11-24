import CoreData
import Foundation

/// Core Data container (macOS 13 baseline; SwiftData requires macOS 14 and is not used).
final class CoreDataStack {
    static let shared = CoreDataStack()

    let container: NSPersistentContainer
    private(set) var loadError: Error?

    var context: NSManagedObjectContext { container.viewContext }

    init(modelName: String = "Model", storeURL: URL? = nil, inMemory: Bool = false) {
        let model = Self.bundledModel(named: modelName) ?? Self.programmaticModel()
        let container = NSPersistentContainer(name: modelName, managedObjectModel: model)

        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
            description.url = nil
        } else {
            description.url = storeURL ?? Bundle.applicationSupportDirectory
                .appendingPathComponent("MacTranslator.sqlite", isDirectory: false)
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            loadError = CoreDataStackError.loadTimeout
        }

        self.container = container
        self.loadError = loadError
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    func save() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        container.newBackgroundContext()
    }

    private static func bundledModel(named name: String) -> NSManagedObjectModel? {
        let bundles = [Bundle.main, Bundle(for: CoreDataStack.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "momd"),
               let model = NSManagedObjectModel(contentsOf: url) {
                return model
            }
        }
        return nil
    }

    /// Fallback keeps tests and SwiftPM builds working when no compiled momd is bundled.
    private static func programmaticModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "HistoryRecordEntity"
        entity.managedObjectClassName = NSStringFromClass(HistoryRecordEntity.self)

        func attribute(
            _ name: String,
            type: NSAttributeType,
            optional: Bool = false,
            defaultValue: Any? = nil
        ) -> NSAttributeDescription {
            let result = NSAttributeDescription()
            result.name = name
            result.attributeType = type
            result.isOptional = optional
            result.defaultValue = defaultValue
            return result
        }

        entity.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("timestamp", type: .dateAttributeType),
            attribute("original", type: .stringAttributeType),
            attribute("translated", type: .stringAttributeType),
            attribute("sourceTypeRaw", type: .stringAttributeType),
            attribute("interfaceName", type: .stringAttributeType),
            attribute("degradedFrom", type: .stringAttributeType, optional: true),
            attribute("isFavorite", type: .booleanAttributeType, defaultValue: false),
            attribute("ocrModeRaw", type: .stringAttributeType, optional: true)
        ]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }
}

enum CoreDataStackError: Error, LocalizedError {
    case loadTimeout

    var errorDescription: String? {
        "Core Data 持久化存储加载超时"
    }
}
