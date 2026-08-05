//
//  VideoImporter.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Import/VideoImporter.swift
import Foundation
import AVFoundation
import CoreData

@MainActor
class VideoImporter: ObservableObject {
    @Published var skippedFolders: [String] = []
    
    private let fileSystemManager = FileSystemManager.shared
    private let videoFileManager = VideoFileManager.shared
    private let subtitleMatcher = SubtitleMatcher()
    
    struct ImportPlan {
        let videoFiles: [URL]
        let createdFolders: [String: Folder]
    }
    
    func prepareImportPlan(
        from urls: [URL],
        library: Library,
        context: NSManagedObjectContext,
        existingRecords: [ImportedVideoRecord] = []
    ) async -> ImportPlan {
        let folderStructure = analyzeFolderStructure(from: urls)
        let allVideoFiles = videoFilesFromAnalyzedStructure(urls: urls, folderNodes: folderStructure)
        let candidates = allVideoFiles.map { url in
            ImportCandidate(url: url, fileSize: fileSize(of: url))
        }
        let videoFiles = ImportDuplicatePolicy
            .uniqueCandidates(candidates, existingRecords: existingRecords)
            .map(\.url)
        let importingPaths = Set(videoFiles.map(ImportDuplicatePolicy.canonicalSourcePath))
        let foldersForImport = folderStructure.compactMap { node in
            prunedFolderNode(node, importingPaths: importingPaths)
        }
        let createdFolders = await createFoldersFromStructure(foldersForImport, library: library, context: context)
        return ImportPlan(videoFiles: videoFiles, createdFolders: createdFolders)
    }

    func importSingleFile(
        _ fileURL: URL,
        library: Library,
        context: NSManagedObjectContext,
        createdFolders: [String: Folder],
        originalSourceURL: URL? = nil
    ) async throws -> Video {
        guard let libraryURL = library.url else { throw FileSystemError.invalidLibraryPath }
        let manager = fileSystemManager
        let copyFile = library.copyFilesOnImport
        let preparedImport = try await Task.detached(priority: .utility) {
            try await manager.prepareVideoImport(
                from: fileURL,
                libraryURL: libraryURL,
                copyFile: copyFile
            )
        }.value
        let video = try manager.makeVideo(from: preparedImport, library: library, context: context)
        if let originalSourceURL {
            video.sourcePath = ImportDuplicatePolicy.canonicalSourcePath(originalSourceURL)
        }
        print("✅ IMPORT: Successfully imported video: \(video.title ?? "Unknown")")
        
        assignVideoToFolder(video: video, originalPath: fileURL, createdFolders: createdFolders)
        
        if library.autoMatchSubtitles {
            let subtitles = subtitleMatcher.findMatchingSubtitles(
                for: fileURL,
                in: fileURL.deletingLastPathComponent()
            )
            print("📄 IMPORT: Found \(subtitles.count) subtitle files for \(fileURL.lastPathComponent)")
            
            for subtitleURL in subtitles {
                do {
                    let subtitle = try await importSubtitle(
                        from: subtitleURL,
                        for: video,
                        to: library,
                        context: context
                    )
                    print("✅ IMPORT: Successfully imported subtitle: \(subtitle.fileName ?? "Unknown")")
                } catch {
                    print("❌ IMPORT: Failed to import subtitle \(subtitleURL.lastPathComponent): \(error)")
                }
            }
        }

        // Move imported local staging file to ubiquitous iCloud media root.
        if let libraryURL = library.url,
           let relativePath = video.relativePath {
            let localStagingURL = libraryURL.appendingPathComponent("Videos").appendingPathComponent(relativePath)
            do {
                try await ThumbnailCoordinator.shared.generateNewImportThumbnail(
                    for: video,
                    sourceURL: localStagingURL
                )
            } catch {
                print("⚠️ IMPORT: Thumbnail generation deferred for \(video.title ?? video.fileName ?? "Unknown"): \(error.localizedDescription)")
            }
            do {
                try await videoFileManager.uploadImportedVideoToCloud(localURL: localStagingURL, for: video)
            } catch {
                // Roll back the imported record: persisting a Video whose staging
                // file is gone would leave an orphaned, unplayable library entry.
                context.delete(video)
                try? FileManager.default.removeItem(at: localStagingURL)
                throw error
            }
            ProcessingQueueManager.shared.enqueueThumbnails(for: [video])
        }
        
        return video
    }
    
    func resetImportState() {
        skippedFolders.removeAll()
    }
    
    func findVideoFiles(in directory: URL) -> [URL] {
        var videoFiles: [URL] = []
        
        // Start accessing security-scoped resource
        let accessing = directory.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            
            for item in contents {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // Recursively search subdirectories
                        videoFiles.append(contentsOf: findVideoFiles(in: item))
                    } else if isVideoFile(item) {
                        videoFiles.append(item)
                    }
                }
            }
        } catch {
            print("⚠️ IMPORT: Could not access directory \(directory.lastPathComponent): \(error)")
        }
        
        return videoFiles
    }
    
    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = VideoFormat.supportedExtensions
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func importSubtitle(from url: URL, for video: Video, to library: Library, context: NSManagedObjectContext) async throws -> Subtitle {
        guard let videoRelativePath = video.relativePath else {
            throw FileSystemError.invalidLibraryPath
        }
        let videoDir = (videoRelativePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        
        let ubiquitousRoot = fm.url(forUbiquityContainerIdentifier: VideoFileManager.shared.cloudContainerIdentifier)
        let targetDir: URL
        let baseURL: URL
        
        if let cloudRoot = ubiquitousRoot {
            baseURL = cloudRoot.appendingPathComponent("Subtitles")
            if videoDir.isEmpty || videoDir == "." {
                targetDir = baseURL
            } else {
                targetDir = baseURL.appendingPathComponent(videoDir)
            }
        } else {
            guard let libraryURL = library.url else {
                throw FileSystemError.invalidLibraryPath
            }
            baseURL = libraryURL.appendingPathComponent("Subtitles")
            if videoDir.isEmpty || videoDir == "." {
                targetDir = baseURL
            } else {
                targetDir = baseURL.appendingPathComponent(videoDir)
            }
        }
        
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        let fileName = url.lastPathComponent
        var destinationURL = targetDir.appendingPathComponent(fileName)
        
        var counter = 1
        while fm.fileExists(atPath: destinationURL.path) {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let newFileName = "\(name)_\(counter).\(ext)"
            destinationURL = targetDir.appendingPathComponent(newFileName)
            counter += 1
        }
        
        try fm.copyItem(at: url, to: destinationURL)
        
        let relativePath: String
        let fileNameOnly = destinationURL.lastPathComponent
        if videoDir.isEmpty || videoDir == "." {
            relativePath = fileNameOnly
        } else {
            relativePath = "\(videoDir)/\(fileNameOnly)"
        }
        
        guard let subtitleEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Subtitle"] else {
            throw FileSystemError.importFailed("Could not find Subtitle entity description")
        }
        
        let subtitle = Subtitle(entity: subtitleEntityDescription, insertInto: context)
        subtitle.id = UUID()
        subtitle.fileName = fileNameOnly
        subtitle.relativePath = relativePath
        subtitle.format = url.pathExtension
        subtitle.encoding = "UTF-8"
        subtitle.isDefault = false
        subtitle.isForced = false
        subtitle.video = video
        
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
    
    func analyzeFolderStructure(from urls: [URL]) -> [FolderNode] {
        var rootNodes: [FolderNode] = []
        
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // This is a folder import
                    let folderNode = buildFolderTree(from: url)
                    rootNodes.append(folderNode)
                } else if isVideoFile(url) {
                    // Individual file import
                    continue
                }
            }
        }
        
        return rootNodes
    }
    
    func buildFolderTree(from folderURL: URL) -> FolderNode {
        let folderName = folderURL.lastPathComponent
        var node = FolderNode(url: folderURL, name: folderName, isRoot: true)
        
        // Start accessing security-scoped resource
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        
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
                        // Project detail only supports one section level, so each immediate
                        // child folder becomes a section and deeper descendants are flattened
                        // into that section's video list.
                        let childAccessing = item.startAccessingSecurityScopedResource()
                        var childNode = FolderNode(url: item, name: item.lastPathComponent)
                        childNode.videoFiles = findVideoFiles(in: item)
                        if childAccessing {
                            item.stopAccessingSecurityScopedResource()
                        }
                        if !childNode.videoFiles.isEmpty {
                            node.children.append(childNode)
                        }
                    } else if isVideoFile(item) {
                        // Video file
                        node.videoFiles.append(item)
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 257 {
                print("⚠️ IMPORT: Permission denied for folder '\(folderName)' - may need individual selection")
                Task { @MainActor in
                    skippedFolders.append(folderName)
                }
            } else {
                print("⚠️ IMPORT: Error reading folder '\(folderName)': \(error)")
            }
        }
        
        return node
    }
    
    func createFoldersFromStructure(_ folderNodes: [FolderNode], library: Library, context: NSManagedObjectContext) async -> [String: Folder] {
        var createdFolders: [String: Folder] = [:]
        
        for folderNode in folderNodes {
            if let folder = await createFolderFromNode(folderNode, parent: nil, library: library, context: context) {
                createdFolders[folderNode.url.path] = folder
                await addChildFolders(for: folderNode, parentFolder: folder, library: library, context: context, createdFolders: &createdFolders)
            }
        }
        
        return createdFolders
    }
    
    func createFolderFromNode(_ node: FolderNode, parent: Folder?, library: Library, context: NSManagedObjectContext) async -> Folder? {
        // Only create folder if there are videos in this folder or subfolders
        guard !node.videoFiles.isEmpty || !node.children.isEmpty else { 
            return nil 
        }

        if let existingFolder = existingFolder(named: node.name, parent: parent, library: library, context: context) {
            return existingFolder
        }
        
        guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            print("Could not find Folder entity description")
            return nil
        }
        
        let folder = Folder(entity: folderEntityDescription, insertInto: context)
        folder.id = UUID()
        folder.name = node.name
        folder.projectTitle = parent == nil ? node.name : nil
        folder.projectProvider = nil
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.library = library
        folder.parentFolder = parent
        folder.isTopLevel = (parent == nil)
        
        return folder
    }
    
    func addChildFolders(for node: FolderNode, parentFolder: Folder, library: Library, context: NSManagedObjectContext, createdFolders: inout [String: Folder]) async {
        for childNode in node.children {
            if let childFolder = await createFolderFromNode(childNode, parent: parentFolder, library: library, context: context) {
                createdFolders[childNode.url.path] = childFolder
            }
        }
    }

    private func existingFolder(
        named name: String,
        parent: Folder?,
        library: Library,
        context: NSManagedObjectContext
    ) -> Folder? {
        let request = Folder.fetchRequest()
        request.fetchLimit = 1
        if let parent {
            request.predicate = NSPredicate(format: "library == %@ AND parentFolder == %@ AND name == %@", library, parent, name)
        } else {
            request.predicate = NSPredicate(format: "library == %@ AND parentFolder == nil AND name == %@", library, name)
        }
        return try? context.fetch(request).first
    }

    private func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func prunedFolderNode(
        _ node: FolderNode,
        importingPaths: Set<String>
    ) -> FolderNode? {
        var pruned = node
        pruned.videoFiles = node.videoFiles.filter { importingPaths.contains(ImportDuplicatePolicy.canonicalSourcePath($0)) }
        pruned.children = node.children.compactMap { child in
            prunedFolderNode(child, importingPaths: importingPaths)
        }
        return pruned.videoFiles.isEmpty && pruned.children.isEmpty ? nil : pruned
    }

    private func videoFilesFromAnalyzedStructure(urls: [URL], folderNodes: [FolderNode]) -> [URL] {
        var seenPaths = Set<String>()
        var result: [URL] = []

        func appendIfNeeded(_ url: URL) {
            let path = url.path
            guard !seenPaths.contains(path) else { return }
            seenPaths.insert(path)
            result.append(url)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               isVideoFile(url) {
                appendIfNeeded(url)
            }
        }

        for node in folderNodes {
            collectVideoFiles(in: node).forEach(appendIfNeeded)
        }

        return result
    }

    private func collectVideoFiles(in node: FolderNode) -> [URL] {
        var files = node.videoFiles

        for child in node.children {
            files.append(contentsOf: collectVideoFiles(in: child))
        }

        return files
    }
    
    func assignVideoToFolder(video: Video, originalPath: URL, createdFolders: [String: Folder]) {
        // Find the folder that corresponds to the video's original folder
        let videoDirectory = originalPath.deletingLastPathComponent()
        
        // Find the exact matching folder first (most specific)
        var bestMatch: Folder?
        var bestMatchPath = ""
        
        for (folderPath, folder) in createdFolders {
            let folderURL = URL(fileURLWithPath: folderPath)
            
            // Match the video's directory exactly, or a real path ancestor of it.
            // A bare `hasPrefix` would also match sibling directories (e.g. "Folder"
            // matching "Folder2"), which silently misassigns imported videos.
            let isExactMatch = videoDirectory.path == folderURL.path
            let isDescendant = videoDirectory.path.hasPrefix(folderURL.path + "/")
            if isExactMatch || isDescendant {
                // Prefer the longest matching path (most specific folder)
                if folderPath.count > bestMatchPath.count {
                    bestMatch = folder
                    bestMatchPath = folderPath
                }
            }
        }
        
        // Assign to the most specific matching folder
        if let bestMatch = bestMatch {
            video.folder = bestMatch
            print("📁 IMPORT: Assigned video '\(video.fileName ?? "Unknown")' to folder '\(bestMatch.name ?? "Unknown")'")
        } else {
            print("⚠️ IMPORT: No matching folder found for video '\(video.fileName ?? "Unknown")' at path: \(videoDirectory.path)")
        }
    }
}
