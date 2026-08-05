import CoreData
import SwiftUI


// MARK: - Project card components

struct ProjectCard: View {
    let project: Folder
    let action: () -> Void
    let isRenaming: Bool
    let isKeyboardHighlighted: Bool
    @Binding var editedTitle: String
    @FocusState.Binding var focusedProjectID: UUID?
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    init(
        project: Folder,
        action: @escaping () -> Void,
        isRenaming: Bool,
        isKeyboardHighlighted: Bool = false,
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
        self.isKeyboardHighlighted = isKeyboardHighlighted
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
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

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
        .overlay {
            if isKeyboardHighlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
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
                #if os(macOS)
                // Finder-style rename affordance: slow double-click on the title.
                // Single clicks still bubble to the card's open action.
                .onTapGesture(count: 2) {
                    onRename()
                }
                #endif
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

struct ProjectSectionHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))

            Rectangle()
                .fill(Color.primary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.bottom, 6)
    }
}

struct ProjectAlbumSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ProjectAlbumFooter: View {
    let videoCount: Int
    let duration: String

    var body: some View {
        Text("\(videoCount) \(videoCount == 1 ? "video" : "videos"), \(duration)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProjectVideoRow: View {
    let video: Video
    let ordinal: Int
    let isSelected: Bool
    let showsSelectionAccessory: Bool
    let usesNativeListStyling: Bool
    let tapAction: (() -> Void)?

    init(
        video: Video,
        ordinal: Int,
        isSelected: Bool,
        showsSelectionAccessory: Bool,
        usesNativeListStyling: Bool = false,
        tapAction: (() -> Void)?
    ) {
        self.video = video
        self.ordinal = ordinal
        self.isSelected = isSelected
        self.showsSelectionAccessory = showsSelectionAccessory
        self.usesNativeListStyling = usesNativeListStyling
        self.tapAction = tapAction
    }

    var body: some View {
        VStack(spacing: 0) {
            interactiveRow

            if !usesNativeListStyling {
                Divider()
                    .padding(.leading, 44)
            }
        }
    }

    @ViewBuilder
    private var interactiveRow: some View {
        if let tapAction {
            rowContent
                .onTapGesture(perform: tapAction)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            activationContent

            if showsSelectionAccessory {
                Button {
                    tapAction?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Deselect video" : "Select video")
            }

            Button(action: toggleFavorite) {
                Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(video.isFavorite ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24)
            .help(favoriteActionLabel)
            .accessibilityLabel(favoriteActionLabel)

            Text(video.formattedDuration)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Menu {
                Button(favoriteActionLabel, systemImage: video.isFavorite ? "heart.slash" : "heart") {
                    toggleFavorite()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .accessibilityLabel("More actions for \(resolvedTitle)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if !usesNativeListStyling && isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
    }

    private var activationContent: some View {
        HStack(spacing: 12) {
            Text("\(ordinal)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            statusIndicator

            Text(resolvedTitle)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resolvedTitle: String {
        let trimmedTitle = video.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return video.fileName ?? "Untitled Video"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            switch video.watchStatus {
            case .unwatched:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: 14, height: 14)
            case .inProgress:
                Circle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 14, height: 14)
            case .watched:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityLabel(video.watchStatus.displayName)
    }

    private var favoriteActionLabel: String {
        video.isFavorite ? "Remove from favourites" : "Add to favourites"
    }

    private func toggleFavorite() {
        video.isFavorite.toggle()
        guard let viewContext = video.managedObjectContext else { return }

        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
        }
    }
}

