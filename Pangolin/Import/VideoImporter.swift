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
                
                // Add video to appropriate playlist based on its original folder path
                assignVideoToPlaylist(video: video, originalPath: fileURL, createdPlaylists: createdPlaylists)
                
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
    
    // MARK: - Folder Structure Analysis
    
    struct FolderNode {
        let url: URL
        let name: String
        var children: [FolderNode] = []
        var videoFiles: [URL] = []
        let isRoot: Bool
        
        init(url: URL, name: String, isRoot: Bool = false) {
            self.url = url
            self.name = name
            self.isRoot = isRoot
        }
    }
    
    private func analyzeFolderStructure(from urls: [URL]) -> [FolderNode] {
        var rootNodes: [FolderNode] = []
        
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // This is a folder import
                    let folderNode = buildFolderTree(from: url)
                    rootNodes.append(folderNode)
                } else if isVideoFile(url) {
                    // Individual file import - no playlist needed
                    continue
                }
            }
        }
        
        return rootNodes
    }
    
    private func buildFolderTree(from folderURL: URL) -> FolderNode {
        let folderName = folderURL.lastPathComponent
        var node = FolderNode(url: folderURL, name: folderName, isRoot: true)
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            
            for item in contents {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // Subfolder - recursively build tree
                        let childNode = buildFolderTree(from: item)
                        if !childNode.videoFiles.isEmpty || !childNode.children.isEmpty {
                            node.children.append(childNode)
                        }
                    } else if isVideoFile(item) {
                        // Video file
                        node.videoFiles.append(item)
                    }
                }
            }
        } catch {
            print("Error reading folder contents: \(error)")
        }
        
        return node
    }
    
    private func createPlaylistsFromStructure(_ folderNodes: [FolderNode], library: Library, context: NSManagedObjectContext) async -> [String: Playlist] {
        var createdPlaylists: [String: Playlist] = [:]
        
        for folderNode in folderNodes {
            if let playlist = await createPlaylistFromNode(folderNode, parent: nil, library: library, context: context) {
                createdPlaylists[folderNode.url.path] = playlist
                await addChildPlaylists(for: folderNode, parentPlaylist: playlist, library: library, context: context, createdPlaylists: &createdPlaylists)
            }
        }
        
        return createdPlaylists
    }
    
    private func createPlaylistFromNode(_ node: FolderNode, parent: Playlist?, library: Library, context: NSManagedObjectContext) async -> Playlist? {
        // Only create playlist if there are videos in this folder or subfolders
        guard !node.videoFiles.isEmpty || !node.children.isEmpty else { 
            return nil 
        }
        
        guard let playlistEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Playlist"] else {
            print("Could not find Playlist entity description")
            return nil
        }
        
        let playlist = Playlist(entity: playlistEntityDescription, insertInto: context)
        playlist.id = UUID()
        playlist.name = node.name
        playlist.type = PlaylistType.user.rawValue
        playlist.dateCreated = Date()
        playlist.dateModified = Date()
        playlist.library = library
        playlist.parentPlaylist = parent
        playlist.sortOrder = 0
        
        return playlist
    }
    
    private func addChildPlaylists(for node: FolderNode, parentPlaylist: Playlist, library: Library, context: NSManagedObjectContext, createdPlaylists: inout [String: Playlist]) async {
        for childNode in node.children {
            if let childPlaylist = await createPlaylistFromNode(childNode, parent: parentPlaylist, library: library, context: context) {
                createdPlaylists[childNode.url.path] = childPlaylist
                await addChildPlaylists(for: childNode, parentPlaylist: childPlaylist, library: library, context: context, createdPlaylists: &createdPlaylists)
            }
        }
    }
    
    private func assignVideoToPlaylist(video: Video, originalPath: URL, createdPlaylists: [String: Playlist]) {
        // Find the playlist that corresponds to the video's original folder
        let videoDirectory = originalPath.deletingLastPathComponent()
        
        // Look for a playlist that matches this directory or any parent directory
        for (playlistPath, playlist) in createdPlaylists {
            let playlistURL = URL(fileURLWithPath: playlistPath)
            
            // Check if the video's directory is the same as or a subdirectory of the playlist's directory
            if videoDirectory.path.hasPrefix(playlistURL.path) {
                // Add video to this playlist using mutable set
                let mutableVideos = playlist.mutableSetValue(forKey: "videos")
                mutableVideos.add(video)
                break
            }
        }
    }
}