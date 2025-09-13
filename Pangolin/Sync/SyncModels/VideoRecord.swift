//
//  VideoRecord.swift
//  Pangolin
//
//  CloudKit record model for Video entities
//  Handles conversion between Core Data and CloudKit
//

import Foundation
import CloudKit
import CoreData
import OSLog

struct VideoRecord {
    static let recordType = "Video"
    
    // CloudKit record
    let record: CKRecord
    
    // Computed properties from record
    var recordID: CKRecord.ID { record.recordID }
    var title: String { record["title"] as? String ?? "" }
    var fileName: String { record["fileName"] as? String ?? "" }
    var videoFormat: String { record["videoFormat"] as? String ?? "" }
    var fileSize: Int64 { record["fileSize"] as? Int64 ?? 0 }
    var dateAdded: Date { record["dateAdded"] as? Date ?? Date() }
    var relativePath: String { record["relativePath"] as? String ?? "" }
    var videoAsset: CKAsset? { record["videoAsset"] as? CKAsset }
    var thumbnailAsset: CKAsset? { record["thumbnailAsset"] as? CKAsset }
    
    // Optional metadata
    var duration: Double? { record["duration"] as? Double }
    var transcriptText: String? { record["transcriptText"] as? String }
    var translatedText: String? { record["translatedText"] as? String }
    var transcriptSummary: String? { record["transcriptSummary"] as? String }
    var transcriptDateGenerated: Date? { record["transcriptDateGenerated"] as? Date }
    var translationDateGenerated: Date? { record["translationDateGenerated"] as? Date }
    var summaryDateGenerated: Date? { record["summaryDateGenerated"] as? Date }
    
    private static let logger = Logger(subsystem: "com.pangolin.sync", category: "VideoRecord")
    
    // MARK: - Initialization
    
    init(record: CKRecord) {
        self.record = record
    }
    
    // MARK: - Core Data to CloudKit Conversion
    
    /// Create a CloudKit record from a Core Data Video entity
    static func create(from video: Video, localStore: CoreDataStack) async throws -> VideoRecord {
        guard let videoID = video.id else {
            throw VideoRecordError.missingVideoID
        }
        
        // Create record ID using video UUID
        let recordID = CKRecord.ID(recordName: "\(videoID.uuidString)-video")
        let record = CKRecord(recordType: recordType, recordID: recordID)
        
        logger.info("📝 Creating CloudKit record for video: \(video.title ?? "unknown")")
        
        // Basic properties
        record["title"] = video.title as CKRecordValue?
        record["fileName"] = video.fileName as CKRecordValue?
        record["videoFormat"] = video.videoFormat as CKRecordValue?
        record["fileSize"] = video.fileSize as CKRecordValue?
        record["dateAdded"] = video.dateAdded as CKRecordValue?
        record["relativePath"] = video.relativePath as CKRecordValue?
        
        // Optional properties
        if video.duration > 0 {
            record["duration"] = video.duration as CKRecordValue
        }
        
        if let transcriptText = video.transcriptText, !transcriptText.isEmpty {
            record["transcriptText"] = transcriptText as CKRecordValue
            record["transcriptDateGenerated"] = video.transcriptDateGenerated as CKRecordValue?
        }
        
        if let translatedText = video.translatedText, !translatedText.isEmpty {
            record["translatedText"] = translatedText as CKRecordValue
            record["translationDateGenerated"] = video.translationDateGenerated as CKRecordValue?
        }
        
        if let transcriptSummary = video.transcriptSummary, !transcriptSummary.isEmpty {
            record["transcriptSummary"] = transcriptSummary as CKRecordValue
            record["summaryDateGenerated"] = video.summaryDateGenerated as CKRecordValue?
        }
        
        // Handle video file asset
        if let relativePath = video.relativePath,
           let libraryURL = video.library?.url {
            let videoFileURL = libraryURL.appendingPathComponent(relativePath)
            
            if FileManager.default.fileExists(atPath: videoFileURL.path) {
                let videoAsset = CKAsset(fileURL: videoFileURL)
                record["videoAsset"] = videoAsset
                logger.info("📎 Added video asset: \(videoFileURL.lastPathComponent)")
            } else {
                logger.warning("⚠️ Video file not found: \(videoFileURL.path)")
            }
        }
        
        // Handle thumbnail asset
        if let thumbnailPath = video.thumbnailPath,
           let libraryURL = video.library?.url {
            let thumbnailURL = libraryURL.appendingPathComponent(thumbnailPath)
            
            if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                let thumbnailAsset = CKAsset(fileURL: thumbnailURL)
                record["thumbnailAsset"] = thumbnailAsset
                logger.info("🖼️ Added thumbnail asset: \(thumbnailURL.lastPathComponent)")
            }
        }
        
        return VideoRecord(record: record)
    }
    
    // MARK: - CloudKit to Core Data Conversion
    
    /// Update Core Data Video entity from CloudKit record
    static func updateCoreData(from record: CKRecord, videoID: UUID, localStore: CoreDataStack) async throws {
        try await localStore.performBackgroundTask { context in
            // Find existing video or create new one
            let fetchRequest = Video.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
            
            let video: Video
            if let existingVideo = try context.fetch(fetchRequest).first {
                video = existingVideo
                logger.info("📝 Updating existing video: \(videoID)")
            } else {
                // Create new video entity
                guard let entityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
                    throw VideoRecordError.coreDataEntityNotFound
                }
                
                video = Video(entity: entityDescription, insertInto: context)
                video.id = videoID
                
                // Associate with current library for new videos
                let libraryFetchRequest = Library.fetchRequest()
                if let currentLibrary = try context.fetch(libraryFetchRequest).first {
                    video.library = currentLibrary
                    logger.info("📝 Creating new video: \(videoID) in library: \(currentLibrary.name ?? "Unknown")")
                } else {
                    logger.warning("⚠️ No library found for new video: \(videoID)")
                }
            }
            
            // Update basic properties
            video.title = record["title"] as? String
            video.fileName = record["fileName"] as? String
            video.videoFormat = record["videoFormat"] as? String
            video.fileSize = record["fileSize"] as? Int64 ?? 0
            video.dateAdded = record["dateAdded"] as? Date
            video.relativePath = record["relativePath"] as? String
            
            // Update optional properties
            if let duration = record["duration"] as? Double {
                video.duration = duration
            }
            
            video.transcriptText = record["transcriptText"] as? String
            video.transcriptDateGenerated = record["transcriptDateGenerated"] as? Date
            
            video.translatedText = record["translatedText"] as? String
            video.translationDateGenerated = record["translationDateGenerated"] as? Date
            
            video.transcriptSummary = record["transcriptSummary"] as? String
            video.summaryDateGenerated = record["summaryDateGenerated"] as? Date
            
            // Handle video file download - simplified for sync version
            if let videoAsset = record["videoAsset"] as? CKAsset,
               let _ = videoAsset.fileURL,
               let relativePath = video.relativePath,
               let library = video.library,
               let libraryURL = library.url {
                
                let targetURL = libraryURL.appendingPathComponent(relativePath)
                // Note: File download should be handled separately in async context
                logger.info("📁 Video asset available for download: \(targetURL.lastPathComponent)")
            }
            
            // Handle thumbnail download - simplified for sync version  
            if let thumbnailAsset = record["thumbnailAsset"] as? CKAsset,
               let _ = thumbnailAsset.fileURL {
                
                let thumbnailPath = "Thumbnails/\(videoID.uuidString).jpg"
                video.thumbnailPath = thumbnailPath
                logger.info("📁 Thumbnail asset available for download: \(thumbnailPath)")
            }
            
            // Save context
            try context.save()
            logger.info("✅ Video updated in Core Data: \(videoID)")
        }
    }
    
    // MARK: - Asset Handling
    
    /// Download a CloudKit asset to local file system
    private static func downloadAsset(from sourceURL: URL, to targetURL: URL) async throws {
        logger.info("📥 Downloading asset: \(sourceURL.lastPathComponent) -> \(targetURL.lastPathComponent)")
        
        // Ensure target directory exists
        let targetDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        // Copy file from CloudKit cache to target location
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        logger.info("✅ Asset downloaded successfully: \(targetURL.lastPathComponent)")
    }
    
    // MARK: - Conflict Resolution
    
    /// Merge two video records, preferring the newer version
    static func merge(serverRecord: CKRecord, clientRecord: CKRecord) throws -> CKRecord {
        logger.info("🔀 Merging video records for conflict resolution")
        
        // Use server record as base
        let mergedRecord = serverRecord.copy() as! CKRecord
        
        // Compare modification dates and take newer values for specific fields
        let serverModified = serverRecord.modificationDate ?? Date.distantPast
        let clientModified = clientRecord.modificationDate ?? Date.distantPast
        
        // For user-generated content, prefer newer version
        if clientModified > serverModified {
            // Prefer client version for user edits
            if let clientTitle = clientRecord["title"] as? String {
                mergedRecord["title"] = clientTitle as CKRecordValue
            }
            
            // Keep newer transcription/translation data
            if let clientTranscript = clientRecord["transcriptText"] as? String {
                mergedRecord["transcriptText"] = clientTranscript as CKRecordValue
                mergedRecord["transcriptDateGenerated"] = clientRecord["transcriptDateGenerated"]
            }
            
            if let clientTranslation = clientRecord["translatedText"] as? String {
                mergedRecord["translatedText"] = clientTranslation as CKRecordValue
                mergedRecord["translationDateGenerated"] = clientRecord["translationDateGenerated"]
            }
            
            if let clientSummary = clientRecord["transcriptSummary"] as? String {
                mergedRecord["transcriptSummary"] = clientSummary as CKRecordValue
                mergedRecord["summaryDateGenerated"] = clientRecord["summaryDateGenerated"]
            }
        }
        
        logger.info("✅ Video records merged successfully")
        return mergedRecord
    }
}

// MARK: - Error Types

enum VideoRecordError: Error, LocalizedError {
    case missingVideoID
    case coreDataEntityNotFound
    case assetUploadFailed(String)
    case assetDownloadFailed(String)
    case recordCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .missingVideoID:
            return "Video is missing required ID"
        case .coreDataEntityNotFound:
            return "Core Data Video entity not found"
        case .assetUploadFailed(let reason):
            return "Failed to upload asset: \(reason)"
        case .assetDownloadFailed(let reason):
            return "Failed to download asset: \(reason)"
        case .recordCreationFailed(let reason):
            return "Failed to create CloudKit record: \(reason)"
        }
    }
}