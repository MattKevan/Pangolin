// CoreData/CoreDataStack.swift
import Foundation
import CoreData
import AVFoundation

class CoreDataStack {
    private let modelName = "Pangolin"
    private let libraryURL: URL
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "PangolinModel", managedObjectModel: self.managedObjectModel)
        
        // Configure for library-specific storage
        let storeURL = libraryURL.appendingPathComponent("Library.sqlite")
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        
        // Performance optimizations
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        container.persistentStoreDescriptions = [storeDescription]
        
        container.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                // Log error - in production, handle this more gracefully
                print("Core Data error: \(error), \(error.userInfo)")
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        return container
    }()
    
    lazy var managedObjectModel: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        
        // Define entities programmatically
        // This could also be loaded from a .xcdatamodeld file
        
        // Video Entity
        let videoEntity = NSEntityDescription()
        videoEntity.name = "Video"
        videoEntity.managedObjectClassName = NSStringFromClass(Video.self)
        
        // Add Video attributes
        let videoAttributes: [(String, NSAttributeType, Any?)] = [
            ("id", .UUIDAttributeType, nil),
            ("title", .stringAttributeType, nil),
            ("fileName", .stringAttributeType, nil),
            ("relativePath", .stringAttributeType, nil),
            ("duration", .doubleAttributeType, 0.0),
            ("fileSize", .integer64AttributeType, 0),
            ("dateAdded", .dateAttributeType, Date()),
            ("lastPlayed", .dateAttributeType, nil),
            ("playbackPosition", .doubleAttributeType, 0.0),
            ("playCount", .integer32AttributeType, 0),
            ("thumbnailPath", .stringAttributeType, nil),
            ("videoFormat", .stringAttributeType, nil),
            ("resolution", .stringAttributeType, nil),
            ("frameRate", .doubleAttributeType, 0.0),
            ("isFavorite", .booleanAttributeType, false) // <-- ADDED THIS LINE
        ]
        
        videoEntity.properties = videoAttributes.map { name, type, defaultValue in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = (name == "lastPlayed" || name == "thumbnailPath" || name == "videoFormat" || name == "resolution")
            attribute.defaultValue = defaultValue
            return attribute
        }
        
        // Folder Entity
        let folderEntity = NSEntityDescription()
        folderEntity.name = "Folder"
        folderEntity.managedObjectClassName = NSStringFromClass(Folder.self)
        
        let folderAttributes: [(String, NSAttributeType, Any?)] = [
            ("id", .UUIDAttributeType, nil),
            ("name", .stringAttributeType, ""),
            ("isTopLevel", .booleanAttributeType, true),
            ("isSmartFolder", .booleanAttributeType, false),
            ("dateCreated", .dateAttributeType, Date()),
            ("dateModified", .dateAttributeType, Date())
        ]
        
        folderEntity.properties = folderAttributes.map { name, type, defaultValue in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = false
            attribute.defaultValue = defaultValue
            return attribute
        }
        
        // Subtitle Entity
        let subtitleEntity = NSEntityDescription()
        subtitleEntity.name = "Subtitle"
        subtitleEntity.managedObjectClassName = NSStringFromClass(Subtitle.self)
        
        let subtitleAttributes: [(String, NSAttributeType, Any?)] = [
            ("id", .UUIDAttributeType, nil),
            ("fileName", .stringAttributeType, ""),
            ("relativePath", .stringAttributeType, ""),
            ("language", .stringAttributeType, nil),
            ("languageName", .stringAttributeType, nil),
            ("isDefault", .booleanAttributeType, false),
            ("isForced", .booleanAttributeType, false),
            ("format", .stringAttributeType, "srt"),
            ("encoding", .stringAttributeType, "UTF-8")
        ]
        
        subtitleEntity.properties = subtitleAttributes.map { name, type, defaultValue in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = (name == "language" || name == "languageName")
            attribute.defaultValue = defaultValue
            return attribute
        }
        
        // Library Entity
        let libraryEntity = NSEntityDescription()
        libraryEntity.name = "Library"
        libraryEntity.managedObjectClassName = NSStringFromClass(Library.self)
        
        let libraryAttributes: [(String, NSAttributeType, Any?)] = [
            ("id", .UUIDAttributeType, nil),
            ("name", .stringAttributeType, ""),
            ("createdDate", .dateAttributeType, Date()),
            ("lastOpenedDate", .dateAttributeType, Date()),
            ("version", .stringAttributeType, "1.0.0"),
            ("libraryPath", .stringAttributeType, ""),
            ("copyFilesOnImport", .booleanAttributeType, true),
            ("organizeByDate", .booleanAttributeType, true),
            ("autoMatchSubtitles", .booleanAttributeType, true),
            ("defaultPlaybackSpeed", .floatAttributeType, 1.0),
            ("rememberPlaybackPosition", .booleanAttributeType, true)
        ]
        
        libraryEntity.properties = libraryAttributes.map { name, type, defaultValue in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = false
            attribute.defaultValue = defaultValue
            return attribute
        }
        
        // Define Relationships
        // Video -> Library (many-to-one)
        let videoToLibrary = NSRelationshipDescription()
        videoToLibrary.name = "library"
        videoToLibrary.destinationEntity = libraryEntity
        videoToLibrary.minCount = 0
        videoToLibrary.maxCount = 1
        videoToLibrary.isOptional = true
        
        // Library -> Videos (one-to-many)
        let libraryToVideos = NSRelationshipDescription()
        libraryToVideos.name = "videos"
        libraryToVideos.destinationEntity = videoEntity
        libraryToVideos.minCount = 0
        libraryToVideos.maxCount = 0 // 0 means no limit
        libraryToVideos.isOptional = true
        libraryToVideos.inverseRelationship = videoToLibrary
        videoToLibrary.inverseRelationship = libraryToVideos
        
        // Subtitle -> Video (many-to-one)
        let subtitleToVideo = NSRelationshipDescription()
        subtitleToVideo.name = "video"
        subtitleToVideo.destinationEntity = videoEntity
        subtitleToVideo.minCount = 0
        subtitleToVideo.maxCount = 1
        subtitleToVideo.isOptional = true
        
        // Video -> Subtitles (one-to-many)
        let videoToSubtitles = NSRelationshipDescription()
        videoToSubtitles.name = "subtitles"
        videoToSubtitles.destinationEntity = subtitleEntity
        videoToSubtitles.minCount = 0
        videoToSubtitles.maxCount = 0
        videoToSubtitles.isOptional = true
        videoToSubtitles.inverseRelationship = subtitleToVideo
        subtitleToVideo.inverseRelationship = videoToSubtitles
        
        // Folder -> Library (many-to-one)
        let folderToLibrary = NSRelationshipDescription()
        folderToLibrary.name = "library"
        folderToLibrary.destinationEntity = libraryEntity
        folderToLibrary.minCount = 0
        folderToLibrary.maxCount = 1
        folderToLibrary.isOptional = true
        
        // Library -> Folders (one-to-many)
        let libraryToFolders = NSRelationshipDescription()
        libraryToFolders.name = "folders"
        libraryToFolders.destinationEntity = folderEntity
        libraryToFolders.minCount = 0
        libraryToFolders.maxCount = 0
        libraryToFolders.isOptional = true
        libraryToFolders.inverseRelationship = folderToLibrary
        folderToLibrary.inverseRelationship = libraryToFolders
        
        // Folder -> Parent Folder (many-to-one)
        let folderToParent = NSRelationshipDescription()
        folderToParent.name = "parentFolder"
        folderToParent.destinationEntity = folderEntity
        folderToParent.minCount = 0
        folderToParent.maxCount = 1
        folderToParent.isOptional = true
        
        // Folder -> Child Folders (one-to-many)
        let folderToChildren = NSRelationshipDescription()
        folderToChildren.name = "childFolders"
        folderToChildren.destinationEntity = folderEntity
        folderToChildren.minCount = 0
        folderToChildren.maxCount = 0
        folderToChildren.isOptional = true
        folderToChildren.inverseRelationship = folderToParent
        folderToParent.inverseRelationship = folderToChildren
        
        // Folder -> Videos (one-to-many) - simplified from many-to-many
        let folderToVideos = NSRelationshipDescription()
        folderToVideos.name = "videos"
        folderToVideos.destinationEntity = videoEntity
        folderToVideos.minCount = 0
        folderToVideos.maxCount = 0
        folderToVideos.isOptional = true
        
        // Video -> Folder (many-to-one) - simplified from many-to-many
        let videoToFolder = NSRelationshipDescription()
        videoToFolder.name = "folder"
        videoToFolder.destinationEntity = folderEntity
        videoToFolder.minCount = 0
        videoToFolder.maxCount = 1
        videoToFolder.isOptional = true
        videoToFolder.inverseRelationship = folderToVideos
        folderToVideos.inverseRelationship = videoToFolder
        
        // Add relationships to entities
        videoEntity.properties.append(videoToLibrary)
        videoEntity.properties.append(videoToSubtitles)
        videoEntity.properties.append(videoToFolder)
        libraryEntity.properties.append(libraryToVideos)
        libraryEntity.properties.append(libraryToFolders)
        subtitleEntity.properties.append(subtitleToVideo)
        folderEntity.properties.append(folderToLibrary)
        folderEntity.properties.append(folderToParent)
        folderEntity.properties.append(folderToChildren)
        folderEntity.properties.append(folderToVideos)
        
        // Add entities to model
        model.entities = [videoEntity, folderEntity, subtitleEntity, libraryEntity]
        
        return model
    }()
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
    }
    
    func saveContext() throws {
        let context = persistentContainer.viewContext
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                do {
                    let result = try block(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
