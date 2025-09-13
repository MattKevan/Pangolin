//
//  iCloudOrphanManager.swift
//  Pangolin
//
//  Service for detecting and managing orphaned iCloud files
//  (files that exist in iCloud but have no database records)
//

import Foundation
import CoreData
import SwiftUI

struct OrphanedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let createdDate: Date
    let fileExtension: String
    let iCloudStatus: iCloudFileStatus
    
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var isVideo: Bool {
        let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm", "flv"])
        return videoExtensions.contains(fileExtension.lowercased())
    }
}

enum OrphanedFileAction {
    case reimport
    case delete
    case ignore
}

@MainActor
class iCloudOrphanManager: ObservableObject {
    @Published var orphanedFiles: [OrphanedFile] = []
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var statusMessage = ""
    
    private let fileManager = FileManager.default
    
    /// Scan for orphaned files in the iCloud library structure
    func scanForOrphanedFiles(library: Library, context: NSManagedObjectContext) async throws -> [OrphanedFile] {
        isScanning = true
        scanProgress = 0.0
        statusMessage = "Scanning for orphaned files..."
        
        defer {
            Task { @MainActor in
                isScanning = false
                scanProgress = 0.0
                statusMessage = ""
            }
        }
        
        guard let libraryURL = library.url else {
            throw LibraryError.libraryNotFound
        }
        
        // Get all files in the library's Videos directory
        let videosDirectory = libraryURL.appendingPathComponent("Videos")
        let orphans = try await scanDirectory(videosDirectory, excludingKnownFiles: getKnownVideoFiles(from: context))
        
        await MainActor.run {
            self.orphanedFiles = orphans
        }
        
        return orphans
    }
    
    private func scanDirectory(_ directory: URL, excludingKnownFiles knownFiles: Set<String>) async throws -> [OrphanedFile] {
        var orphans: [OrphanedFile] = []
        
        guard fileManager.fileExists(atPath: directory.path) else {
            return orphans
        }
        
        await MainActor.run {
            statusMessage = "Scanning \(directory.lastPathComponent)..."
        }
        
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        
        let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm", "flv"])
        
        for (index, fileURL) in contents.enumerated() {
            let fileName = fileURL.lastPathComponent
            let fileExtension = fileURL.pathExtension.lowercased()
            
            // Update progress
            let progress = Double(index) / Double(contents.count)
            await MainActor.run {
                scanProgress = progress
                statusMessage = "Checking \(fileName)..."
            }
            
            // Skip non-video files and known files
            guard videoExtensions.contains(fileExtension) && !knownFiles.contains(fileName) else {
                continue
            }
            
            // Get file metadata
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey
            ])
            
            let size = Int64(resourceValues.fileSize ?? 0)
            let createdDate = resourceValues.creationDate ?? resourceValues.contentModificationDate ?? Date()
            
            // Get iCloud status
            let iCloudStatusResult = try await GetiCloudFileStatus.status(for: fileURL)
            
            let orphan = OrphanedFile(
                url: fileURL,
                name: fileName,
                size: size,
                createdDate: createdDate,
                fileExtension: fileExtension,
                iCloudStatus: iCloudStatusResult.status
            )
            
            orphans.append(orphan)
        }
        
        return orphans
    }
    
    private func getKnownVideoFiles(from context: NSManagedObjectContext) -> Set<String> {
        let request = Video.fetchRequest()
        request.propertiesToFetch = ["fileName"]
        
        do {
            let videos = try context.fetch(request)
            return Set(videos.compactMap { $0.fileName })
        } catch {
            print("⚠️ ORPHAN: Failed to fetch known video files: \(error)")
            return Set()
        }
    }
    
    /// Process orphaned files based on user selection
    func processOrphanedFiles(_ files: [OrphanedFile], action: OrphanedFileAction, library: Library, context: NSManagedObjectContext) async throws {
        statusMessage = "Processing \(files.count) files..."
        
        switch action {
        case .reimport:
            try await reimportOrphanedFiles(files, into: library, context: context)
        case .delete:
            try await deleteOrphanedFiles(files)
        case .ignore:
            // Remove from orphaned list but don't touch files
            await MainActor.run {
                for file in files {
                    orphanedFiles.removeAll { $0.id == file.id }
                }
            }
        }
        
        statusMessage = ""
    }
    
    private func reimportOrphanedFiles(_ files: [OrphanedFile], into library: Library, context: NSManagedObjectContext) async throws {
        for (index, file) in files.enumerated() {
            let progress = Double(index) / Double(files.count)
            await MainActor.run {
                scanProgress = progress
                statusMessage = "Importing \(file.name)..."
            }
            
            // Create new Video entity
            guard let entityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
                throw LibraryError.corruptedDatabase
            }
            
            let video = Video(entity: entityDescription, insertInto: context)
            video.id = UUID()
            video.title = file.url.deletingPathExtension().lastPathComponent
            video.fileName = file.name
            video.videoFormat = file.fileExtension
            video.fileSize = file.size
            video.dateAdded = file.createdDate
            video.library = library
            
            // Set file path relative to library
            let relativePath = file.url.path.replacingOccurrences(
                of: library.url?.path ?? "",
                with: ""
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            video.relativePath = relativePath
            
            print("📹 ORPHAN: Re-importing \(file.name) as \(video.title ?? "unknown")")
        }
        
        try context.save()
        
        // Remove from orphaned list
        await MainActor.run {
            for file in files {
                orphanedFiles.removeAll { $0.id == file.id }
            }
        }
        
        print("✅ ORPHAN: Successfully re-imported \(files.count) orphaned files")
    }
    
    private func deleteOrphanedFiles(_ files: [OrphanedFile]) async throws {
        for (index, file) in files.enumerated() {
            let progress = Double(index) / Double(files.count)
            await MainActor.run {
                scanProgress = progress
                statusMessage = "Deleting \(file.name)..."
            }
            
            do {
                // Move to trash instead of permanent deletion for safety
                try fileManager.trashItem(at: file.url, resultingItemURL: nil)
                print("🗑️ ORPHAN: Moved \(file.name) to trash")
            } catch {
                print("❌ ORPHAN: Failed to delete \(file.name): \(error)")
                throw error
            }
        }
        
        // Remove from orphaned list
        await MainActor.run {
            for file in files {
                orphanedFiles.removeAll { $0.id == file.id }
            }
        }
        
        print("✅ ORPHAN: Successfully deleted \(files.count) orphaned files")
    }
    
    /// Quick scan to get count without full details
    func getOrphanedFileCount(library: Library, context: NSManagedObjectContext) async -> Int {
        guard let libraryURL = library.url else { return 0 }
        
        let videosDirectory = libraryURL.appendingPathComponent("Videos")
        guard fileManager.fileExists(atPath: videosDirectory.path) else { return 0 }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let knownFiles = getKnownVideoFiles(from: context)
            let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm", "flv"])
            
            return contents.filter { url in
                let fileName = url.lastPathComponent
                let fileExtension = url.pathExtension.lowercased()
                return videoExtensions.contains(fileExtension) && !knownFiles.contains(fileName)
            }.count
        } catch {
            return 0
        }
    }
}