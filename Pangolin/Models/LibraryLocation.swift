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
