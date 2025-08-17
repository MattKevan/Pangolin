//
//  VideoImporter.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Import/VideoImporter.swift
import Foundation
import Combine
import AVFoundation
import CoreData

class VideoImporter: ObservableObject {
    @Published var isImporting = false
    @Published var currentFile = ""
    @Published var progress: Double = 0
    @Published var totalFiles = 0
    @Published var processedFiles = 0
    @Published var errors: [ImportError] = []
    @Published var importedVideos: [Video] = []
    
    private let fileSystemManager = FileSystemManager.shared
    private let subtitleMatcher = SubtitleMatcher()
    private var cancellables = Set<AnyCancellable>()
    
    struct ImportError: Identifiable {
        let id = UUID()
        let fileName: String
        let error: Error
    }
    
    func importFiles(_ urls: [URL], to library: Library, context: NSManagedObjectContext) async {
        await MainActor.run {
            isImporting = true
            errors = []
            importedVideos = []
            progress = 0
        }
        
        // Analyze import structure to create playlists
        let folderStructure = analyzeFolderStructure(from: urls)
        let createdPlaylists = await createPlaylistsFromStructure(folderStructure, library: library, context: context)
        
        // Gather all video files
        let videoFiles = gatherVideoFiles(from: urls)
        await MainActor.run {
            totalFiles = videoFiles.count
        }
        
        // Import each file
        for (index, fileURL) in videoFiles.enumerated() {
            await MainActor.run {
                currentFile = fileURL.lastPathComponent
                processedFiles = index
                progress = Double(index) / Double(videoFiles.count)
            }
            
            do {
                // Import video
                let video = try await fileSystemManager.importVideo(
                    from: fileURL,
                    to: library,
                    context: context,
                    copyFile: library.copyFilesOnImport
                )
                
                // Find and import matching subtitles
                if library.autoMatchSubtitles {
                    let subtitles = subtitleMatcher.findMatchingSubtitles(
                        for: fileURL,
                        in: fileURL.deletingLastPathComponent()
                    )
                    
                    for subtitleURL in subtitles {
                        _ = try? await importSubtitle(
                            from: subtitleURL,
                            for: video,
                            to: library,
                            context: context
                        )
                    }
                }
                
                await MainActor.run {
                    importedVideos.append(video)
                }
                
            } catch {
                await MainActor.run {
                    errors.append(ImportError(
                        fileName: fileURL.lastPathComponent,
                        error: error
                    ))
                }
            }
        }
        
        // Save context
        do {
            try context.save()
        } catch {
            await MainActor.run {
                errors.append(ImportError(
                    fileName: "Core Data",
                    error: error
                ))
            }
        }
        
        await MainActor.run {
            isImporting = false
            progress = 1.0
            processedFiles = totalFiles
        }
    }
    
    private func gatherVideoFiles(from urls: [URL]) -> [URL] {
        var videoFiles: [URL] = []
        
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Recursively find video files in directory
                    videoFiles.append(contentsOf: findVideoFiles(in: url))
                } else if isVideoFile(url) {
                    videoFiles.append(url)
                }
            }
        }
        
        return videoFiles
    }
    
    private func findVideoFiles(in directory: URL) -> [URL] {
        var videoFiles: [URL] = []
        
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if isVideoFile(fileURL) {
                    videoFiles.append(fileURL)
                }
            }
        }
        
        return videoFiles
    }
    
    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = VideoFormat.supportedExtensions
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func importSubtitle(from url: URL, for video: Video, to library: Library, context: NSManagedObjectContext) async throws -> Subtitle {
        guard let libraryURL = library.url else {
            throw FileSystemError.invalidLibraryPath
        }
        
        // Create subtitle directory
        let videoDir = URL(fileURLWithPath: video.relativePath).deletingLastPathComponent().path
        let subtitlesDir = libraryURL.appendingPathComponent("Subtitles")
            .appendingPathComponent(videoDir)
        
        try FileManager.default.createDirectory(
            at: subtitlesDir,
            withIntermediateDirectories: true
        )
        
        // Copy subtitle file
        let destinationURL = subtitlesDir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destinationURL)
        
        // Create subtitle entity in Core Data context using entity description
        guard let subtitleEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Subtitle"] else {
            throw FileSystemError.importFailed("Could not find Subtitle entity description")
        }
        
        let subtitle = Subtitle(entity: subtitleEntityDescription, insertInto: context)
        subtitle.id = UUID()
        subtitle.fileName = url.lastPathComponent
        subtitle.relativePath = destinationURL.path
            .replacingOccurrences(of: libraryURL.path + "/Subtitles/", with: "")
        subtitle.format = url.pathExtension
        subtitle.encoding = "UTF-8"
        subtitle.isDefault = false
        subtitle.isForced = false
        subtitle.video = video
        
        // Detect language from filename
        let languageInfo = subtitleMatcher.detectLanguage(from: url.lastPathComponent)
        subtitle.language = languageInfo.code
        subtitle.languageName = languageInfo.name
        
        return subtitle
    }
}