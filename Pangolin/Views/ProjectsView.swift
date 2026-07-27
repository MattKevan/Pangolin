import CoreData
import SwiftUI

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

enum ProjectVideoTouchInteraction: Equatable {
    case open(UUID)
    case selecting(Set<UUID>)
}

enum ProjectVideoTouchInteractionPolicy {
    static func tap(
        _ id: UUID,
        selection: Set<UUID>,
        isSelecting: Bool
    ) -> ProjectVideoTouchInteraction {
        guard isSelecting else { return .open(id) }

        var next = selection
        if !next.insert(id).inserted {
            next.remove(id)
        }
        return .selecting(next)
    }

    static func longPress(
        _ id: UUID,
        selection: Set<UUID>
    ) -> ProjectVideoTouchInteraction {
        .selecting(selection.union([id]))
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

struct ProjectsGridView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var renamingProjectID: UUID?
    @State private var editedProjectTitle = ""
    @FocusState private var focusedProjectID: UUID?
    @State private var projectPendingDeletion: Folder?
    @State private var showingDeletionConfirmation = false

    private let projectSelectionAction: ((Folder) -> Void)?

    private var projects: [Folder] {
        store.projects()
    }

    private var usesCompactGrid: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    init(projectSelectionAction: ((Folder) -> Void)? = nil) {
        self.projectSelectionAction = projectSelectionAction
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: ProjectGridLayout.spacing) {

                    if projects.isEmpty {
                        ContentUnavailableView(
                            "No projects yet",
                            systemImage: "square.grid.2x2",
                            description: Text("Create a project to organize sections and videos.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        LazyVGrid(
                            columns: columns(for: geometry.size.width),
                            alignment: .leading,
                            spacing: ProjectGridLayout.spacing
                        ) {
                            ForEach(projects, id: \.objectID) { project in
                                ProjectCard(
                                    project: project,
                                    action: {
                                        if let projectSelectionAction {
                                            projectSelectionAction(project)
                                        } else {
                                            store.openProject(project)
                                        }
                                    },
                                    isRenaming: renamingProjectID == project.id,
                                    editedTitle: $editedProjectTitle,
                                    focusedProjectID: $focusedProjectID,
                                    onRename: { beginRenaming(project) },
                                    onCommitRename: { Task { await commitRename(for: project) } },
                                    onCancelRename: cancelRenaming,
                                    onDelete: { promptDeletion(of: project) }
                                )
                                .accessibilityIdentifier("project-card-\(project.id?.uuidString ?? project.objectID.uriRepresentation().absoluteString)")
                            }
                        }
                    }
                }
                .padding(ProjectGridLayout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Projects")
        .projectFolderDrop(
            isEnabled: libraryManager.currentLibrary != nil,
            libraryManager: libraryManager
        )
        .alert("Delete Project?", isPresented: $showingDeletionConfirmation) {
            Button("Cancel", role: .cancel) {
                cancelDeletion()
            }
            Button("Delete", role: .destructive) {
                Task { await confirmDeletion() }
            }
        } message: {
            Text("This project and all its contents will be permanently deleted from your library and removed from disk. This action cannot be undone.")
        }
    }

    private func columns(for containerWidth: CGFloat) -> [GridItem] {
        let availableWidth = max(
            0,
            containerWidth - (ProjectGridLayout.contentPadding * 2)
        )
        let count = ProjectGridLayout.columnCount(
            availableWidth: availableWidth,
            isCompact: usesCompactGrid
        )
        return Array(
            repeating: GridItem(
                .flexible(minimum: 0, maximum: .infinity),
                spacing: ProjectGridLayout.spacing,
                alignment: .top
            ),
            count: count
        )
    }

    private func beginRenaming(_ project: Folder) {
        guard let projectID = project.id else { return }

        renamingProjectID = projectID
        editedProjectTitle = project.resolvedProjectTitle
        Task { @MainActor in
            await Task.yield()
            guard renamingProjectID == projectID else { return }
            focusedProjectID = projectID
        }
    }

    private func commitRename(for project: Folder) async {
        guard let projectID = project.id,
              renamingProjectID == projectID else {
            return
        }

        let title = ProjectRenamePolicy.savedTitle(
            draft: editedProjectTitle,
            current: project.resolvedProjectTitle
        )
        cancelRenaming()

        if let title {
            await store.renameItem(id: projectID, to: title)
        }
    }

    private func cancelRenaming() {
        renamingProjectID = nil
        focusedProjectID = nil
        editedProjectTitle = ""
    }

    private func promptDeletion(of project: Folder) {
        projectPendingDeletion = project
        showingDeletionConfirmation = true
    }

    private func cancelDeletion() {
        projectPendingDeletion = nil
        showingDeletionConfirmation = false
    }

    private func confirmDeletion() async {
        guard let projectID = projectPendingDeletion?.id else {
            cancelDeletion()
            return
        }

        let deleted = await store.deleteItems([projectID])
        if deleted {
            if renamingProjectID == projectID {
                cancelRenaming()
            }
            cancelDeletion()
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var store: FolderNavigationStore

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    @State private var showingHighlightsPlaceholder = false
    @State private var editingVideo: Video?
    @State private var videoPendingDeletion: Video?
    @State private var showingVideoDeletionConfirmation = false
    @State private var isTouchSelectingVideos = false

    let project: Folder
    let showsPhoneToolbar: Bool
    let opensVideoOnSingleTap: Bool

    init(
        project: Folder,
        showsPhoneToolbar: Bool = false,
        opensVideoOnSingleTap: Bool = true
    ) {
        self.project = project
        self.showsPhoneToolbar = showsPhoneToolbar
        self.opensVideoOnSingleTap = opensVideoOnSingleTap
    }

    private var sections: [ProjectSectionSnapshot] {
        store.projectSections(for: project)
    }

    private var totalVideoCount: Int {
        sections.reduce(0) { $0 + $1.videos.count }
    }

    private var totalDuration: TimeInterval {
        store.totalDuration(for: project)
    }

    private var continueWatchingVideo: Video? {
        store.continueWatchingVideo(in: project)
    }

    private var orderedDisplayedVideos: [Video] {
        sections.flatMap(\.videos)
    }

    private var displayedVideoIDs: Set<UUID> {
        Set(orderedDisplayedVideos.compactMap(\.id))
    }

    private var selectedProjectVideo: Video? {
        guard let id = ProjectVideoSelectionPolicy.primaryActionID(
            selection: store.selectedProjectVideoIDs,
            visibleIDs: displayedVideoIDs
        ) else { return nil }
        return orderedDisplayedVideos.first { $0.id == id }
    }

    private var hasProjectSearch: Bool {
        !store.projectSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var isEditingSelection: Bool {
        #if os(iOS)
        return editMode?.wrappedValue.isEditing == true
        #else
        return false
        #endif
    }

    private var isSelectingProjectVideos: Bool {
        isEditingSelection || isTouchSelectingVideos
    }

    var body: some View {
        let baseView = Group {
            #if os(macOS)
            macProjectDetail
            #else
            if UIDevice.current.userInterfaceIdiom == .phone {
                phoneProjectDetail
            } else {
                padProjectDetail
            }
            #endif
        }
        baseView
            .onChange(of: displayedVideoIDs) { _, visibleIDs in
                store.selectedProjectVideoIDs = ProjectVideoSelectionPolicy.reconciledSelection(
                    store.selectedProjectVideoIDs,
                    visibleIDs: visibleIDs
                )
            }
            .toolbar {
                projectToolbarItems
            }
            .projectSearchableIfNeeded(
                query: $store.projectSearchQuery,
                enabled: !showsPhoneToolbar
            )
            .alert("Highlights coming soon", isPresented: $showingHighlightsPlaceholder) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Highlights is a temporary placeholder in this pass.")
            }
            .sheet(item: $editingVideo) { video in
                VideoMetadataEditor(video: video)
            }
            .alert("Delete Video?", isPresented: $showingVideoDeletionConfirmation) {
                Button("Cancel", role: .cancel) { cancelVideoDeletion() }
                Button("Delete", role: .destructive) { Task { await deletePendingVideo() } }
            } message: {
                Text("This video will be permanently deleted from your library and removed from disk. This action cannot be undone.")
            }
    }

    #if os(macOS)
    private var macProjectDetail: some View {
        VStack(spacing: 0) {
            macAlbumHero
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 28)

            if sections.isEmpty {
                projectEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else {
                MacProjectVideoCollectionView(
                    sections: sections,
                    selection: $store.selectedProjectVideoIDs,
                    onOpen: { store.openProjectVideo($0, in: project) },
                    onEdit: { editingVideo = $0 },
                    onDelete: promptVideoDeletion,
                    onToggleFavorite: toggleFavorite
                )
                .accessibilityIdentifier("project-video-collection")

                ProjectAlbumFooter(
                    videoCount: totalVideoCount,
                    duration: formattedProjectDuration(totalDuration)
                )
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(project.resolvedProjectTitle)
    }

    private var macAlbumHero: some View {
        ViewThatFits(in: .horizontal) {
            heroContent(isCompact: false)
                .frame(minWidth: 520, alignment: .leading)

            heroContent(isCompact: true)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var projectEmptyState: some View {
        if hasProjectSearch {
            ContentUnavailableView.search(text: store.projectSearchQuery)
        } else {
            ContentUnavailableView(
                "No videos in this project",
                systemImage: "video.slash",
                description: Text("Import videos or add sections to populate the project.")
            )
        }
    }

    #endif

    #if os(iOS)
    private var padProjectDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroContent(isCompact: false)
                sectionListContent
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(project.resolvedProjectTitle)
    }

    private var phoneProjectDetail: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 28) {
                heroContent(isCompact: true)
                sectionListContent
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(project.resolvedProjectTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    @ViewBuilder
    private var sectionListContent: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 28) {
            ProjectVideoGrid(
                sections: sections,
                searchQuery: store.projectSearchQuery,
                selection: store.selectedProjectVideoIDs,
                isSelecting: isSelectingProjectVideos,
                onInteraction: handleTouchInteraction,
                onEdit: { editingVideo = $0 },
                onDelete: promptVideoDeletion,
                onToggleFavorite: toggleFavorite
            )

            if !sections.isEmpty {
                ProjectAlbumFooter(
                    videoCount: totalVideoCount,
                    duration: formattedProjectDuration(totalDuration)
                )
            }
        }
        #else
        if sections.isEmpty {
            ContentUnavailableView(
                "No videos in this project",
                systemImage: "video.slash",
                description: Text("Import videos or add sections to populate the project.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        ProjectSectionHeader(title: section.title)

                        ForEach(Array(section.videos.enumerated()), id: \.element.objectID) { index, video in
                            ProjectVideoRow(
                                video: video,
                                ordinal: index + 1,
                                isSelected: isVideoSelected(video),
                                showsSelectionAccessory: isEditingSelection,
                                tapAction: {
                                    if opensVideoOnSingleTap && !isEditingSelection {
                                        store.openProjectVideo(video, in: project)
                                    } else {
                                        handleSelection(for: video)
                                    }
                                }
                            )
                            .contextMenu {
                                Button("Edit Video") { editingVideo = video }
                                Button("Delete Video", role: .destructive) { promptVideoDeletion(video) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    @ViewBuilder
    private func heroContent(isCompact: Bool) -> some View {
        if isCompact {
            VStack(spacing: 18) {
                projectThumbnail(size: 176, cornerRadius: 12)

                VStack(spacing: 4) {
                    Text(project.resolvedProjectTitle)
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)

                    if !project.resolvedProjectProvider.isEmpty {
                        Text(project.resolvedProjectProvider)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    Text(heroStatsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                heroButtons(centered: true)
            }
        } else {
            HStack(alignment: .top, spacing: 20) {
                projectThumbnail(size: 212, cornerRadius: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(project.resolvedProjectTitle)
                        .font(.largeTitle.weight(.bold))

                    if !project.resolvedProjectProvider.isEmpty {
                        Text(project.resolvedProjectProvider)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    Text(heroStatsText)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    heroButtons(centered: false)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var heroStatsText: String {
        "\(totalVideoCount) \(totalVideoCount == 1 ? "video" : "videos") • \(formattedProjectDuration(totalDuration))"
    }

    @ViewBuilder
    private func projectThumbnail(size: CGFloat, cornerRadius: CGFloat) -> some View {
        ProjectSyncedThumbnailImage(project: project, contentMode: .fill) {
            placeholderThumbnail(cornerRadius: cornerRadius)
        }
        .id(ObjectIdentifier(project))
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
        }
    }

    private func placeholderThumbnail(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func heroButtons(centered: Bool) -> some View {
        let stack = HStack(spacing: 12) {
            Button("Continue watching") {
                if let continueWatchingVideo {
                    store.openProjectVideo(continueWatchingVideo, in: project)
                }
            }
            .buttonStyle(.bordered)
            .disabled(continueWatchingVideo == nil)

            Button("Highlights") {
                showingHighlightsPlaceholder = true
            }
            .buttonStyle(.bordered)
        }

        if centered {
            stack
        } else {
            stack.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ToolbarContentBuilder
    private var projectToolbarItems: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.downloadAllVideos(in: project)
            } label: {
                Image(systemName: "icloud.and.arrow.down")
            }
            .help("Download all videos in this project")

            projectOverflowMenu
        }
        #else
        if UIDevice.current.userInterfaceIdiom == .phone, showsPhoneToolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.downloadAllVideos(in: project)
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                }

                projectOverflowMenu

                Menu {
                    Button("Import Videos", systemImage: "video.badge.plus") {
                        NotificationCenter.default.post(name: .triggerImportVideos, object: nil)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()

                Button {
                    store.downloadAllVideos(in: project)
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                }

                projectOverflowMenu
            }
        }
        #endif
    }

    private var projectOverflowMenu: some View {
        Menu {
            if let selectedProjectVideo {
                Button(
                    selectedProjectVideo.isFavorite ? "Remove from favourites" : "Add to favourites",
                    systemImage: selectedProjectVideo.isFavorite ? "heart.slash" : "heart"
                ) {
                    toggleFavorite(selectedProjectVideo)
                }
                Button("Edit Video") { editingVideo = selectedProjectVideo }
                Button("Delete Video", role: .destructive) { promptVideoDeletion(selectedProjectVideo) }
                Divider()
            }

            Button("Clear search", systemImage: "xmark.circle") {
                store.projectSearchQuery = ""
            }
            .disabled(store.projectSearchQuery.isEmpty)

            Button("Clear selection", systemImage: "checkmark.circle") {
                store.clearProjectVideoSelection()
                #if os(iOS)
                isTouchSelectingVideos = false
                #endif
            }
            .disabled(store.selectedProjectVideoIDs.isEmpty && !isTouchSelectingVideos)
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    private func handleSelection(for video: Video) {
        guard let videoID = video.id else { return }

        if isEditingSelection {
            if store.selectedProjectVideoIDs.contains(videoID) {
                store.selectedProjectVideoIDs.remove(videoID)
            } else {
                store.selectedProjectVideoIDs.insert(videoID)
            }
        } else {
            store.selectedProjectVideoIDs = [videoID]
        }
    }

    #if os(iOS)
    private func handleTouchInteraction(_ interaction: ProjectVideoTouchInteraction) {
        switch interaction {
        case .open(let videoID):
            guard opensVideoOnSingleTap,
                  let video = orderedDisplayedVideos.first(where: { $0.id == videoID }) else {
                return
            }
            store.openProjectVideo(video, in: project)
        case .selecting(let selection):
            isTouchSelectingVideos = true
            store.selectedProjectVideoIDs = selection
        }
    }
    #endif

    private func isVideoSelected(_ video: Video) -> Bool {
        guard let videoID = video.id else { return false }
        return store.selectedProjectVideoIDs.contains(videoID)
    }

    private func toggleFavorite(_ video: Video) {
        video.isFavorite.toggle()
        guard let context = video.managedObjectContext else { return }

        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func promptVideoDeletion(_ video: Video) {
        videoPendingDeletion = video
        showingVideoDeletionConfirmation = true
    }

    private func cancelVideoDeletion() {
        videoPendingDeletion = nil
        showingVideoDeletionConfirmation = false
    }

    private func deletePendingVideo() async {
        guard let videoID = videoPendingDeletion?.id else {
            cancelVideoDeletion()
            return
        }
        if await store.deleteItems([videoID]) {
            cancelVideoDeletion()
        }
    }

    private func formattedProjectDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "0 min" }

        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            if minutes == 0 {
                return "\(hours) hr"
            }
            return "\(hours) hr \(minutes) min"
        }

        return "\(max(minutes, 1)) min"
    }
}

private struct ProjectCard: View {
    let project: Folder
    let action: () -> Void
    let isRenaming: Bool
    @Binding var editedTitle: String
    @FocusState.Binding var focusedProjectID: UUID?
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

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

private struct ProjectSyncedThumbnailImage<Placeholder: View>: View {
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

private struct ProjectAlbumSectionHeader: View {
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

private struct ProjectAlbumFooter: View {
    let videoCount: Int
    let duration: String

    var body: some View {
        Text("\(videoCount) \(videoCount == 1 ? "video" : "videos"), \(duration)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectVideoRow: View {
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

private extension View {
    @ViewBuilder
    func projectSearchableIfNeeded(query: Binding<String>, enabled: Bool) -> some View {
        if enabled {
            self
                .searchable(text: query, placement: .toolbar, prompt: "Search in project")
        } else {
            self
        }
    }
}
