//
//  FileSystemManager.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import Foundation
import CoreData
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

class FileSystemManager {
    static let shared = FileSystemManager()
    
    private let fileManager = FileManager.default
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    private init() {}

    static func mediaRelativePath(for videoURL: URL, libraryURL: URL, cloudRootURL: URL?) -> String {
        let localVideosRoot = libraryURL.appendingPathComponent("Videos", isDirectory: true)
        let localPrefix = localVideosRoot.path + "/"
        if videoURL.path.hasPrefix(localPrefix) {
            return String(videoURL.path.dropFirst(localPrefix.count))
        }

        if let cloudRootURL {
            let cloudVideosRoot = cloudRootURL.appendingPathComponent("Media/Videos", isDirectory: true)
            let cloudPrefix = cloudVideosRoot.path + "/"
            if videoURL.path.hasPrefix(cloudPrefix) {
                return String(videoURL.path.dropFirst(cloudPrefix.count))
            }
        }

        return videoURL.lastPathComponent
    }
    
    // MARK: - Video File Operations
    
    func importVideo(from sourceURL: URL, to library: Library, context: NSManagedObjectContext, copyFile: Bool = true) async throws -> Video {
        guard let libraryURL = library.url else {
            throw FileSystemError.invalidLibraryPath
        }
        
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
        guard let libraryURL = library.url else {
            throw FileSystemError.invalidLibraryPath
        }
        let videoStorageURL = libraryURL.appendingPathComponent("Videos")
        
        // Create date-based subdirectory
        let importDate = Date()
        let dateString = dateFormatter.string(from: importDate)
        let videosDir = videoStorageURL.appendingPathComponent(dateString)
        
        // Ensure directory exists
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        
        // Determine destination URL
        let fileName = sourceURL.lastPathComponent
        var destinationURL = videosDir.appendingPathComponent(fileName)
        
        // Handle duplicates
        destinationURL = try uniqueURL(for: destinationURL)
        
        // Diagnostic logging
        print("📁 FS: sourceURL: \(sourceURL.path)")
        print("📁 FS: destinationURL: \(destinationURL.path)")
        print("📁 FS: destDir exists: \(fileManager.fileExists(atPath: videosDir.path))")
        if let attrs = try? fileManager.attributesOfItem(atPath: videosDir.path) {
            print("📁 FS: destDir permissions: \(attrs[.posixPermissions] ?? "unknown")")
        }
        print("📁 FS: source exists: \(fileManager.fileExists(atPath: sourceURL.path))")
        print("📁 FS: source isReadable: \(fileManager.isReadableFile(atPath: sourceURL.path))")
        
        // Copy or move file
        if copyFile {
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                let nsError = error as NSError
                print("❌ FS: copyItem failed — domain: \(nsError.domain), code: \(nsError.code)")
                print("❌ FS: underlying error: \(nsError.userInfo[NSUnderlyingErrorKey] ?? "none")")
                throw error
            }
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
        
        // Get relative path
        let relativePath = destinationURL.path.replacingOccurrences(of: videoStorageURL.path + "/", with: "")
        
        // Get video metadata
        let metadata = try await getVideoMetadata(from: destinationURL)
        
        // Generate thumbnail
        let thumbnailPath = try await generateThumbnail(for: destinationURL, in: library)
        
        // Create video entity in Core Data context using entity description
        guard let videoEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            throw FileSystemError.importFailed("Could not find Video entity description")
        }
        
        let video = Video(entity: videoEntityDescription, insertInto: context)
        video.id = UUID()
        video.title = sourceURL.deletingPathExtension().lastPathComponent
        video.fileName = fileName
        video.relativePath = relativePath
        video.duration = metadata.duration
        video.fileSize = metadata.fileSize
        video.dateAdded = importDate
        video.videoFormat = sourceURL.pathExtension
        video.resolution = metadata.resolution
        video.frameRate = metadata.frameRate
        video.playbackPosition = 0
        video.playCount = 0
        video.thumbnailPath = thumbnailPath
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
                    print("Failed to import \(fileURL): \(error)")
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
            print("Error finding subtitles: \(error)")
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
            let size = try await videoTrack.load(.naturalSize)
            resolution = "\(Int(size.width))x\(Int(size.height))"
            
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
    
    // MARK: - Thumbnail Generation
    
    func generateThumbnail(for videoURL: URL, in library: Library) async throws -> String? {
        guard let libraryURL = library.url else {
            throw FileSystemError.invalidLibraryPath
        }
        
        let asset = AVURLAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 1280, height: 720)
        
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let thumbnailTime = CMTime(seconds: min(durationSeconds * 0.1, 5.0), preferredTimescale: 600)
        
        do {
            let cgImage = try await imageGenerator.image(at: thumbnailTime).image

            let ubiquitousRoot = fileManager.url(forUbiquityContainerIdentifier: cloudContainerIdentifier)
            let videoRelativePath = Self.mediaRelativePath(
                for: videoURL,
                libraryURL: libraryURL,
                cloudRootURL: ubiquitousRoot
            )
            let thumbnailRelativePath = URL(fileURLWithPath: videoRelativePath).deletingPathExtension().lastPathComponent + ".jpg"
            let thumbnailSubDir = URL(fileURLWithPath: videoRelativePath).deletingLastPathComponent().path

            if let cloudRoot = ubiquitousRoot {
                let cloudDir: URL
                if thumbnailSubDir.isEmpty || thumbnailSubDir == "." {
                    cloudDir = cloudRoot.appendingPathComponent("Thumbnails")
                } else {
                    cloudDir = cloudRoot.appendingPathComponent("Thumbnails").appendingPathComponent(thumbnailSubDir)
                }
                try fileManager.createDirectory(at: cloudDir, withIntermediateDirectories: true)
                let cloudURL = cloudDir.appendingPathComponent(thumbnailRelativePath)
                try writeJPEG(cgImage: cgImage, to: cloudURL)
                return thumbnailSubDir.isEmpty || thumbnailSubDir == "." ? thumbnailRelativePath : "\(thumbnailSubDir)/\(thumbnailRelativePath)"
            }
            
            let localDir = libraryURL.appendingPathComponent("Thumbnails").appendingPathComponent(thumbnailSubDir)
            try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
            let localURL = localDir.appendingPathComponent(thumbnailRelativePath)
            try writeJPEG(cgImage: cgImage, to: localURL)
            return localURL.path.replacingOccurrences(of: libraryURL.path + "/Thumbnails/", with: "")
            
        } catch {
            print("Failed to generate thumbnail for \(videoURL.lastPathComponent): \(error)")
            return nil
        }
    }

    private func writeJPEG(cgImage: CGImage, to url: URL) throws {
        #if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw FileSystemError.importFailed("Could not create JPEG data")
        }
        try jpegData.write(to: url)
        #else
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
            throw FileSystemError.importFailed("Could not create JPEG data")
        }
        try jpegData.write(to: url)
        #endif
    }

    func generateThumbnail(for video: Video, in library: Library) async throws -> String? {
        let videoURL = try await video.getAccessibleFileURL(downloadIfNeeded: true)
        return try await generateThumbnail(for: videoURL, in: library)
    }
    
    // MARK: - Thumbnail Generation for Existing Videos
    
    func generateMissingThumbnails(for library: Library, context: NSManagedObjectContext) async {
        guard library.url != nil else { return }
        
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND thumbnailPath == nil", library)
        
        do {
            let videosWithoutThumbnails = try context.fetch(request)
            let videoCount = videosWithoutThumbnails.count
            print("Found \(videoCount) videos without thumbnails")
            
            for video in videosWithoutThumbnails {
                do {
                    let thumbnailPath = try await generateThumbnail(for: video, in: library)
                    video.thumbnailPath = thumbnailPath
                } catch {
                    print("Failed to generate thumbnail for \(video.fileName ?? "Unknown Video"): \(error)")
                }
            }
            
            do {
                try context.save()
                print("Successfully saved thumbnails for \(videoCount) videos")
            } catch {
                print("Failed to save thumbnail paths: \(error)")
            }
            
        } catch {
            print("Failed to fetch videos without thumbnails: \(error)")
        }
    }
    
    func rebuildAllThumbnails(for library: Library, context: NSManagedObjectContext) async {
        guard library.url != nil else { return }
        
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        
        do {
            let allVideos = try context.fetch(request)
            let videoCount = allVideos.count
            print("Rebuilding thumbnails for \(videoCount) videos")
            
            for video in allVideos {
                do {
                    let thumbnailPath = try await generateThumbnail(for: video, in: library)
                    video.thumbnailPath = thumbnailPath
                } catch {
                    print("Failed to rebuild thumbnail for \(video.fileName ?? "Unknown Video"): \(error)")
                }
            }
            
            do {
                try context.save()
                print("Successfully rebuilt thumbnails for \(videoCount) videos")
            } catch {
                print("Failed to save rebuilt thumbnail paths: \(error)")
            }
        } catch {
            print("Failed to fetch videos for thumbnail rebuild: \(error)")
        }
    }
}

// MARK: - Supporting Types

struct VideoMetadata {
    let duration: TimeInterval
    let fileSize: Int64
    let resolution: String
    let frameRate: Double
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
