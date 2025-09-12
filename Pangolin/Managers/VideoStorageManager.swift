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
            // Default to iCloud Drive for all new libraries
            return try iCloudVideoURL(for: library)
        }
        
        switch storageType {
        case .iCloudDrive:
            return try iCloudVideoURL(for: library)
            
        case .localLibrary:
            return try localVideoURL(for: library)
            
        case .externalDrive, .customPath:
            return try customVideoURL(for: library)
            
        case .dropbox, .googleDrive, .oneDrive:
            // These will be handled through custom path selection in preferences
            // For now, fall back to custom path handling
            return try customVideoURL(for: library)
        }
    }
    
    // MARK: - Storage URL Implementations
    
    private func iCloudVideoURL(for library: Library) throws -> URL {
        // Ensure iCloud Drive is available
        guard fileManager.url(forUbiquityContainerIdentifier: nil) != nil else {
            throw VideoStorageError.iCloudUnavailable
        }
        
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
                #if os(macOS)
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale)
                #else
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                options: [],
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale)
                #endif
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
    
    // Cloud service URLs will be handled through user-selected custom paths in preferences
    // These methods are removed in favor of the customVideoURL implementation
    
    // MARK: - Storage Detection
    
    private func detectAvailableStorageOptions() {
        var available: [VideoStorageType] = []
        
        // Check iCloud availability - preferred default
        if fileManager.url(forUbiquityContainerIdentifier: nil) != nil {
            available.append(.iCloudDrive)
        }
        
        // Always available options
        available.append(.localLibrary)
        available.append(.customPath)
        
        #if os(macOS)
        // External drives are more relevant on macOS
        available.append(.externalDrive)
        #endif
        
        // Cloud services will be handled through custom path selection in preferences
        // Users can select their preferred cloud service folder location
        
        self.availableStorageTypes = available
    }
}

// MARK: - Video Storage Errors

enum VideoStorageError: LocalizedError {
    case iCloudUnavailable
    case invalidLibraryPath
    case noCustomPathConfigured
    case storageLocationUnavailable
    
    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud Drive is not available. Please enable iCloud Drive in System Preferences."
        case .invalidLibraryPath:
            return "Library path is invalid"
        case .noCustomPathConfigured:
            return "No custom storage path configured. Please select a storage location in Preferences."
        case .storageLocationUnavailable:
            return "Selected storage location is not available"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .iCloudUnavailable:
            return "Enable iCloud Drive in System Preferences or select a different storage location."
        case .noCustomPathConfigured:
            return "Go to Preferences and select a custom storage location."
        default:
            return nil
        }
    }
}