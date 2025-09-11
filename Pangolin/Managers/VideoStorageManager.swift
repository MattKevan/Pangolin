//
//  VideoStorageManager.swift
//  Pangolin
//
//  Handles flexible video storage location resolution
//

import Foundation

@MainActor
class VideoStorageManager: ObservableObject {
    static let shared = VideoStorageManager()
    
    @Published var availableStorageTypes: [VideoStorageType] = []
    
    private let fileManager = FileManager.default
    
    private init() {
        detectAvailableStorageOptions()
    }
    
    // MARK: - Storage Location Resolution
    
    func resolveVideoStorageURL(for library: Library) throws -> URL {
        guard let storageTypeString = library.videoStorageType,
              let storageType = VideoStorageType(rawValue: storageTypeString) else {
            // Default fallback to iCloud Drive
            return try iCloudVideoURL(for: library)
        }
        
        switch storageType {
        case .iCloudDrive:
            return try iCloudVideoURL(for: library)
            
        case .localLibrary:
            return try localVideoURL(for: library)
            
        case .externalDrive, .customPath:
            return try customVideoURL(for: library)
            
        case .dropbox:
            return try dropboxVideoURL(for: library)
            
        case .googleDrive:
            return try googleDriveVideoURL(for: library)
            
        case .oneDrive:
            return try oneDriveVideoURL(for: library)
        }
    }
    
    // MARK: - Storage URL Implementations
    
    private func iCloudVideoURL(for library: Library) throws -> URL {
        // For iCloud Drive storage, store videos in the library package's Videos directory
        guard let libraryURL = library.url else {
            throw VideoStorageError.invalidLibraryPath
        }
        return libraryURL.appendingPathComponent("Videos")
    }
    
    private func localVideoURL(for library: Library) throws -> URL {
        guard let libraryURL = library.url else {
            throw VideoStorageError.invalidLibraryPath
        }
        return libraryURL.appendingPathComponent("Videos")
    }
    
    private func customVideoURL(for library: Library) throws -> URL {
        guard let customPath = library.customVideoStoragePath else {
            throw VideoStorageError.noCustomPathConfigured
        }
        
        // Resolve security-scoped bookmark if available
        if let bookmarkData = library.videoStorageBookmarkData {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale)
                if !isStale {
                    return url.appendingPathComponent("Pangolin Videos")
                             .appendingPathComponent(library.name ?? "Unknown")
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        return URL(fileURLWithPath: customPath).appendingPathComponent("Pangolin Videos")
                                              .appendingPathComponent(library.name ?? "Unknown")
    }
    
    private func dropboxVideoURL(for library: Library) throws -> URL {
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let dropboxURL = homeURL.appendingPathComponent("Dropbox")
        
        guard fileManager.fileExists(atPath: dropboxURL.path) else {
            throw VideoStorageError.dropboxNotFound
        }
        
        return dropboxURL.appendingPathComponent("Pangolin Videos")
                        .appendingPathComponent(library.name ?? "Unknown")
    }
    
    private func googleDriveVideoURL(for library: Library) throws -> URL {
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let googleDriveURL = homeURL.appendingPathComponent("Google Drive")
        
        guard fileManager.fileExists(atPath: googleDriveURL.path) else {
            throw VideoStorageError.googleDriveNotFound
        }
        
        return googleDriveURL.appendingPathComponent("Pangolin Videos")
                           .appendingPathComponent(library.name ?? "Unknown")
    }
    
    private func oneDriveVideoURL(for library: Library) throws -> URL {
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let oneDriveURL = homeURL.appendingPathComponent("OneDrive")
        
        guard fileManager.fileExists(atPath: oneDriveURL.path) else {
            throw VideoStorageError.oneDriveNotFound
        }
        
        return oneDriveURL.appendingPathComponent("Pangolin Videos")
                         .appendingPathComponent(library.name ?? "Unknown")
    }
    
    // MARK: - Storage Detection
    
    private func detectAvailableStorageOptions() {
        var available: [VideoStorageType] = [.localLibrary] // Always available
        
        // Check iCloud availability
        if fileManager.url(forUbiquityContainerIdentifier: nil) != nil {
            available.append(.iCloudDrive)
        }
        
        // Check cloud service folders
        let homeURL = fileManager.homeDirectoryForCurrentUser
        
        if fileManager.fileExists(atPath: homeURL.appendingPathComponent("Dropbox").path) {
            available.append(.dropbox)
        }
        
        if fileManager.fileExists(atPath: homeURL.appendingPathComponent("Google Drive").path) {
            available.append(.googleDrive)
        }
        
        if fileManager.fileExists(atPath: homeURL.appendingPathComponent("OneDrive").path) {
            available.append(.oneDrive)
        }
        
        // Always allow custom paths and external drives
        available.append(contentsOf: [.customPath, .externalDrive])
        
        self.availableStorageTypes = available
    }
}

// MARK: - Video Storage Errors

enum VideoStorageError: LocalizedError {
    case iCloudUnavailable
    case invalidLibraryPath
    case noCustomPathConfigured
    case dropboxNotFound
    case googleDriveNotFound
    case oneDriveNotFound
    case storageLocationUnavailable
    
    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud Drive is not available"
        case .invalidLibraryPath:
            return "Library path is invalid"
        case .noCustomPathConfigured:
            return "No custom storage path configured"
        case .dropboxNotFound:
            return "Dropbox folder not found"
        case .googleDriveNotFound:
            return "Google Drive folder not found"
        case .oneDriveNotFound:
            return "OneDrive folder not found"
        case .storageLocationUnavailable:
            return "Selected storage location is not available"
        }
    }
}