//
//  VideoFileManager.swift
//  Pangolin
//
//  Handles video file access, iCloud downloads, and missing storage scenarios
//

import Foundation
import Combine
import AppKit

@MainActor
class VideoFileManager: ObservableObject {
    static let shared = VideoFileManager()
    
    @Published var downloadingVideos: Set<UUID> = []
    @Published var unavailableStorage: Set<String> = []
    @Published var downloadProgress: [UUID: Double] = [:]
    
    private let fileManager = FileManager.default
    private var downloadObservers: [UUID: Any] = [:]
    
    private init() {
        setupStorageMonitoring()
    }
    
    // MARK: - Video File Access
    
    /// Get video file URL and handle iCloud download if needed
    func getVideoFileURL(for video: Video, downloadIfNeeded: Bool = true) async throws -> URL {
        print("📁 VideoFileManager: Getting URL for video '\(video.title ?? "Unknown")'")
        print("📁 VideoFileManager: Video relativePath: '\(video.relativePath ?? "nil")'")
        print("📁 VideoFileManager: Library path: '\(video.library?.libraryPath ?? "nil")'")
        
        guard let fileURL = video.fileURL else {
            print("📁 VideoFileManager: Failed to get fileURL from video")
            throw VideoFileError.invalidVideoPath
        }
        
        print("📁 VideoFileManager: Computed fileURL: \(fileURL)")
        print("📁 VideoFileManager: File exists check: \(fileManager.fileExists(atPath: fileURL.path))")
        
        // Debug: Check what files actually exist in the Videos directory
        let videosDir = fileURL.deletingLastPathComponent()
        print("📁 VideoFileManager: Videos directory: \(videosDir)")
        if fileManager.fileExists(atPath: videosDir.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil)
                print("📁 VideoFileManager: Contents of Videos directory:")
                for file in contents {
                    print("   - \(file.lastPathComponent)")
                }
            } catch {
                print("📁 VideoFileManager: Failed to list Videos directory: \(error)")
            }
        } else {
            print("📁 VideoFileManager: Videos directory doesn't exist")
            
            // Check parent directories
            let libraryDir = videosDir.deletingLastPathComponent()
            print("📁 VideoFileManager: Library directory: \(libraryDir)")
            if fileManager.fileExists(atPath: libraryDir.path) {
                do {
                    let contents = try fileManager.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)
                    print("📁 VideoFileManager: Contents of Library directory:")
                    for file in contents {
                        print("   - \(file.lastPathComponent)")
                    }
                } catch {
                    print("📁 VideoFileManager: Failed to list Library directory: \(error)")
                }
            }
        }
        
        // Check if file exists locally
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        
        // Check if it's an iCloud file that needs downloading
        let isiCloudFile = await isFileiCloudButNotDownloaded(fileURL)
        print("📁 VideoFileManager: Is iCloud file: \(isiCloudFile)")
        
        if isiCloudFile {
            if downloadIfNeeded {
                print("📁 VideoFileManager: Attempting to download iCloud file")
                return try await downloadiCloudFile(fileURL, for: video)
            } else {
                print("📁 VideoFileManager: iCloud file not downloaded and download not requested")
                throw VideoFileError.iCloudFileNotDownloaded(fileURL)
            }
        }
        
        // Check if storage location is unavailable
        print("📁 VideoFileManager: Checking storage availability")
        try checkStorageAvailability(for: video)
        
        print("📁 VideoFileManager: File not found and not iCloud file")
        throw VideoFileError.fileNotFound(fileURL)
    }
    
    /// Check if video file is accessible without downloading
    func isVideoFileAccessible(_ video: Video) async -> VideoFileStatus {
        guard let fileURL = video.fileURL else {
            return .invalid
        }
        
        // Check if file exists locally
        if fileManager.fileExists(atPath: fileURL.path) {
            return .available
        }
        
        // Check if it's in iCloud but not downloaded
        if await isFileiCloudButNotDownloaded(fileURL) {
            return .iCloudNotDownloaded
        }
        
        // Check if storage location exists
        do {
            try checkStorageAvailability(for: video)
            return .storageUnavailable
        } catch VideoFileError.storageLocationUnavailable(_) {
            return .storageUnavailable
        } catch {
            return .notFound
        }
    }
    
    // MARK: - iCloud File Handling
    
    private func isFileiCloudButNotDownloaded(_ fileURL: URL) async -> Bool {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey
            ])
            
            guard let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus else {
                return false
            }
            
            return downloadStatus != .current
        } catch {
            print("Failed to check iCloud status for \(fileURL): \(error)")
            return false
        }
    }
    
    private func downloadiCloudFile(_ fileURL: URL, for video: Video) async throws -> URL {
        guard let videoId = video.id else {
            throw VideoFileError.invalidVideoPath
        }
        
        // Add to downloading set
        downloadingVideos.insert(videoId)
        downloadProgress[videoId] = 0.0
        
        defer {
            downloadingVideos.remove(videoId)
            downloadProgress.removeValue(forKey: videoId)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            do {
                // Start downloading from iCloud
                try fileManager.startDownloadingUbiquitousItem(at: fileURL)
                
                // Monitor download progress
                let observer = startDownloadProgressMonitoring(for: fileURL, videoId: videoId) { result in
                    continuation.resume(with: result)
                }
                
                downloadObservers[videoId] = observer
                
            } catch {
                continuation.resume(throwing: VideoFileError.iCloudDownloadFailed(error))
            }
        }
    }
    
    private func startDownloadProgressMonitoring(
        for fileURL: URL,
        videoId: UUID,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> Any {
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [
                        .ubiquitousItemDownloadingStatusKey,
                        .ubiquitousItemDownloadingErrorKey,
                        .ubiquitousItemDownloadRequestedKey
                    ])
                    
                    // Check for download error
                    if let error = resourceValues.ubiquitousItemDownloadingError {
                        timer.invalidate()
                        self.downloadObservers.removeValue(forKey: videoId)
                        completion(.failure(VideoFileError.iCloudDownloadFailed(error)))
                        return
                    }
                    
                    // Check download status
                    if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                        switch downloadStatus {
                        case .current:
                            // Download complete
                            timer.invalidate()
                            self.downloadObservers.removeValue(forKey: videoId)
                            self.downloadProgress[videoId] = 1.0
                            completion(.success(fileURL))
                            
                        case .downloaded:
                            // File is downloaded but may not be current
                            self.downloadProgress[videoId] = 0.9
                            
                        case .notDownloaded:
                            // Still downloading
                            self.downloadProgress[videoId] = 0.1
                            
                        default:
                            self.downloadProgress[videoId] = 0.5
                        }
                    }
                    
                } catch {
                    timer.invalidate()
                    self.downloadObservers.removeValue(forKey: videoId)
                    completion(.failure(error))
                }
            }
        }
        
        return timer
    }
    
    // MARK: - Storage Availability Checking
    
    private func checkStorageAvailability(for video: Video) throws {
        guard let library = video.library,
              let storageType = library.videoStorageType else {
            throw VideoFileError.invalidVideoPath
        }
        
        let videoStorageType = VideoStorageType(rawValue: storageType) ?? .iCloudDrive
        
        switch videoStorageType {
        case .iCloudDrive:
            if fileManager.url(forUbiquityContainerIdentifier: nil) == nil {
                throw VideoFileError.storageLocationUnavailable("iCloud Drive")
            }
            
        case .externalDrive, .customPath:
            guard let customPath = library.customVideoStoragePath else {
                throw VideoFileError.storageLocationUnavailable("Custom location not configured")
            }
            
            let customURL = URL(fileURLWithPath: customPath)
            if !fileManager.fileExists(atPath: customURL.path) {
                unavailableStorage.insert(customPath)
                throw VideoFileError.storageLocationUnavailable(customPath)
            }
            
        case .dropbox:
            let dropboxPath = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Dropbox")
            if !fileManager.fileExists(atPath: dropboxPath.path) {
                unavailableStorage.insert("Dropbox")
                throw VideoFileError.storageLocationUnavailable("Dropbox")
            }
            
        case .googleDrive:
            let googleDrivePath = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Google Drive")
            if !fileManager.fileExists(atPath: googleDrivePath.path) {
                unavailableStorage.insert("Google Drive")
                throw VideoFileError.storageLocationUnavailable("Google Drive")
            }
            
        case .oneDrive:
            let oneDrivePath = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("OneDrive")
            if !fileManager.fileExists(atPath: oneDrivePath.path) {
                unavailableStorage.insert("OneDrive")
                throw VideoFileError.storageLocationUnavailable("OneDrive")
            }
            
        case .localLibrary:
            // Local library should always be available if library exists
            break
        }
    }
    
    // MARK: - Storage Monitoring
    
    private func setupStorageMonitoring() {
        // Monitor for external drive connections/disconnections
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleStorageChange(notification)
        }
        
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleStorageChange(notification)
        }
    }
    
    private func handleStorageChange(_ notification: Notification) {
        // Refresh storage availability status
        Task { @MainActor in
            // Clear unavailable storage cache
            unavailableStorage.removeAll()
            
            // Notify observers that storage availability may have changed
            NotificationCenter.default.post(
                name: .videoStorageAvailabilityChanged,
                object: nil
            )
        }
    }
    
    // MARK: - Utility Methods
    
    /// Force download all videos in a library
    func downloadAllVideos(in library: Library) async {
        // Get all videos in library
        // This would need to be implemented with a fetch request
        // For now, placeholder
    }
    
    /// Cancel download for a specific video
    func cancelDownload(for video: Video) {
        guard let videoId = video.id else { return }
        
        if let observer = downloadObservers[videoId] {
            if let timer = observer as? Timer {
                timer.invalidate()
            }
            downloadObservers.removeValue(forKey: videoId)
        }
        
        downloadingVideos.remove(videoId)
        downloadProgress.removeValue(forKey: videoId)
    }
}

// MARK: - Video File Status

enum VideoFileStatus {
    case available
    case iCloudNotDownloaded
    case storageUnavailable
    case notFound
    case invalid
    
    var displayName: String {
        switch self {
        case .available: return "Available"
        case .iCloudNotDownloaded: return "In iCloud"
        case .storageUnavailable: return "Storage Unavailable"
        case .notFound: return "Not Found"
        case .invalid: return "Invalid Path"
        }
    }
    
    var systemImage: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .iCloudNotDownloaded: return "icloud.and.arrow.down"
        case .storageUnavailable: return "externaldrive.badge.exclamationmark"
        case .notFound: return "questionmark.circle"
        case .invalid: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Video File Errors

enum VideoFileError: LocalizedError {
    case invalidVideoPath
    case fileNotFound(URL)
    case iCloudFileNotDownloaded(URL)
    case iCloudDownloadFailed(Error)
    case storageLocationUnavailable(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidVideoPath:
            return "Invalid video file path"
        case .fileNotFound(let url):
            return "Video file not found at \(url.lastPathComponent)"
        case .iCloudFileNotDownloaded(let url):
            return "Video file \(url.lastPathComponent) is in iCloud but not downloaded"
        case .iCloudDownloadFailed(let error):
            return "Failed to download from iCloud: \(error.localizedDescription)"
        case .storageLocationUnavailable(let location):
            return "Storage location '\(location)' is not available"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .iCloudFileNotDownloaded:
            return "The video will be downloaded automatically when you try to play it"
        case .iCloudDownloadFailed:
            return "Check your internet connection and iCloud settings"
        case .storageLocationUnavailable(let location):
            if location.contains("Drive") {
                return "Connect the external drive or select a different storage location"
            } else {
                return "Make sure the storage location is accessible"
            }
        default:
            return nil
        }
    }
}

// MARK: - Video Storage Type

enum VideoStorageType: String, CaseIterable, Codable {
    case iCloudDrive = "icloud_drive"
    case localLibrary = "local_library"
    case externalDrive = "external_drive"
    case customPath = "custom_path"
    case dropbox = "dropbox"
    case googleDrive = "google_drive"
    case oneDrive = "onedrive"
    
    var displayName: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .localLibrary: return "Local Library Package"
        case .externalDrive: return "External Drive"
        case .customPath: return "Custom Location"
        case .dropbox: return "Dropbox Folder"
        case .googleDrive: return "Google Drive Folder"
        case .oneDrive: return "OneDrive Folder"
        }
    }
    
    var requiresCustomPath: Bool {
        switch self {
        case .externalDrive, .customPath, .dropbox, .googleDrive, .oneDrive:
            return true
        case .iCloudDrive, .localLibrary:
            return false
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let videoStorageAvailabilityChanged = Notification.Name("videoStorageAvailabilityChanged")
}