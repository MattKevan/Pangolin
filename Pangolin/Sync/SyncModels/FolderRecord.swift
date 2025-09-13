//
//  FolderRecord.swift
//  Pangolin
//
//  CloudKit record model for Folder entities
//  Handles conversion between Core Data and CloudKit
//

import Foundation
import CloudKit
import CoreData
import OSLog

struct FolderRecord {
    static let recordType = "Folder"
    
    // CloudKit record
    let record: CKRecord
    
    // Computed properties from record
    var recordID: CKRecord.ID { record.recordID }
    var name: String { record["name"] as? String ?? "" }
    var dateCreated: Date { record["dateCreated"] as? Date ?? Date() }
    var isSmartFolder: Bool { record["isSmartFolder"] as? Bool ?? false }
    var isTopLevel: Bool { record["isTopLevel"] as? Bool ?? false }
    
    // Relationship references
    var parentFolderReference: CKRecord.Reference? { record["parentFolder"] as? CKRecord.Reference }
    var libraryReference: CKRecord.Reference { record["library"] as! CKRecord.Reference }
    
    private static let logger = Logger(subsystem: "com.pangolin.sync", category: "FolderRecord")
    
    // MARK: - Initialization
    
    init(record: CKRecord) {
        self.record = record
    }
    
    // MARK: - Core Data to CloudKit Conversion
    
    /// Create a CloudKit record from a Core Data Folder entity
    static func create(from folder: Folder) async throws -> FolderRecord {
        guard let folderID = folder.id else {
            throw FolderRecordError.missingFolderID
        }
        
        guard let library = folder.library, let libraryID = library.id else {
            throw FolderRecordError.missingLibraryReference
        }
        
        // Create record ID using folder UUID
        let recordID = CKRecord.ID(recordName: "\(folderID.uuidString)-folder")
        let record = CKRecord(recordType: recordType, recordID: recordID)
        
        logger.info("📁 Creating CloudKit record for folder: \(folder.name ?? "unknown")")
        
        // Basic properties
        record["name"] = folder.name as CKRecordValue?
        record["dateCreated"] = folder.dateCreated as CKRecordValue?
        record["isSmartFolder"] = folder.isSmartFolder as CKRecordValue
        record["isTopLevel"] = folder.isTopLevel as CKRecordValue
        
        // Library reference (required)
        let libraryRecordID = CKRecord.ID(recordName: "\(libraryID.uuidString)-library")
        record["library"] = CKRecord.Reference(recordID: libraryRecordID, action: .deleteSelf)
        
        // Parent folder reference (optional)
        if let parentFolder = folder.parentFolder, let parentFolderID = parentFolder.id {
            let parentRecordID = CKRecord.ID(recordName: "\(parentFolderID.uuidString)-folder")
            record["parentFolder"] = CKRecord.Reference(recordID: parentRecordID, action: .deleteSelf)
        }
        
        return FolderRecord(record: record)
    }
    
    // MARK: - CloudKit to Core Data Conversion
    
    /// Update Core Data Folder entity from CloudKit record
    static func updateCoreData(from record: CKRecord, folderID: UUID, localStore: CoreDataStack) async throws {
        try await localStore.performBackgroundTask { context in
            // Find existing folder or create new one
            let fetchRequest = Folder.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", folderID as CVarArg)
            
            let folder: Folder
            if let existingFolder = try context.fetch(fetchRequest).first {
                folder = existingFolder
                logger.info("📁 Updating existing folder: \(folderID)")
            } else {
                // Create new folder entity
                guard let entityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
                    throw FolderRecordError.coreDataEntityNotFound
                }
                
                folder = Folder(entity: entityDescription, insertInto: context)
                folder.id = folderID
                logger.info("📁 Creating new folder: \(folderID)")
            }
            
            // Update basic properties
            folder.name = record["name"] as? String
            folder.dateCreated = record["dateCreated"] as? Date
            folder.isSmartFolder = record["isSmartFolder"] as? Bool ?? false
            folder.isTopLevel = record["isTopLevel"] as? Bool ?? false
            
            // Handle library relationship
            if let libraryRef = record["library"] as? CKRecord.Reference {
                let libraryIDString = libraryRef.recordID.recordName.replacingOccurrences(of: "-library", with: "")
                if let libraryUUID = UUID(uuidString: libraryIDString) {
                    let libraryFetchRequest = Library.fetchRequest()
                    libraryFetchRequest.predicate = NSPredicate(format: "id == %@", libraryUUID as CVarArg)
                    
                    if let library = try context.fetch(libraryFetchRequest).first {
                        folder.library = library
                    } else {
                        logger.warning("⚠️ Library not found for folder: \(libraryUUID)")
                    }
                }
            }
            
            // Handle parent folder relationship
            if let parentRef = record["parentFolder"] as? CKRecord.Reference {
                let parentIDString = parentRef.recordID.recordName.replacingOccurrences(of: "-folder", with: "")
                if let parentUUID = UUID(uuidString: parentIDString) {
                    let parentFetchRequest = Folder.fetchRequest()
                    parentFetchRequest.predicate = NSPredicate(format: "id == %@", parentUUID as CVarArg)
                    
                    if let parentFolder = try context.fetch(parentFetchRequest).first {
                        folder.parentFolder = parentFolder
                    } else {
                        logger.warning("⚠️ Parent folder not found: \(parentUUID)")
                    }
                }
            } else {
                folder.parentFolder = nil
            }
            
            // Save context
            try context.save()
            logger.info("✅ Folder updated in Core Data: \(folderID)")
        }
    }
    
    // MARK: - Conflict Resolution
    
    /// Merge two folder records, preferring the newer version
    static func merge(serverRecord: CKRecord, clientRecord: CKRecord) throws -> CKRecord {
        logger.info("🔀 Merging folder records for conflict resolution")
        
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
            
            if let clientTopLevel = clientRecord["isTopLevel"] as? Bool {
                mergedRecord["isTopLevel"] = clientTopLevel as CKRecordValue
            }
            
            // Update parent folder if client moved it
            if let clientParentRef = clientRecord["parentFolder"] as? CKRecord.Reference {
                mergedRecord["parentFolder"] = clientParentRef
            } else if clientRecord["parentFolder"] == nil {
                mergedRecord["parentFolder"] = nil
            }
        }
        
        logger.info("✅ Folder records merged successfully")
        return mergedRecord
    }
    
    // MARK: - Helper Methods
    
    /// Extract UUID from folder record ID
    static func extractFolderID(from recordID: CKRecord.ID) -> UUID? {
        let recordName = recordID.recordName
        let folderIDString = recordName.replacingOccurrences(of: "-folder", with: "")
        return UUID(uuidString: folderIDString)
    }
    
    /// Extract UUID from library reference
    static func extractLibraryID(from reference: CKRecord.Reference) -> UUID? {
        let recordName = reference.recordID.recordName
        let libraryIDString = recordName.replacingOccurrences(of: "-library", with: "")
        return UUID(uuidString: libraryIDString)
    }
    
    /// Extract UUID from parent folder reference
    static func extractParentFolderID(from reference: CKRecord.Reference?) -> UUID? {
        guard let reference = reference else { return nil }
        let recordName = reference.recordID.recordName
        let folderIDString = recordName.replacingOccurrences(of: "-folder", with: "")
        return UUID(uuidString: folderIDString)
    }
}

// MARK: - Error Types

enum FolderRecordError: Error, LocalizedError {
    case missingFolderID
    case missingLibraryReference
    case coreDataEntityNotFound
    case recordCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .missingFolderID:
            return "Folder is missing required ID"
        case .missingLibraryReference:
            return "Folder is missing required library reference"
        case .coreDataEntityNotFound:
            return "Core Data Folder entity not found"
        case .recordCreationFailed(let reason):
            return "Failed to create CloudKit record: \(reason)"
        }
    }
}