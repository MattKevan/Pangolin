//
//  LibraryLocation.swift
//  Pangolin
//

import Foundation
import os

/// Where this device keeps the open library's files.
///
/// The location is per device, so it is deliberately not stored on the synced `Library` record:
/// a path saved there would be overwritten by every other device that opens the library.
enum LibraryLocation {
    private static let storage = OSAllocatedUnfairLock<URL?>(initialState: nil)

    static var url: URL? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// The local video cache limit, a per-device preference kept in `UserDefaults` for the same
/// reason: a phone and a Mac need different limits, and a synced value would make them fight.
enum LocalVideoCachePreferences {
    private static let keyPrefix = "maxLocalVideoCacheBytes."

    static func maxBytes(for libraryID: UUID?) -> Int64 {
        guard let libraryID,
              let stored = UserDefaults.standard.object(forKey: keyPrefix + libraryID.uuidString) as? Int64,
              stored > 0 else {
            return Library.defaultMaxLocalVideoCacheBytes
        }
        return stored
    }

    static func setMaxBytes(_ bytes: Int64, for libraryID: UUID?) {
        guard let libraryID else { return }
        UserDefaults.standard.set(bytes, forKey: keyPrefix + libraryID.uuidString)
    }
}
