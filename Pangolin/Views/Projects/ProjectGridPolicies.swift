import CoreData
import SwiftUI


// MARK: - Project grid & thumbnail policies

struct ProjectThumbnailMembership: Equatable {
    let videoIDs: Set<NSManagedObjectID>
    let folderIDs: Set<NSManagedObjectID>

    static let empty = ProjectThumbnailMembership(videoIDs: [], folderIDs: [])

    private init(
        videoIDs: Set<NSManagedObjectID>,
        folderIDs: Set<NSManagedObjectID>
    ) {
        self.videoIDs = videoIDs
        self.folderIDs = folderIDs
    }

    init(project: Folder) {
        var visitedFolderIDs: Set<NSManagedObjectID> = []
        var collectedVideoIDs: Set<NSManagedObjectID> = []

        func collect(_ folder: Folder) {
            guard visitedFolderIDs.insert(folder.objectID).inserted else { return }
            collectedVideoIDs.formUnion(folder.videosArray.map(\.objectID))
            folder.childFoldersArray.forEach(collect)
        }

        collect(project)
        videoIDs = collectedVideoIDs
        folderIDs = visitedFolderIDs
    }

    var objectIDs: Set<NSManagedObjectID> {
        videoIDs.union(folderIDs)
    }
}

enum ProjectThumbnailChange {
    case invalidatedAll
    case objects(Set<NSManagedObjectID>)
}

enum ProjectThumbnailReconciliationResult: Equatable {
    case saved
    case alreadyCurrent
    case deferredDirty
    case failed
}

struct ProjectThumbnailObservationState {
    private(set) var membership: ProjectThumbnailMembership
    private(set) var isContextInvalidated = false
    private(set) var reconciliationPending = true
    private var reconciliationInFlight = false

    init(project: Folder) {
        membership = ProjectThumbnailMembership(project: project)
    }

    mutating func handle(
        change: ProjectThumbnailChange,
        currentMembership: () -> ProjectThumbnailMembership
    ) -> Bool {
        guard !isContextInvalidated else { return false }

        switch change {
        case .invalidatedAll:
            isContextInvalidated = true
            membership = .empty
            reconciliationPending = false
            reconciliationInFlight = false
            return true
        case .objects:
            let current = currentMembership()
            let shouldRefresh = ProjectThumbnailChangePolicy.shouldRefresh(
                change: change,
                previous: membership,
                current: current
            )
            membership = current
            if shouldRefresh {
                reconciliationPending = true
            }
            return shouldRefresh
        }
    }

    mutating func markReconciliationPending() {
        guard !isContextInvalidated else { return }
        reconciliationPending = true
    }

    func shouldScheduleReconciliation(contextIsClean: Bool) -> Bool {
        reconciliationPending
            && !reconciliationInFlight
            && !isContextInvalidated
            && contextIsClean
    }

    var canQueueLifecycleRetry: Bool {
        reconciliationPending && !reconciliationInFlight && !isContextInvalidated
    }

    mutating func beginReconciliation() -> Bool {
        guard reconciliationPending,
              !reconciliationInFlight,
              !isContextInvalidated else {
            return false
        }
        reconciliationInFlight = true
        return true
    }

    mutating func recordReconciliation(_ result: ProjectThumbnailReconciliationResult) {
        reconciliationInFlight = false
        switch result {
        case .saved, .alreadyCurrent:
            reconciliationPending = false
        case .deferredDirty, .failed:
            reconciliationPending = !isContextInvalidated
        }
    }
}

enum ProjectThumbnailChangePolicy {
    private static let thumbnailKeys: Set<String> = [
        "thumbnailData",
        "thumbnailGeneratedAt",
        "thumbnailGenerationVersion",
    ]
    private static let videoStructuralKeys: Set<String> = ["folder"]
    private static let folderStructuralKeys: Set<String> = [
        "childFolders",
        "parentFolder",
        "videos",
    ]

    static func shouldRefresh(
        project: Folder,
        video: Video,
        changedKeys: Set<String>
    ) -> Bool {
        let belongsToProject = project.descendantVideos.contains {
            $0.objectID == video.objectID
        }
        let suppliedCurrentArtwork = project.projectThumbnailVideoID == video.id
        guard belongsToProject || suppliedCurrentArtwork else { return false }

        return changedKeys.isEmpty || !thumbnailKeys.isDisjoint(with: changedKeys)
    }

    static func shouldRefresh(
        notification: Notification,
        in context: NSManagedObjectContext,
        previous: ProjectThumbnailMembership,
        current: ProjectThumbnailMembership
    ) -> Bool {
        guard let change = change(for: notification, in: context) else { return false }
        return shouldRefresh(change: change, previous: previous, current: current)
    }

    static func change(
        for notification: Notification,
        in context: NSManagedObjectContext
    ) -> ProjectThumbnailChange? {
        guard let changedContext = notification.object as? NSManagedObjectContext,
              changedContext === context else {
            return nil
        }

        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            return .invalidatedAll
        }

        var objectIDs: Set<NSManagedObjectID> = []
        for key in [NSInsertedObjectsKey, NSDeletedObjectsKey, NSInvalidatedObjectsKey] {
            objectIDs.formUnion(
                managedObjects(for: key, in: notification)
                    .filter(isArtworkStructureObject)
                    .map(\.objectID)
            )
        }

        for object in managedObjects(for: NSUpdatedObjectsKey, in: notification) {
            let changedKeys = Set(object.changedValuesForCurrentEvent().keys)
            switch object {
            case is Video where changedKeys.isEmpty
                || !thumbnailKeys.isDisjoint(with: changedKeys)
                || !videoStructuralKeys.isDisjoint(with: changedKeys):
                objectIDs.insert(object.objectID)
            case is Folder where changedKeys.isEmpty
                || !folderStructuralKeys.isDisjoint(with: changedKeys):
                objectIDs.insert(object.objectID)
            default:
                break
            }
        }

        objectIDs.formUnion(
            managedObjects(for: NSRefreshedObjectsKey, in: notification)
                .filter(isArtworkStructureObject)
                .map(\.objectID)
        )

        return objectIDs.isEmpty ? nil : .objects(objectIDs)
    }

    static func shouldRefresh(
        change: ProjectThumbnailChange,
        previous: ProjectThumbnailMembership,
        current: ProjectThumbnailMembership
    ) -> Bool {
        switch change {
        case .invalidatedAll:
            return true
        case .objects(let changedObjectIDs):
            return !changedObjectIDs.isDisjoint(with: previous.objectIDs.union(current.objectIDs))
        }
    }

    private static func isArtworkStructureObject(_ object: NSManagedObject) -> Bool {
        object.entity.name == "Video" || object.entity.name == "Folder"
    }

    private static func managedObjects(
        for key: String,
        in notification: Notification
    ) -> Set<NSManagedObject> {
        notification.userInfo?[key] as? Set<NSManagedObject> ?? []
    }
}

@MainActor
enum ProjectThumbnailReconciler {
    @discardableResult
    static func reconcile(_ project: Folder) -> ProjectThumbnailReconciliationResult {
        guard let context = project.managedObjectContext else { return .failed }
        guard !context.hasChanges else { return .deferredDirty }

        let resolvedVideoID = project.resolvedProjectThumbnailVideo?.id
        guard project.projectThumbnailVideoID != resolvedVideoID else {
            return .alreadyCurrent
        }

        project.projectThumbnailVideoID = resolvedVideoID
        do {
            try context.save()
            return .saved
        } catch {
            context.rollback()
            return .failed
        }
    }
}

enum ProjectVideoSelectionPolicy {
    static func reconciledSelection(
        _ selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> Set<UUID> {
        selection.intersection(visibleIDs)
    }

    static func activationID(
        selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> UUID? {
        guard selection.count == 1,
              let selectedID = selection.first,
              visibleIDs.contains(selectedID) else {
            return nil
        }
        return selectedID
    }

    static func primaryActionID(
        selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> UUID? {
        activationID(selection: selection, visibleIDs: visibleIDs)
    }

    static func marqueeSelection(
        hitIDs: Set<UUID>,
        selection: Set<UUID>,
        extendingSelection: Bool
    ) -> Set<UUID> {
        extendingSelection ? selection.symmetricDifference(hitIDs) : hitIDs
    }

    static func backgroundSelection() -> Set<UUID> {
        []
    }
}

enum ProjectVideoGridLayout {
    static let spacing: CGFloat = ProjectGridLayout.spacing
    static let minimumRegularCardWidth: CGFloat = 180

    static func columnCount(availableWidth: CGFloat, isCompact: Bool) -> Int {
        guard !isCompact else { return 2 }
        return max(2, Int((availableWidth + spacing) / (minimumRegularCardWidth + spacing)))
    }

    static func regularColumns(availableWidth: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: columnCount(availableWidth: availableWidth, isCompact: false)
        )
    }
}

enum IOSProjectVideoCollectionInteraction: Equatable {
    case open(UUID)
    case selecting(Set<UUID>)
}

enum IOSProjectVideoCollectionPolicy {
    static func interaction(
        for id: UUID,
        selection: Set<UUID>,
        isEditing: Bool
    ) -> IOSProjectVideoCollectionInteraction {
        guard isEditing else { return .open(id) }

        var next = selection
        if !next.insert(id).inserted {
            next.remove(id)
        }
        return .selecting(next)
    }
}

enum ProjectRenamePolicy {
    static func savedTitle(draft: String, current: String) -> String? {
        let trimmedTitle = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != current else { return nil }
        return trimmedTitle
    }
}

enum ProjectGridLayout {
    static let contentPadding: CGFloat = 22
    static let spacing: CGFloat = 22
    static let minimumRegularCardWidth: CGFloat = 220
    static let compactColumnCount = 2
    static let minimumRegularColumnCount = 2
    static let cardAspectRatio: CGFloat = 5.0 / 3.0

    static func columnCount(availableWidth: CGFloat, isCompact: Bool) -> Int {
        guard !isCompact else { return compactColumnCount }

        let fittedColumnCount = Int(
            (availableWidth + spacing) / (minimumRegularCardWidth + spacing)
        )
        return max(minimumRegularColumnCount, fittedColumnCount)
    }
}

/// Pure arrow-key navigation math for the projects grid: index movement with
/// clamping at the grid edges and the partial last row.
enum ProjectGridFocusPolicy {
    enum Direction: Equatable {
        case up
        case down
        case left
        case right
    }

    static func nextIndex(
        from currentIndex: Int,
        columnCount: Int,
        itemCount: Int,
        direction: Direction
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        guard currentIndex >= 0, currentIndex < itemCount else { return nil }

        let columns = max(1, columnCount)
        switch direction {
        case .left:
            return max(0, currentIndex - 1)
        case .right:
            return min(itemCount - 1, currentIndex + 1)
        case .up:
            return max(0, currentIndex - columns)
        case .down:
            return min(itemCount - 1, currentIndex + columns)
        }
    }
}

#if os(macOS)
extension ProjectGridFocusPolicy.Direction {
    init(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            self = .up
        case .down:
            self = .down
        case .left:
            self = .left
        case .right:
            self = .right
        @unknown default:
            self = .right
        }
    }
}
#endif
