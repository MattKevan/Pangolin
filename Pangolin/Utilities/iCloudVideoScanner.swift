//
//  iCloudVideoScanner.swift
//  Pangolin
//
//  Utility for scanning iCloud directory for existing video files
//  and importing them into a fresh library after database reset
//

import Foundation
import AVFoundation
import CoreData

@MainActor
class iCloudVideoScanner: ObservableObject {
    static let shared = iCloudVideoScanner()
    
    @Published var isScanning = false
    @Published var foundVideos: [URL] = []
    @Published var scanProgress: Double = 0.0
    @Published var scanStatusMessage = ""
    
    private let fileManager = FileManager.default
    private let supportedVideoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm"]
    
    private init() {}
    
    /// Scan iCloud directory for video files and import them into the library
    func scanAndImportVideos(into library: Library, context: NSManagedObjectContext) async throws {
        print("📹 VIDEO SCANNER: Starting iCloud video scan...")
        isScanning = true
        scanProgress = 0.0
        foundVideos = []
        scanStatusMessage = "Scanning iCloud for video files..."
        
        defer {
            isScanning = false
            scanStatusMessage = ""
        }
        
        // Get iCloud directory
        guard let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            throw ScanError.iCloudUnavailable
        }
        
        let pangolinDirectory = iCloudURL.appendingPathComponent("Pangolin")
        let videosDirectory = pangolinDirectory.appendingPathComponent("Videos")
        
        // Check if videos directory exists
        guard fileManager.fileExists(atPath: videosDirectory.path) else {
            print("📹 VIDEO SCANNER: No videos directory found in iCloud")
            scanStatusMessage = "No existing video library found"
            return
        }
        
        // Recursively scan for video files
        let videoFiles = try await scanForVideoFiles(in: videosDirectory)
        foundVideos = videoFiles
        
        if videoFiles.isEmpty {
            print("📹 VIDEO SCANNER: No video files found")
            scanStatusMessage = "No video files found"
            return
        }
        
        print("📹 VIDEO SCANNER: Found \(videoFiles.count) video files, starting import...")
        scanStatusMessage = "Found \(videoFiles.count) videos, importing..."
        
        // Import each video file
        let totalVideos = Double(videoFiles.count)
        for (index, videoURL) in videoFiles.enumerated() {
            scanProgress = Double(index) / totalVideos
            scanStatusMessage = "Importing \(videoURL.lastPathComponent)..."
            
            do {
                try await importVideoFile(videoURL, into: library, context: context)
                print("✅ VIDEO SCANNER: Imported \(videoURL.lastPathComponent)")
            } catch {
                print("❌ VIDEO SCANNER: Failed to import \(videoURL.lastPathComponent): \(error)")
                // Continue with other files even if one fails
            }
        }
        
        scanProgress = 1.0
        scanStatusMessage = "Import complete - \(videoFiles.count) videos restored"
        print("✅ VIDEO SCANNER: Import complete")
    }
    
    /// Recursively scan directory for video files
    private func scanForVideoFiles(in directory: URL) async throws -> [URL] {
        var videoFiles: [URL] = []
        
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .pathKey, .ubiquitousItemDownloadingStatusKey]
        
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.directoryEnumerationFailed
        }
        
        while let url = enumerator.nextObject() as? URL {
            do {
                let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                
                // Skip directories
                if resourceValues.isDirectory == true {
                    continue
                }
                
                // Check if it's a video file
                let fileExtension = url.pathExtension.lowercased()
                if supportedVideoExtensions.contains(fileExtension) {
                    videoFiles.append(url)
                }
                
            } catch {
                print("⚠️ VIDEO SCANNER: Could not read properties for \(url): \(error)")
                continue
            }
        }
        
        return videoFiles
    }
    
    /// Import a single video file into the library
    private func importVideoFile(_ videoURL: URL, into library: Library, context: NSManagedObjectContext) async throws {
        // Ensure file is downloaded
        if !fileManager.fileExists(atPath: videoURL.path) {
            try fileManager.startDownloadingUbiquitousItem(at: videoURL)
            // Wait briefly for download to start
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // Create video entity
        let video = Video(context: context)
        video.id = UUID()
        video.fileName = videoURL.lastPathComponent
        video.videoFormat = videoURL.pathExtension
        video.relativePath = videoURL.path
        video.dateAdded = Date()
        video.library = library
        
        // Generate basic metadata
        let asset = AVAsset(url: videoURL)
        
        // Get duration
        do {
            let duration = try await asset.load(.duration)
            video.duration = CMTimeGetSeconds(duration)
        } catch {
            print("⚠️ Could not load duration for \(videoURL.lastPathComponent)")
        }
        
        // Get file size
        do {
            let resourceValues = try videoURL.resourceValues(forKeys: [.fileSizeKey])
            video.fileSize = Int64(resourceValues.fileSize ?? 0)
        } catch {
            print("⚠️ Could not get file size for \(videoURL.lastPathComponent)")
        }
        
        // Get creation date from file
        do {
            let resourceValues = try videoURL.resourceValues(forKeys: [.creationDateKey])
            // Note: Video entity doesn't have a createdAt field in the model
            // dateAdded is already set above
        } catch {
            // Ignore creation date errors
        }
        
        // Set initial processing states based on the model
        video.transcriptStatus = "pending"
        
        // Save the context
        try context.save()
        
        // Queue processing tasks for the imported video
        let processingManager = ProcessingQueueManager.shared
        processingManager.addTask(for: video, type: .transcribe)
    }
}

// MARK: - Errors

enum ScanError: LocalizedError {
    case iCloudUnavailable
    case directoryEnumerationFailed
    case importFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud Drive is not available"
        case .directoryEnumerationFailed:
            return "Failed to scan directory contents"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        }
    }
}