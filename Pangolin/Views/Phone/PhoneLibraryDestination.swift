//
//  PhoneLibraryDestination.swift
//  Pangolin
//

import Foundation

/// The places the iPhone's Library control switches between.
enum PhoneLibraryDestination: String, CaseIterable, Identifiable, Hashable {
    case allVideos
    case projects
    case favourites
    case recents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allVideos: "All videos"
        case .projects: "Projects"
        case .favourites: "Favourites"
        case .recents: "Recents"
        }
    }

    var systemImage: String {
        switch self {
        case .allVideos: "list.bullet"
        case .projects: "square.grid.2x2"
        case .favourites: "heart"
        case .recents: "clock"
        }
    }

    /// The store destination this page shows.
    var storeDestination: LibrarySidebarDestination {
        switch self {
        case .allVideos: .smartCollection(.allVideos)
        case .projects: .projects
        case .favourites: .smartCollection(.favorites)
        case .recents: .smartCollection(.recent)
        }
    }
}

enum PhoneLibraryPolicy {
    /// Search takes over the page while the field is being used or holds a query.
    static func isSearching(isFieldFocused: Bool, query: String) -> Bool {
        isFieldFocused || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Library bar stays out of the way of a video, which needs the whole screen.
    static func showsLibraryBar(path: [PhoneProjectsRoute]) -> Bool {
        !path.contains { $0.videoID != nil }
    }
}
