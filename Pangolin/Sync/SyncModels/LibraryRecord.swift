//
//  LibraryRecord.swift
//  Pangolin
//
//  CloudKit record model for Library entities
//  Handles conversion between Core Data and CloudKit
//

import Foundation
import CloudKit
import CoreData
import OSLog

struct LibraryRecord {
    static let recordType = "Library"
    
    // CloudKit record
    let record: CKRecord
    
    // Computed properties from record
    var recordID: CKRecord.ID { record.recordID }
    var name: String { record["name"] as? String ?? "" }
    var createdDate: Date { record["createdDate"] as? Date ?? Date() }
    var lastModified: Date { record["lastModified"] as? Date ?? Date() }
    var libraryPath: String { record["libraryPath"] as? String ?? "" }
    var version: String { record["version"] as? String ?? "1.0.0" }
    
    // Optional metadata  
    var videoStorageType: String? { record["videoStorageType"] as? String }
    var copyFilesOnImport: Bool { record["copyFilesOnImport"] as? Bool ?? true }
    var organizeByDate: Bool { record["organizeByDate"] as? Bool ?? true }
    
    private static let logger = Logger(subsystem: "com.pangolin.sync", category: "LibraryRecord")
    
    // MARK: - Initialization
    
    init(record: CKRecord) {
        self.record = record
    }
    
    // MARK: - Core Data to CloudKit Conversion
    
    /// Create a CloudKit record from a Core Data Library entity
    static func create(from library: Library) async throws -> LibraryRecord {
        guard let libraryID = library.id else {
            throw LibraryRecordError.missingLibraryID
        }
        
        // Create record ID using library UUID
        let recordID = CKRecord.ID(recordName: "\(libraryID.uuidString)-library")
        let record = CKRecord(recordType: recordType, recordID: recordID)
        
        logger.info("📚 Creating CloudKit record for library: \(library.name ?? "unknown")")
        
        // Basic properties
        record["name"] = library.name as CKRecordValue?
        record["createdDate"] = library.createdDate as CKRecordValue?
        record["lastModified"] = Date() as CKRecordValue
        record["libraryPath"] = library.libraryPath as CKRecordValue?
        record["version"] = library.version as CKRecordValue?
        
        // Storage settings
        record["videoStorageType"] = library.videoStorageType as CKRecordValue?
        record["copyFilesOnImport"] = library.copyFilesOnImport as CKRecordValue
        record["organizeByDate"] = library.organizeByDate as CKRecordValue
        
        return LibraryRecord(record: record)
    }
    
    // MARK: - CloudKit to Core Data Conversion
    
    /// Update Core Data Library entity from CloudKit record
    static func updateCoreData(from record: CKRecord, libraryID: UUID, localStore: CoreDataStack) async throws {
        try await localStore.performBackgroundTask { context in
            // Find existing library or create new one
            let fetchRequest = Library.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
            
            let library: Library
            if let existingLibrary = try context.fetch(fetchRequest).first {
                library = existingLibrary
                logger.info("📚 Updating existing library: \(libraryID)")
            } else {
                // Create new library entity
                guard let entityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Library"] else {
                    throw LibraryRecordError.coreDataEntityNotFound
                }
                
                library = Library(entity: entityDescription, insertInto: context)
                library.id = libraryID
                logger.info("📚 Creating new library: \(libraryID)")
            }
            
            // Update properties
            library.name = record["name"] as? String
            library.createdDate = record["createdDate"] as? Date
            library.libraryPath = record["libraryPath"] as? String
            library.version = record["version"] as? String ?? "1.0.0"
            
            // Update storage settings
            library.videoStorageType = record["videoStorageType"] as? String
            library.copyFilesOnImport = record["copyFilesOnImport"] as? Bool ?? true
            library.organizeByDate = record["organizeByDate"] as? Bool ?? true
            
            // Save context
            try context.save()
            logger.info("✅ Library updated in Core Data: \(libraryID)")
        }
    }
    
    // MARK: - Conflict Resolution
    
    /// Merge two library records, preferring the newer version
    static func merge(serverRecord: CKRecord, clientRecord: CKRecord) throws -> CKRecord {
        logger.info("🔀 Merging library records for conflict resolution")
        
        // Use server record as base
        let mergedRecord = serverRecord.copy() as! CKRecord
        
        // Compare modification dates and take newer values for specific fields
        let serverModified = serverRecord.modificationDate ?? Date.distantPast
        let clientModified = clientRecord.modificationDate ?? Date.distantPast
        
        // For user-editable content, prefer newer version
        if clientModified > serverModified {
            // Prefer client version for user edits
            if let clientName = clientRecord["name"] as? String {
                mergedRecord["name"] = clientName as CKRecordValue
            }
            
            if let clientCopyFiles = clientRecord["copyFilesOnImport"] as? Bool {
                mergedRecord["copyFilesOnImport"] = clientCopyFiles as CKRecordValue
            }
            
            if let clientOrganize = clientRecord["organizeByDate"] as? Bool {
                mergedRecord["organizeByDate"] = clientOrganize as CKRecordValue
            }
        }
        
        // Always use the most recent lastModified
        let mostRecentModified = max(serverModified, clientModified)
        mergedRecord["lastModified"] = mostRecentModified as CKRecordValue
        
        logger.info("✅ Library records merged successfully")
        return mergedRecord
    }
}

// MARK: - Error Types

enum LibraryRecordError: Error, LocalizedError {
    case missingLibraryID
    case coreDataEntityNotFound
    case recordCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .missingLibraryID:
            return "Library is missing required ID"
        case .coreDataEntityNotFound:
            return "Core Data Library entity not found"
        case .recordCreationFailed(let reason):
            return "Failed to create CloudKit record: \(reason)"
        }
    }
}