//
//  DeviceStoragePreferences.swift
//  Pangolin
//

import Foundation

/// Storage preferences for this device.
///
/// A phone and a Mac need different answers, so none of these live on the synced `Library`
/// record. The keys are plain, library-independent `UserDefaults` keys because the iOS
/// Settings.bundle writes them directly. Values saved before the move are read as fallbacks.
enum DeviceStoragePreferences {
    /// Unit tests run inside the app's own sandbox; a separate suite keeps them from rewriting the
    /// developer's real settings.
    static let store: UserDefaults = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
              let suite = UserDefaults(suiteName: "PangolinTests.DeviceStoragePreferences") else {
            return .standard
        }
        suite.removePersistentDomain(forName: "PangolinTests.DeviceStoragePreferences")
        return suite
    }()

    static let storageModeKey = "storageMode"
    static let uploadOptimizationKey = "uploadOptimization"
    static let cacheLimitGBKey = "cacheLimitGB"

    static func storageMode(
        legacySyncedValue: String? = nil,
        defaults: UserDefaults = DeviceStoragePreferences.store
    ) -> LibraryStoragePreference {
        if let raw = defaults.string(forKey: storageModeKey),
           let mode = LibraryStoragePreference(rawValue: raw) {
            return mode
        }
        if let legacySyncedValue,
           let mode = LibraryStoragePreference(rawValue: legacySyncedValue) {
            return mode
        }
        return .optimizeStorage
    }

    static func setStorageMode(_ mode: LibraryStoragePreference, defaults: UserDefaults = DeviceStoragePreferences.store) {
        defaults.set(mode.rawValue, forKey: storageModeKey)
    }

    static func uploadOptimization(
        legacyLibraryID: UUID? = nil,
        defaults: UserDefaults = DeviceStoragePreferences.store
    ) -> VideoUploadOptimizationPreset {
        if let raw = defaults.string(forKey: uploadOptimizationKey),
           let preset = VideoUploadOptimizationPreset(rawValue: raw) {
            return preset
        }
        if let legacyLibraryID,
           let raw = defaults.string(forKey: "videoUploadOptimizationPreset." + legacyLibraryID.uuidString),
           let preset = VideoUploadOptimizationPreset(rawValue: raw) {
            return preset
        }
        return .original
    }

    static func setUploadOptimization(_ preset: VideoUploadOptimizationPreset, defaults: UserDefaults = DeviceStoragePreferences.store) {
        defaults.set(preset.rawValue, forKey: uploadOptimizationKey)
    }

    static func cacheLimitGB(
        legacyLibraryID: UUID? = nil,
        defaults: UserDefaults = DeviceStoragePreferences.store
    ) -> Int {
        let stored = defaults.object(forKey: cacheLimitGBKey) as? NSNumber
        if let gb = stored?.intValue, gb > 0 {
            return gb
        }
        if let legacyLibraryID,
           let bytes = defaults.object(forKey: "maxLocalVideoCacheBytes." + legacyLibraryID.uuidString) as? Int64,
           bytes > 0 {
            let bytesPerGB = Int64(1024 * 1024 * 1024)
            return max(1, Int((bytes + bytesPerGB - 1) / bytesPerGB))
        }
        return Int(Library.defaultMaxLocalVideoCacheBytes / (1024 * 1024 * 1024))
    }

    static func setCacheLimitGB(_ gb: Int, defaults: UserDefaults = DeviceStoragePreferences.store) {
        defaults.set(max(1, gb), forKey: cacheLimitGBKey)
    }
}
