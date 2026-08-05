import os
import SwiftUI
import CoreData
import Combine
import Observation
// MARK: - Navigation types

// MARK: - Sidebar Routing Types
enum LibrarySidebarDestination: Hashable, Identifiable {
    case search
    case projects
    case smartCollection(SmartCollectionKind)
    case folder(Folder)
    case video(Video)

    var id: String { stableKey }

    var stableKey: String {
        switch self {
        case .search:
            return "search"
        case .projects:
            return "projects"
        case .smartCollection(let kind):
            return "smart:\(kind.rawValue)"
        case .folder(let folder):
            if let id = folder.id?.uuidString {
                return "folder:\(id)"
            }
            return "folderObject:\(folder.objectID.uriRepresentation().absoluteString)"
        case .video(let video):
            if let id = video.id?.uuidString {
                return "video:\(id)"
            }
            return "videoObject:\(video.objectID.uriRepresentation().absoluteString)"
        }
    }

    static func == (lhs: LibrarySidebarDestination, rhs: LibrarySidebarDestination) -> Bool {
        lhs.stableKey == rhs.stableKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableKey)
    }
}

typealias SidebarSelection = LibrarySidebarDestination

enum LibraryDetailSurface: Equatable {
    case searchResults
    case projectsGrid
    case projectDetail
    case smartCollectionTable(SmartCollectionKind)
    case videoDetail
    case empty
}

enum FolderDeletionMode {
    case keepVideosInLibrary
    case deleteAllVideos
}

struct ProjectSectionSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let videos: [Video]
    let sourceFolder: Folder?

    static func == (lhs: ProjectSectionSnapshot, rhs: ProjectSectionSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}

struct VideoNeighbors {
    let previous: Video?
    let next: Video?
}

enum VideoNavigationOrigin {
    case project(Folder)
    case sidebar(LibrarySidebarDestination)
}
