import os
//
//  FileSystemManager.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import Foundation
import CoreData
import AVFoundation

final class FileSystemManager: Sendable {
    static let shared = FileSystemManager()
    
    private let fileManager = FileManager.default
    
    private init() {}

    // MARK: - Video File Operations
    
    func importVideo(from sourceURL: URL, to library: Library, context: NSManagedObjectContext, copyFile: Bool = true) async throws -> Video {
        guard let libraryURL = library.url else { throw FileSystemError.invalidLibraryPath }
        let preparedImport = try await prepareVideoImport(
            from: sourceURL,
            libraryURL: libraryURL,
            copyFile: copyFile
        )
        return try makeVideo(from: preparedImport, library: library, context: context)
    }

    func prepareVideoImport(
        from sourceURL: URL,
        libraryURL: URL,
        copyFile: Bool
    ) async throws -> PreparedVideoImport {
        // Validate video file
        guard isVideoFile(sourceURL) else {
            throw FileSystemError.unsupportedFileType(sourceURL.pathExtension)
        }
        
        // Start accessing security-scoped resources for both source and destination
        let sourceAccessing = sourceURL.startAccessingSecurityScopedResource()
        let libraryAccessing = libraryURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            if libraryAccessing {
                libraryURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Use Videos directory inside the library package
        let videoStorageURL = libraryURL.appendingPathComponent("Videos")
        
        // Create date-based subdirectory
        let importDate = Date()
        let dateString = importDate.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let videosDir = videoStorageURL.appendingPathComponent(dateString)
        
        // Ensure directory exists
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        
        // Determine destination URL
        let fileName = sourceURL.lastPathComponent
        var destinationURL = videosDir.appendingPathComponent(fileName)
        
        // Handle duplicates
        destinationURL = try uniqueURL(for: destinationURL)
        
        // Diagnostic logging
        Logger.files.info("FS: sourceURL: \(sourceURL.path)")
        Logger.files.info("FS: destinationURL: \(destinationURL.path)")
        Logger.files.info("FS: destDir exists: \(self.fileManager.fileExists(atPath: videosDir.path))")
        if let attrs = try? fileManager.attributesOfItem(atPath: videosDir.path) {
            Logger.files.info("FS: destDir permissions: \(String(describing: attrs[.posixPermissions] ?? "unknown"))")
        }
        Logger.files.info("FS: source exists: \(self.fileManager.fileExists(atPath: sourceURL.path))")
        Logger.files.info("FS: source isReadable: \(self.fileManager.isReadableFile(atPath: sourceURL.path))")
        
        // Copy or move file
        if copyFile {
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                let nsError = error as NSError
                Logger.files.error("FS: copyItem failed — domain: \(nsError.domain), code: \(nsError.code)")
                Logger.files.error("FS: underlying error: \(String(describing: nsError.userInfo[NSUnderlyingErrorKey] ?? "none"))")
                throw error
            }
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
        
        // Get relative path
        let relativePath = destinationURL.path.replacingOccurrences(of: videoStorageURL.path + "/", with: "")
        
        // Get video metadata
        let metadata = try await getVideoMetadata(from: destinationURL)

        return PreparedVideoImport(
            sourcePath: ImportDuplicatePolicy.canonicalSourcePath(sourceURL),
            fileName: fileName,
            relativePath: relativePath,
            importDate: importDate,
            destinationURL: destinationURL,
            metadata: metadata
        )
    }

    func makeVideo(
        from preparedImport: PreparedVideoImport,
        library: Library,
        context: NSManagedObjectContext
    ) throws -> Video {
        
        // Create video entity in Core Data context using entity description
        guard let videoEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            throw FileSystemError.importFailed("Could not find Video entity description")
        }
        
        let video = Video(entity: videoEntityDescription, insertInto: context)
        video.id = UUID()
        video.title = (preparedImport.fileName as NSString).deletingPathExtension
        video.fileName = preparedImport.fileName
        video.relativePath = preparedImport.relativePath
        video.sourcePath = preparedImport.sourcePath
        video.duration = preparedImport.metadata.duration
        video.fileSize = preparedImport.metadata.fileSize
        video.dateAdded = preparedImport.importDate
        video.videoFormat = preparedImport.destinationURL.pathExtension
        video.resolution = preparedImport.metadata.resolution
        video.frameRate = preparedImport.metadata.frameRate
        video.playbackPosition = 0
        video.playCount = 0
        video.library = library
        
        return video
    }
    
    func importFolder(at folderURL: URL, to library: Library, context: NSManagedObjectContext) async throws -> [Video] {
        var importedVideos: [Video] = []
        
        let enumerator = fileManager.enumerator(at: folderURL,
                                               includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if isVideoFile(fileURL) {
                do {
                    let video = try await importVideo(from: fileURL, to: library, context: context)
                    importedVideos.append(video)
                } catch {
                    // Log error but continue importing other files
                    Logger.files.info("Failed to import \(fileURL): \(error)")
                }
            }
        }
        
        return importedVideos
    }
    
    // MARK: - Subtitle Operations
    
    func findMatchingSubtitles(for videoURL: URL) -> [URL] {
        let videoName = videoURL.deletingPathExtension().lastPathComponent
        let directory = videoURL.deletingLastPathComponent()
        
        var subtitles: [URL] = []
        
        do {
            let files = try fileManager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil)
            
            for file in files {
                if isSubtitleFile(file) {
                    let subtitleName = file.deletingPathExtension().lastPathComponent
                    
                    // Check various matching patterns
                    if subtitleName == videoName ||
                       subtitleName.hasPrefix(videoName + ".") ||
                       subtitleName.hasPrefix(videoName + "_") {
                        subtitles.append(file)
                    }
                }
            }
        } catch {
            Logger.files.info("Error finding subtitles: \(error)")
        }
        
        return subtitles
    }
    
    // MARK: - Helper Methods
    
    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = VideoFormat.supportedExtensions
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func isSubtitleFile(_ url: URL) -> Bool {
        let subtitleExtensions = ["srt", "vtt", "ssa", "ass", "sub"]
        return subtitleExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func uniqueURL(for url: URL) throws -> URL {
        var uniqueURL = url
        var counter = 1
        
        while fileManager.fileExists(atPath: uniqueURL.path) {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            uniqueURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(name)_\(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        
        return uniqueURL
    }
    
    private func getVideoMetadata(from url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        
        // Get duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // Get file size
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        
        // Get video track for resolution and frame rate
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var resolution = ""
        var frameRate = 0.0
        
        if let videoTrack = tracks.first {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            if let displaySize = VideoDisplayGeometry.displaySize(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            ) {
                resolution = "\(Int(displaySize.width.rounded()))x\(Int(displaySize.height.rounded()))"
            }
            
            let rate = try await videoTrack.load(.nominalFrameRate)
            frameRate = Double(rate)
        }
        
        return VideoMetadata(
            duration: durationSeconds,
            fileSize: fileSize,
            resolution: resolution,
            frameRate: frameRate
        )
    }
    
}

// MARK: - Supporting Types

struct VideoMetadata: Sendable {
    let duration: TimeInterval
    let fileSize: Int64
    let resolution: String
    let frameRate: Double
}

struct PreparedVideoImport: Sendable {
    let sourcePath: String
    let fileName: String
    let relativePath: String
    let importDate: Date
    let destinationURL: URL
    let metadata: VideoMetadata
}

enum FileSystemError: LocalizedError {
    case invalidLibraryPath
    case unsupportedFileType(String)
    case importFailed(String)
    case fileNotFound
    case insufficientSpace
    case accessDenied
    
    var errorDescription: String? {
        switch self {
        case .invalidLibraryPath:
            return "Invalid library path"
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext)"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        case .fileNotFound:
            return "File not found"
        case .insufficientSpace:
            return "Insufficient disk space"
        case .accessDenied:
            return "Access denied to file or folder"
        }
    }
}
