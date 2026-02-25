import Foundation
import CoreData

enum SmartCollectionKind: String, CaseIterable, Identifiable, Hashable {
    case allVideos
    case recent
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allVideos:
            return "All videos"
        case .recent:
            return "Recent"
        case .favorites:
            return "Favorites"
        }
    }

    var sidebarIcon: String {
        switch self {
        case .allVideos:
            return "video"
        case .recent:
            return "clock"
        case .favorites:
            return "heart"
        }
    }

    // Legacy persisted smart folders are still kept for compatibility.
    var legacyFolderName: String { title }

    static func fromLegacyFolderName(_ name: String?) -> SmartCollectionKind? {
        guard let name else { return nil }
        return allCases.first { $0.legacyFolderName == name }
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
        }
    }
}
