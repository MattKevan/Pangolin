import Foundation
import CoreData

enum SmartCollectionKind: String, CaseIterable, Identifiable, Hashable {
    case allVideos
    case recent
    case favorites
    case downloads

    var id: String { rawValue }

    /// The collections the sidebar lists, in order. Downloads holds videos fetched from URLs,
    /// which only the Mac can do, so iOS does not list it.
    static var sidebarCases: [SmartCollectionKind] {
        #if os(macOS)
        [.allVideos, .favorites, .recent, .downloads]
        #else
        [.allVideos, .favorites, .recent]
        #endif
    }

    var title: String {
        switch self {
        case .allVideos:
            return "All videos"
        case .recent:
            return "Recents"
        case .favorites:
            return "Favourites"
        case .downloads:
            return "Downloads"
        }
    }

    var sidebarIcon: String {
        switch self {
        case .allVideos:
            return "list.bullet"
        case .recent:
            return "clock"
        case .favorites:
            return "heart"
        case .downloads:
            return "arrow.down.circle"
        }
    }

    func configureVideoFetchRequest(_ request: NSFetchRequest<Video>, library: Library) {
        switch self {
        case .allVideos:
            request.predicate = NSPredicate(format: "library == %@", library)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
        case .recent:
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            request.predicate = NSPredicate(format: "library == %@ AND dateAdded >= %@", library, thirtyDaysAgo as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Video.dateAdded, ascending: false)]
            request.fetchLimit = 50
        case .favorites:
            request.predicate = NSPredicate(format: "library == %@ AND isFavorite == YES", library)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
        case .downloads:
            request.predicate = NSPredicate(
                format: "library == %@ AND ((originalURL != nil AND originalURL != '') OR (remoteVideoID != nil AND remoteVideoID != ''))",
                library
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Video.dateAdded, ascending: false)]
        }
    }
}
