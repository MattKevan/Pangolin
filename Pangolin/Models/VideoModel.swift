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
import UniformTypeIdentifiers
import CoreTransferable

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
    
    // Relationships
    @NSManaged public var playlists: Set<Playlist>?
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

// Helper struct for transferring video data
public struct VideoTransfer: Codable, Transferable {
    let id: UUID
    let title: String
    let sourcePlaylistId: UUID?
    
    init(video: Video, sourcePlaylist: Playlist? = nil) {
        self.id = video.id
        self.title = video.title
        self.sourcePlaylistId = sourcePlaylist?.id
    }
    
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .data) { video in
            try JSONEncoder().encode(video)
        } importing: { data in
            try JSONDecoder().decode(VideoTransfer.self, from: data)
        }
    }
}

// MARK: - Playlist Model
public class Playlist: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var type: String // "system" or "user"
    @NSManaged public var sortOrder: Int32
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateModified: Date
    @NSManaged public var iconName: String?
    @NSManaged public var color: String?
    
    // Relationships
    @NSManaged public var parentPlaylist: Playlist?
    @NSManaged public var childPlaylists: Set<Playlist>?
    @NSManaged public var videos: Set<Video>?
    @NSManaged public var library: Library?
    
    // Computed properties
    var isSystemPlaylist: Bool {
        return type == "system"
    }
    
    var childPlaylistsArray: [Playlist]? {
        guard let children = childPlaylists, !children.isEmpty else { return nil }
        return Array(children).sorted { $0.sortOrder < $1.sortOrder }
    }
    
    enum ContentType {
        case empty      // Can accept videos or playlists
        case playlist   // Contains videos, can only accept more videos
        case folder     // Contains playlists, can only accept more playlists
    }
    
    var contentType: ContentType {
        let hasVideos = (videos?.count ?? 0) > 0
        let hasPlaylists = (childPlaylists?.count ?? 0) > 0
        
        if hasVideos && hasPlaylists {
            // Legacy mixed content - treat as folder for safety
            return .folder
        } else if hasVideos {
            return .playlist
        } else if hasPlaylists {
            return .folder
        } else {
            return .empty
        }
    }
    
    var isFolder: Bool {
        return contentType == .folder
    }
    
    var canAcceptVideos: Bool {
        return contentType != .folder
    }
    
    var canAcceptPlaylists: Bool {
        return contentType != .playlist
    }
    
    var dynamicIconName: String {
        // System playlists use their custom icons
        if isSystemPlaylist, let icon = iconName {
            return icon
        }
        
        // User playlists use content-based icons
        switch contentType {
        case .empty:
            return "folder.badge.plus"  // Empty, can accept anything
        case .playlist:
            return "music.note.list"    // Contains videos
        case .folder:
            return "folder"             // Contains playlists
        }
    }
    
    var videoCount: Int {
        if isSystemPlaylist {
            return getSmartPlaylistVideos().count
        }
        
        if isFolder {
            // Recursively count videos in child playlists
            return childPlaylists?.reduce(0) { $0 + $1.videoCount } ?? 0
        }
        return videos?.count ?? 0
    }
    
    var allVideos: [Video] {
        // Handle smart playlists (system playlists)
        if isSystemPlaylist {
            return getSmartPlaylistVideos()
        }
        
        // Handle regular playlists
        var allVids: [Video] = []
        
        if let videos = videos {
            allVids.append(contentsOf: videos)
        }
        
        if let children = childPlaylists {
            for child in children {
                allVids.append(contentsOf: child.allVideos)
            }
        }
        
        return allVids
    }
    
    private func getSmartPlaylistVideos() -> [Video] {
        guard let library = library else { return [] }
        
        switch name {
        case "All Videos":
            return Array(library.videos ?? [])
        case "Recent":
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            return Array(library.videos ?? [])
                .filter { $0.dateAdded >= thirtyDaysAgo }
                .sorted { $0.dateAdded > $1.dateAdded }
        case "Favorites":
            // TODO: Implement favorites when rating system is added
            return []
        case "Watch Later":
            // TODO: Implement watch later when flag is added to Video model
            return []
        default:
            return []
        }
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
    @NSManaged public var playlists: Set<Playlist>?
    
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

// MARK: - Enums
enum PlaylistType: String, CaseIterable {
    case system = "system"
    case user = "user"
    
    
    
    static var systemPlaylists: [(name: String, icon: String)] {
        return [
            ("All Videos", "film.stack"),
            ("Recent", "clock"),
            ("Favorites", "star"),
            ("Watch Later", "bookmark")
        ]
    }
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

extension Playlist {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Playlist> {
        return NSFetchRequest<Playlist>(entityName: "Playlist")
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
