import CoreData
import SwiftUI


// MARK: - Project card components

struct ProjectCard: View {
    let project: Folder
    /// Single click/tap: selects the project on macOS, opens it on iOS/iPadOS.
    /// Double-click handling lives in the grid (manual timing), so the card
    /// needs only this one action.
    let action: () -> Void
    let isRenaming: Bool
    let isSelected: Bool
    @Binding var editedTitle: String
    @FocusState.Binding var focusedProjectID: UUID?
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    init(
        project: Folder,
        action: @escaping () -> Void,
        isRenaming: Bool,
        isSelected: Bool = false,
        editedTitle: Binding<String>,
        focusedProjectID: FocusState<UUID?>.Binding,
        onRename: @escaping () -> Void,
        onCommitRename: @escaping () -> Void,
        onCancelRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.project = project
        self.action = action
        self.isRenaming = isRenaming
        self.isSelected = isSelected
        self._editedTitle = editedTitle
        self._focusedProjectID = focusedProjectID
        self.onRename = onRename
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename
        self.onDelete = onDelete
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .aspectRatio(ProjectGridLayout.cardAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        thumbnail
                    }
                    .clipShape(.rect(cornerRadius: 6))
                    .shadow(
                        color: .black.opacity(isHovering ? 0.32 : 0.18),
                        radius: isHovering ? 14 : 6,
                        y: isHovering ? 6 : 2
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                    // Hover zoom applies to the thumbnail only, not the title.
                    .scaleEffect(isHovering ? 1.02 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)

                VStack(alignment: .leading, spacing: 2) {
                    projectTitle

                    if !project.resolvedProjectProvider.isEmpty {
                        Text(project.resolvedProjectProvider)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityHint("Opens the project")
        .contextMenu {
            Button("Rename") {
                onRename()
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    @ViewBuilder
    private var projectTitle: some View {
        if isRenaming, let projectID = project.id {
            TextField("Project title", text: $editedTitle)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .focused($focusedProjectID, equals: projectID)
                .onSubmit(onCommitRename)
                .onKeyPress { keyPress in
                    if keyPress.key == .escape {
                        onCancelRename()
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: focusedProjectID) { oldValue, newValue in
                    if oldValue == projectID && newValue != projectID {
                        onCommitRename()
                    }
                }
        } else {
            Text(project.resolvedProjectTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ProjectSyncedThumbnailImage(project: project, contentMode: .fill) {
            placeholderThumbnail
        }
        .id(ObjectIdentifier(project))
    }

    private var placeholderThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

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
