//
//  CoreDataStack.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


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
            ("frameRate", .doubleAttributeType, 0.0)
        ]
        
        videoEntity.properties = videoAttributes.map { name, type, defaultValue in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = (name == "lastPlayed" || name == "thumbnailPath" || name == "videoFormat" || name == "resolution")
            attribute.defaultValue = defaultValue
            return attribute
        }
        
        // Playlist Entity
        let playlistEntity = NSEntityDescription()
        playlistEntity.name = "Playlist"
        playlistEntity.managedObjectClassName = NSStringFromClass(Playlist.self)
        
        let playlistAttributes: [(String, NSAttributeType, Any?)] = [
            ("id", .UUIDAttributeType, nil),
            ("name", .stringAttributeType, ""),
            ("type", .stringAttributeType, "user"),
            ("sortOrder", .integer32AttributeType, 0),
            ("dateCreated", .dateAttributeType, Date()),
            ("dateModified", .dateAttributeType, Date()),
            ("iconName", .stringAttributeType, nil),
            ("color", .stringAttributeType, nil)
        ]
        
        playlistEntity.properties = playlistAttributes.map { name, type, defaultValue in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = (name == "iconName" || name == "color")
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
        
        // Playlist -> Library (many-to-one)
        let playlistToLibrary = NSRelationshipDescription()
        playlistToLibrary.name = "library"
        playlistToLibrary.destinationEntity = libraryEntity
        playlistToLibrary.minCount = 0
        playlistToLibrary.maxCount = 1
        playlistToLibrary.isOptional = true
        
        // Library -> Playlists (one-to-many)
        let libraryToPlaylists = NSRelationshipDescription()
        libraryToPlaylists.name = "playlists"
        libraryToPlaylists.destinationEntity = playlistEntity
        libraryToPlaylists.minCount = 0
        libraryToPlaylists.maxCount = 0
        libraryToPlaylists.isOptional = true
        libraryToPlaylists.inverseRelationship = playlistToLibrary
        playlistToLibrary.inverseRelationship = libraryToPlaylists
        
        // Playlist -> Parent Playlist (many-to-one)
        let playlistToParent = NSRelationshipDescription()
        playlistToParent.name = "parentPlaylist"
        playlistToParent.destinationEntity = playlistEntity
        playlistToParent.minCount = 0
        playlistToParent.maxCount = 1
        playlistToParent.isOptional = true
        
        // Playlist -> Child Playlists (one-to-many)
        let playlistToChildren = NSRelationshipDescription()
        playlistToChildren.name = "childPlaylists"
        playlistToChildren.destinationEntity = playlistEntity
        playlistToChildren.minCount = 0
        playlistToChildren.maxCount = 0
        playlistToChildren.isOptional = true
        playlistToChildren.inverseRelationship = playlistToParent
        playlistToParent.inverseRelationship = playlistToChildren
        
        // Playlist -> Videos (many-to-many)
        let playlistToVideos = NSRelationshipDescription()
        playlistToVideos.name = "videos"
        playlistToVideos.destinationEntity = videoEntity
        playlistToVideos.minCount = 0
        playlistToVideos.maxCount = 0
        playlistToVideos.isOptional = true
        
        // Video -> Playlists (many-to-many)
        let videoToPlaylists = NSRelationshipDescription()
        videoToPlaylists.name = "playlists"
        videoToPlaylists.destinationEntity = playlistEntity
        videoToPlaylists.minCount = 0
        videoToPlaylists.maxCount = 0
        videoToPlaylists.isOptional = true
        videoToPlaylists.inverseRelationship = playlistToVideos
        playlistToVideos.inverseRelationship = videoToPlaylists
        
        // Add relationships to entities
        videoEntity.properties.append(videoToLibrary)
        videoEntity.properties.append(videoToSubtitles)
        videoEntity.properties.append(videoToPlaylists)
        libraryEntity.properties.append(libraryToVideos)
        libraryEntity.properties.append(libraryToPlaylists)
        subtitleEntity.properties.append(subtitleToVideo)
        playlistEntity.properties.append(playlistToLibrary)
        playlistEntity.properties.append(playlistToParent)
        playlistEntity.properties.append(playlistToChildren)
        playlistEntity.properties.append(playlistToVideos)
        
        // Add entities to model
        model.entities = [videoEntity, playlistEntity, subtitleEntity, libraryEntity]
        
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

