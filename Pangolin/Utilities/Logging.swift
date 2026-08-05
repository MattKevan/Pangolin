import Foundation
import os

// MARK: - Logging

/// Per-subsystem loggers. All runtime diagnostics should go through these
/// (via `Logger.<category>.<level>(...)`) instead of `print`, so Console.app
/// and the unified logging system can filter, persist, and attach metadata.
extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.newindustries.pangolin"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let coredata = Logger(subsystem: subsystem, category: "coredata")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let navigation = Logger(subsystem: subsystem, category: "navigation")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let download = Logger(subsystem: subsystem, category: "download")
    static let importProcess = Logger(subsystem: subsystem, category: "import")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let cloud = Logger(subsystem: subsystem, category: "cloud")
    static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
}
