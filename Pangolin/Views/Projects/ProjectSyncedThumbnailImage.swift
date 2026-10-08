import CoreData
import SwiftUI


// MARK: - Project card components

struct ProjectSyncedThumbnailImage<Placeholder: View>: View {
    @ObservedObject var project: Folder
    let contentMode: ContentMode
    let placeholder: Placeholder
    let context: NSManagedObjectContext?

    @State private var thumbnailRevision: UInt64 = 0
    @State private var contextLifecycleRevision: UInt64 = 0
    @State private var reconciliationAttempt: UInt64 = 0
    @State private var observationState: ProjectThumbnailObservationState

    init(
        project: Folder,
        contentMode: ContentMode,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.project = project
        self.contentMode = contentMode
        self.placeholder = placeholder()
        context = project.managedObjectContext
        _observationState = State(
            initialValue: ProjectThumbnailObservationState(project: project)
        )
    }

    private var resolvedVideo: Video? {
        guard !observationState.isContextInvalidated else { return nil }
        _ = thumbnailRevision
        return project.resolvedProjectThumbnailVideo
    }

    var body: some View {
        Group {
            if let resolvedVideo {
                SyncedThumbnailImage(video: resolvedVideo, contentMode: contentMode) {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: context
        )) { notification in
            guard let context,
                  notification.object as? NSManagedObjectContext === context else { return }

            if let change = ProjectThumbnailChangePolicy.change(
                    for: notification,
                    in: context
                  ) {
                let shouldRefresh = observationState.handle(change: change) {
                    ProjectThumbnailMembership(project: project)
                }
                if shouldRefresh {
                    thumbnailRevision &+= 1
                }
            }
            if observationState.canQueueLifecycleRetry {
                contextLifecycleRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSManagedObjectContextDidSave,
            object: context
        )) { notification in
            guard let savedContext = notification.object as? NSManagedObjectContext,
                  savedContext === context else { return }
            if observationState.canQueueLifecycleRetry {
                contextLifecycleRevision &+= 1
            }
        }
        .task(id: contextLifecycleRevision) {
            guard contextLifecycleRevision > 0 else { return }
            await Task.yield()
            guard !Task.isCancelled, let context else { return }
            scheduleReconciliationIfPossible(in: context)
        }
        .task(id: reconciliationAttempt) {
            await Task.yield()
            guard !Task.isCancelled,
                  observationState.beginReconciliation() else { return }
            let result = ProjectThumbnailReconciler.reconcile(project)
            observationState.recordReconciliation(result)
        }
    }

    private func scheduleReconciliationIfPossible(in context: NSManagedObjectContext) {
        guard observationState.shouldScheduleReconciliation(
            contextIsClean: !context.hasChanges
        ) else { return }
        reconciliationAttempt &+= 1
    }
}
