//
//  Video.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Models/VideoModel.swift
import Foundation
import CoreData
import AVFoundation

// MARK: - Video Model
public class Video: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var title: String
    @NSManaged public var fileName: String
    @NSManaged public var relativePath: String
    @NSManaged public var duration: TimeInterval
    @NSManaged public var fileSize: Int64
    @NSManaged public var dateAdded: Date
    @NSManaged public var lastPlayed: Date?
    @NSManaged public var playbackPosition: TimeInterval
    @NSManaged public var playCount: Int32
    @NSManaged public var thumbnailPath: String?
    @NSManaged public var videoFormat: String?
    @NSManaged public var resolution: String?
    @NSManaged public var frameRate: Double
    @NSManaged public var isFavorite: Bool
    
    // Relationships
    @NSManaged public var folder: Folder?
    @NSManaged public var subtitles: Set<Subtitle>?
    @NSManaged public var library: Library?
    
    // Computed properties
    var fileURL: URL? {
        guard let library = library,
              let libraryPath = library.url else { return nil }
        return libraryPath.appendingPathComponent("Videos").appendingPathComponent(relativePath)
    }
    
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00"
    }
    
    var hasSubtitles: Bool {
        return (subtitles?.count ?? 0) > 0
    }
    
    var thumbnailURL: URL? {
        guard let library = library,
              let libraryPath = library.url,
              let thumbnailPath = thumbnailPath else { return nil }
        return libraryPath.appendingPathComponent("Thumbnails").appendingPathComponent(thumbnailPath)
    }
}


// MARK: - Folder Model
public class Folder: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var isTopLevel: Bool
    @NSManaged public var isSmartFolder: Bool
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateModified: Date
    
    // Relationships
    @NSManaged public var parentFolder: Folder?
    @NSManaged public var childFolders: Set<Folder>?
    @NSManaged public var videos: Set<Video>?
    @NSManaged public var library: Library?
    
    // Computed properties
    var childFoldersArray: [Folder] {
        guard let children = childFolders else { return [] }
        return Array(children).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    
    var videosArray: [Video] {
        guard let videos = videos else { return [] }
        return Array(videos).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
    
    var itemCount: Int {
        return (childFolders?.count ?? 0) + (videos?.count ?? 0)
    }
    
    var totalVideoCount: Int {
        let directVideos = videos?.count ?? 0
        let childVideos = childFolders?.reduce(0) { $0 + $1.totalVideoCount } ?? 0
        return directVideos + childVideos
    }
}

// MARK: - Subtitle Model
public class Subtitle: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var fileName: String
    @NSManaged public var relativePath: String
    @NSManaged public var language: String?
    @NSManaged public var languageName: String?
    @NSManaged public var isDefault: Bool
    @NSManaged public var isForced: Bool
    @NSManaged public var format: String // "srt", "vtt", "ssa"
    @NSManaged public var encoding: String // "UTF-8", etc.
    
    // Relationships
    @NSManaged public var video: Video?
    
    // Computed properties
    var fileURL: URL? {
        guard let video = video,
              let library = video.library,
              let libraryPath = library.url else { return nil }
        return libraryPath.appendingPathComponent("Subtitles").appendingPathComponent(relativePath)
    }
    
    var displayName: String {
        if let languageName = languageName {
            return languageName
        } else if let language = language {
            return Locale.current.localizedString(forLanguageCode: language) ?? language
        }
        return fileName
    }
}

// MARK: - Library Model
public class Library: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var createdDate: Date
    @NSManaged public var lastOpenedDate: Date
    @NSManaged public var version: String
    @NSManaged public var libraryPath: String
    
    // Settings
    @NSManaged public var copyFilesOnImport: Bool
    @NSManaged public var organizeByDate: Bool
    @NSManaged public var autoMatchSubtitles: Bool
    @NSManaged public var defaultPlaybackSpeed: Float
    @NSManaged public var rememberPlaybackPosition: Bool
    
    // Relationships
    @NSManaged public var videos: Set<Video>?
    @NSManaged public var folders: Set<Folder>?
    
    // Computed properties
    var url: URL? {
        return URL(fileURLWithPath: libraryPath)
    }
    
    var videoCount: Int {
        return videos?.count ?? 0
    }
    
    var totalSize: Int64 {
        return videos?.reduce(0) { $0 + $1.fileSize } ?? 0
    }
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}

// MARK: - Content Types
enum ContentType: Hashable {
    case folder(Folder)
    case video(Video)
    
    var id: UUID {
        switch self {
        case .folder(let folder): return folder.id
        case .video(let video): return video.id
        }
    }
    
    var name: String {
        switch self {
        case .folder(let folder): return folder.name
        case .video(let video): return video.title
        }
    }
    
    var dateCreated: Date {
        switch self {
        case .folder(let folder): return folder.dateCreated
        case .video(let video): return video.dateAdded
        }
    }
    
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

// MARK: - Sorting
enum SortOption: String, CaseIterable {
    case nameAscending = "Name A-Z"
    case nameDescending = "Name Z-A"
    case dateCreatedNewest = "Newest First"
    case dateCreatedOldest = "Oldest First"
    case foldersFirst = "Folders First"
}

enum SubtitleFormat: String, CaseIterable {
    case srt = "srt"
    case vtt = "vtt"
    case ssa = "ssa"
    case ass = "ass"
    
    var displayName: String {
        switch self {
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .ssa, .ass: return "SubStation Alpha (.ssa/.ass)"
        }
    }
}

enum VideoFormat: String, CaseIterable {
    case mp4 = "mp4"
    case mov = "mov"
    case m4v = "m4v"
    case mkv = "mkv"
    case avi = "avi"
    case webm = "webm"
    
    static var supportedExtensions: [String] {
        return VideoFormat.allCases.map { $0.rawValue }
    }
}

// MARK: - Library Descriptor (for multiple libraries)
struct LibraryDescriptor: Codable, Identifiable {
    let id: UUID
    let name: String
    let path: URL
    let lastOpenedDate: Date
    let createdDate: Date
    let version: String
    let thumbnailData: Data?
    let videoCount: Int
    let totalSize: Int64
    
    var isAvailable: Bool {
        return FileManager.default.fileExists(atPath: path.path)
    }
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}

extension Video {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Video> {
        return NSFetchRequest<Video>(entityName: "Video")
    }
}

extension Folder {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Folder> {
        return NSFetchRequest<Folder>(entityName: "Folder")
    }
}

extension Subtitle {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Subtitle> {
        return NSFetchRequest<Subtitle>(entityName: "Subtitle")
    }
}

extension Library {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Library> {
        return NSFetchRequest<Library>(entityName: "Library")
    }
}
