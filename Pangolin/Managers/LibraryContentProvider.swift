import Foundation
import CoreData

enum LibraryContentProvider {
    static func loadSmartCollection(
        _ kind: SmartCollectionKind,
        library: Library,
        context: NSManagedObjectContext
    ) throws -> [Video] {
        let request: NSFetchRequest<Video> = Video.fetchRequest()
        kind.configureVideoFetchRequest(request, library: library)
        return try context.fetch(request)
    }

    static func loadFolderContent(
        folderID: UUID,
        library: Library,
        context: NSManagedObjectContext
    ) throws -> (hierarchical: [HierarchicalContentItem], flat: [ContentType]) {
        let folderRequest = Folder.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)

        guard let folder = try context.fetch(folderRequest).first else {
            return ([], [])
        }

        var hierarchical: [HierarchicalContentItem] = []
        var flat: [ContentType] = []

        for childFolder in folder.childFoldersArray {
            hierarchical.append(HierarchicalContentItem(folder: childFolder))
            flat.append(.folder(childFolder))
        }

        for video in folder.videosArray {
            hierarchical.append(HierarchicalContentItem(video: video))
            flat.append(.video(video))
        }

        return (hierarchical, flat)
    }
}
