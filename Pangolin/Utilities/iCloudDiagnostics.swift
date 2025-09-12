//
//  iCloudDiagnostics.swift
//  Pangolin
//
//  Utilities for diagnosing iCloud sync issues and monitoring file status
//

import Foundation
import CoreData
import SQLite3

@MainActor
class iCloudDiagnostics: ObservableObject {
    static let shared = iCloudDiagnostics()
    
    @Published var iCloudStatus: iCloudStatus = .unknown
    @Published var librarySync: LibrarySyncStatus = .unknown
    @Published var lastDiagnosticRun: Date?
    
    private let fileManager = FileManager.default
    
    private init() {}
    
    // MARK: - iCloud Status Monitoring
    
    func runFullDiagnostics() async -> DiagnosticReport {
        print("🔍 iCloud Diagnostics: Starting full diagnostic scan...")
        
        lastDiagnosticRun = Date()
        
        var report = DiagnosticReport()
        
        // 1. Check iCloud availability
        report.iCloudAvailable = checkiCloudAvailability()
        
        // 2. Check iCloud Drive status
        if report.iCloudAvailable {
            report.iCloudDriveStatus = await checkiCloudDriveStatus()
        }
        
        // 3. Check library file status
        if let libraryURL = await getLibraryURL() {
            report.libraryFileStatus = await checkFileStatus(url: libraryURL)
            report.librarySize = getFileSize(url: libraryURL)
        }
        
        // 4. Check database integrity
        report.databaseIntegrity = await checkDatabaseIntegrity()
        
        // 5. Check for sync conflicts
        report.syncConflicts = await detectSyncConflicts()
        
        // Update published status
        updateStatus(from: report)
        
        print("✅ iCloud Diagnostics: Diagnostic complete")
        printDiagnosticReport(report)
        
        return report
    }
    
    private func checkiCloudAvailability() -> Bool {
        let available = fileManager.url(forUbiquityContainerIdentifier: nil) != nil
        print("☁️ iCloud Available: \(available)")
        return available
    }
    
    private func checkiCloudDriveStatus() async -> iCloudDriveStatus {
        guard let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            return .unavailable
        }
        
        do {
            let resourceValues = try iCloudURL.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemHasUnresolvedConflictsKey
            ])
            
            if resourceValues.ubiquitousItemHasUnresolvedConflicts == true {
                return .hasConflicts
            }
            
            return .available
        } catch {
            print("❌ Error checking iCloud Drive status: \(error)")
            return .error(error)
        }
    }
    
    private func getLibraryURL() async -> URL? {
        guard let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        
        let pangolinDirectory = iCloudURL.appendingPathComponent("Pangolin")
        let defaultLibraryName = "My Video Library"
        return pangolinDirectory.appendingPathComponent("\(defaultLibraryName).pangolin")
    }
    
    private func checkFileStatus(url: URL) async -> FileStatus {
        guard fileManager.fileExists(atPath: url.path) else {
            return .notFound
        }
        
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemHasUnresolvedConflictsKey,
                .ubiquitousItemDownloadingErrorKey
            ])
            
            // Check for conflicts first
            if resourceValues.ubiquitousItemHasUnresolvedConflicts == true {
                return .hasConflicts
            }
            
            // Check for download errors
            if let error = resourceValues.ubiquitousItemDownloadingError {
                return .downloadError(error)
            }
            
            // Check download status
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                switch downloadStatus {
                case .current:
                    return .current
                case .downloaded:
                    return .downloaded
                case .notDownloaded:
                    return .notDownloaded
                default:
                    return .unknown
                }
            }
            
            return .local
        } catch {
            return .error(error)
        }
    }
    
    private func getFileSize(url: URL) -> Int64 {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(resourceValues.fileSize ?? 0)
        } catch {
            return 0
        }
    }
    
    private func checkDatabaseIntegrity() async -> DatabaseIntegrity {
        // Check if we can create a Core Data stack without errors
        guard let libraryURL = await getLibraryURL() else {
            return .noDatabase
        }
        
        let databaseURL = libraryURL.appendingPathComponent("Library.sqlite")
        
        // First check if database file exists
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return .noDatabase
        }
        
        // Try to open SQLite connection directly to test corruption
        var sqlite: OpaquePointer?
        let result = sqlite3_open(databaseURL.path, &sqlite)
        
        if result == SQLITE_OK {
            // Try to execute a simple query to detect corruption
            let testQuery = "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1"
            var statement: OpaquePointer?
            
            let prepareResult = sqlite3_prepare_v2(sqlite, testQuery, -1, &statement, nil)
            if prepareResult == SQLITE_OK {
                let stepResult = sqlite3_step(statement)
                sqlite3_finalize(statement)
                sqlite3_close(sqlite)
                
                if stepResult == SQLITE_ROW || stepResult == SQLITE_DONE {
                    return .healthy
                } else if stepResult == SQLITE_CORRUPT {
                    return .corrupted(NSError(domain: "SQLiteCorruption", code: 11, userInfo: [NSLocalizedDescriptionKey: "Database is corrupted"]))
                }
            } else {
                sqlite3_close(sqlite)
                if prepareResult == SQLITE_CORRUPT {
                    return .corrupted(NSError(domain: "SQLiteCorruption", code: 11, userInfo: [NSLocalizedDescriptionKey: "Database is corrupted"]))
                }
            }
        } else {
            if sqlite != nil {
                sqlite3_close(sqlite)
            }
            if result == SQLITE_CORRUPT {
                return .corrupted(NSError(domain: "SQLiteCorruption", code: 11, userInfo: [NSLocalizedDescriptionKey: "Database is corrupted"]))
            }
        }
        
        // If we get here, try Core Data stack as backup test
        do {
            let _ = try CoreDataStack(libraryURL: libraryURL)
            return .healthy
        } catch {
            if let nsError = error as NSError? {
                if nsError.code == 11 || nsError.code == 134030 { // SQLite corruption
                    return .corrupted(error)
                }
            }
            return .error(error)
        }
    }
    
    private func detectSyncConflicts() async -> [SyncConflict] {
        var conflicts: [SyncConflict] = []
        
        guard let libraryURL = await getLibraryURL() else {
            return conflicts
        }
        
        // Check for .icloud files (indicates sync issues)
        let libraryParent = libraryURL.deletingLastPathComponent()
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: libraryParent, includingPropertiesForKeys: nil)
            
            for file in contents {
                if file.lastPathComponent.hasPrefix(".") && file.pathExtension == "icloud" {
                    conflicts.append(SyncConflict(
                        type: .pendingUpload,
                        file: file,
                        description: "File pending upload to iCloud"
                    ))
                }
                
                if file.lastPathComponent.contains(" (Conflicted copy") {
                    conflicts.append(SyncConflict(
                        type: .conflictedCopy,
                        file: file,
                        description: "Conflicted copy detected"
                    ))
                }
            }
        } catch {
            print("❌ Error detecting sync conflicts: \(error)")
        }
        
        return conflicts
    }
    
    private func updateStatus(from report: DiagnosticReport) {
        if !report.iCloudAvailable {
            iCloudStatus = .unavailable
        } else if report.syncConflicts.count > 0 {
            iCloudStatus = .hasConflicts
        } else if case .corrupted(_) = report.databaseIntegrity {
            iCloudStatus = .databaseCorrupted
        } else {
            iCloudStatus = .healthy
        }
        
        // Update library sync status
        if case .hasConflicts = report.libraryFileStatus {
            librarySync = .conflicts
        } else if case .current = report.libraryFileStatus {
            librarySync = .synced
        } else if case .notDownloaded = report.libraryFileStatus {
            librarySync = .downloading
        } else {
            librarySync = .unknown
        }
    }
    
    private func printDiagnosticReport(_ report: DiagnosticReport) {
        print("\n📊 === iCloud Diagnostic Report ===")
        print("☁️ iCloud Available: \(report.iCloudAvailable)")
        print("💾 iCloud Drive: \(report.iCloudDriveStatus)")
        print("📁 Library File: \(report.libraryFileStatus)")
        print("💽 Database: \(report.databaseIntegrity)")
        print("⚠️ Conflicts: \(report.syncConflicts.count)")
        
        if !report.syncConflicts.isEmpty {
            print("\n🔍 Sync Conflicts:")
            for conflict in report.syncConflicts {
                print("  - \(conflict.type): \(conflict.file.lastPathComponent)")
            }
        }
        
        print("📊 === End Report ===\n")
    }
    
    // MARK: - Repair Methods
    
    func attemptAutoRepair() async -> RepairResult {
        let report = await runFullDiagnostics()
        
        // Try to resolve common issues
        var repairActions: [String] = []
        
        // 1. Handle sync conflicts
        if !report.syncConflicts.isEmpty {
            let conflictResult = await resolveSyncConflicts(report.syncConflicts)
            repairActions.append("Resolved \(conflictResult) sync conflicts")
        }
        
        // 2. Handle database corruption
        if case .corrupted(let error) = report.databaseIntegrity {
            let dbResult = await repairDatabase(error: error)
            repairActions.append("Database repair: \(dbResult)")
        }
        
        // 3. Force re-download if needed
        if case .notDownloaded = report.libraryFileStatus {
            let downloadResult = await forceLibraryDownload()
            repairActions.append("Forced download: \(downloadResult)")
        }
        
        return RepairResult(
            success: !repairActions.isEmpty,
            actions: repairActions,
            requiresManualIntervention: false
        )
    }
    
    private func resolveSyncConflicts(_ conflicts: [SyncConflict]) async -> Int {
        var resolved = 0
        
        for conflict in conflicts {
            switch conflict.type {
            case .pendingUpload:
                // Try to force upload
                if await forceUpload(file: conflict.file) {
                    resolved += 1
                }
            case .conflictedCopy:
                // This requires manual resolution
                print("⚠️ Manual intervention needed for: \(conflict.file.lastPathComponent)")
            }
        }
        
        return resolved
    }
    
    private func repairDatabase(error: Error) async -> String {
        guard let libraryURL = await getLibraryURL() else {
            return "No library URL found"
        }
        
        let databaseURL = libraryURL.appendingPathComponent("Library.sqlite")
        let backupURL = databaseURL.appendingPathExtension("backup")
        
        do {
            // Create backup of corrupted database
            if fileManager.fileExists(atPath: databaseURL.path) {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: databaseURL, to: backupURL)
            }
            
            // Remove corrupted database and related files
            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.removeItem(at: databaseURL)
            }
            
            let walURL = databaseURL.appendingPathExtension("sqlite-wal")
            let shmURL = databaseURL.appendingPathExtension("sqlite-shm")
            
            if fileManager.fileExists(atPath: walURL.path) {
                try fileManager.removeItem(at: walURL)
            }
            if fileManager.fileExists(atPath: shmURL.path) {
                try fileManager.removeItem(at: shmURL)
            }
            
            return "Database corruption repaired. Backup created at \(backupURL.lastPathComponent). App restart required."
        } catch {
            return "Database repair failed: \(error.localizedDescription)"
        }
    }
    
    private func forceLibraryDownload() async -> String {
        guard let libraryURL = await getLibraryURL() else {
            return "No library URL found"
        }
        
        do {
            try fileManager.startDownloadingUbiquitousItem(at: libraryURL)
            return "Download initiated"
        } catch {
            return "Download failed: \(error.localizedDescription)"
        }
    }
    
    private func forceUpload(file: URL) async -> Bool {
        // This would require more complex logic to force iCloud upload
        return false
    }
}

// MARK: - Data Structures

enum iCloudStatus {
    case unknown
    case unavailable
    case healthy
    case hasConflicts
    case databaseCorrupted
}

enum LibrarySyncStatus {
    case unknown
    case synced
    case conflicts
    case downloading
    case uploadPending
}

enum iCloudDriveStatus {
    case unavailable
    case available
    case hasConflicts
    case error(Error)
}

enum FileStatus {
    case notFound
    case local
    case current
    case downloaded
    case notDownloaded
    case hasConflicts
    case downloadError(Error)
    case error(Error)
    case unknown
}

enum DatabaseIntegrity {
    case noDatabase
    case healthy
    case corrupted(Error)
    case error(Error)
}

struct SyncConflict {
    enum ConflictType {
        case pendingUpload
        case conflictedCopy
    }
    
    let type: ConflictType
    let file: URL
    let description: String
}

struct DiagnosticReport {
    var iCloudAvailable: Bool = false
    var iCloudDriveStatus: iCloudDriveStatus = .unavailable
    var libraryFileStatus: FileStatus = .notFound
    var librarySize: Int64 = 0
    var databaseIntegrity: DatabaseIntegrity = .noDatabase
    var syncConflicts: [SyncConflict] = []
}

struct RepairResult {
    let success: Bool
    let actions: [String]
    let requiresManualIntervention: Bool
}