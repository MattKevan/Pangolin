import CoreData
import SwiftUI
#if os(macOS)
import AppKit
#endif


struct ProjectsGridView: View {
    @Environment(FolderNavigationStore.self) private var store
    @EnvironmentObject private var libraryManager: LibraryManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var renamingProjectID: UUID?
    @State private var editedProjectTitle = ""
    @FocusState private var focusedProjectID: UUID?
    /// The selected card (macOS). Declared unconditionally so the card
    /// highlight comparison compiles on iOS, where it stays nil.
    @State private var selectedProjectID: UUID?
    #if os(macOS)
    @FocusState private var isGridKeyboardFocused: Bool
    /// Last single-click target, for manual double-click detection. A tap
    /// gesture on the card would defer the first click's action while macOS
    /// disambiguates single vs double click, which delays selection.
    @State private var lastClickProjectID: UUID?
    @State private var lastClickTime = Date.distantPast
    #endif
    @State private var projectPendingDeletion: Folder?
    @State private var showingDeletionConfirmation = false

    private let projectSelectionAction: ((Folder) -> Void)?

    private var projects: [Folder] {
        _ = store.contentRevision
        return store.projects()
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
                                        #if os(macOS)
                                        handleProjectClick(project)
                                        #else
                                        openProject(project)
                                        #endif
                                    },
                                    isRenaming: renamingProjectID == project.id,
                                    isSelected: selectedProjectID == project.id,
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
            #if os(macOS)
            // Interaction model: click selects, double-click opens, arrow keys
            // move the selection, Return opens it. Single click never navigates.
            // Selection is only set by explicit click/arrow-key/onAppear — never
            // by focus changes, because mouse-down focuses the grid before the
            // click action fires, which would flash the first card's border.
            .focusable()
            .focusEffectDisabled()
            .focused($isGridKeyboardFocused)
            .onMoveCommand { direction in
                moveKeyboardFocus(direction, columnCount: columns(for: geometry.size.width).count)
            }
            .onKeyPress { press in
                guard press.key == .return else { return .ignored }
                openKeyboardFocusedProject()
                return .handled
            }
            .onAppear {
                // The grid is recreated after opening a project, which clears
                // @State. Re-select the last selected project from the store.
                selectedProjectID = store.lastSelectedProjectID
            }
            #endif
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

    private func openProject(_ project: Folder) {
        store.lastSelectedProjectID = project.id
        if let projectSelectionAction {
            projectSelectionAction(project)
        } else {
            store.openProject(project)
        }
    }

    private func selectProject(_ project: Folder) {
        selectedProjectID = project.id
        store.lastSelectedProjectID = project.id
    }

    #if os(macOS)
    private func moveKeyboardFocus(_ direction: MoveCommandDirection, columnCount: Int) {
        guard !projects.isEmpty else { return }
        let currentIndex = selectedProjectID
            .flatMap { id in projects.firstIndex(where: { $0.id == id }) }
            ?? 0
        guard let nextIndex = ProjectGridFocusPolicy.nextIndex(
            from: currentIndex,
            columnCount: columnCount,
            itemCount: projects.count,
            direction: ProjectGridFocusPolicy.Direction(direction)
        ) else { return }
        selectedProjectID = projects[nextIndex].id
    }

    private func openKeyboardFocusedProject() {
        guard let id = selectedProjectID,
              let project = projects.first(where: { $0.id == id }) else { return }
        openProject(project)
    }

    /// Every click selects immediately; a second click on the same card within
    /// the system double-click interval also opens it. Manual detection keeps
    /// selection instant (a count-2 tap gesture defers the first click).
    private func handleProjectClick(_ project: Folder) {
        selectProject(project)
        let isDoubleClick = project.id == lastClickProjectID
            && Date.now.timeIntervalSince(lastClickTime) <= NSEvent.doubleClickInterval
        if isDoubleClick {
            lastClickProjectID = nil
            openProject(project)
        } else {
            lastClickProjectID = project.id
            lastClickTime = Date.now
        }
    }
    #endif

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
            if store.lastSelectedProjectID == projectID {
                store.lastSelectedProjectID = nil
            }
            if renamingProjectID == projectID {
                cancelRenaming()
            }
            cancelDeletion()
        }
    }
}

struct ProjectDetailView: View {
    @Environment(FolderNavigationStore.self) private var store

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    @State private var showingHighlightsPlaceholder = false
    @State private var editingVideo: Video?
    @State private var videoPendingDeletion: Video?
    @State private var showingVideoDeletionConfirmation = false

    let project: Folder
    let showsPhoneToolbar: Bool

    init(
        project: Folder,
        showsPhoneToolbar: Bool = false
    ) {
        self.project = project
        self.showsPhoneToolbar = showsPhoneToolbar
    }

    private var sections: [ProjectSectionSnapshot] {
        _ = store.contentRevision
        return store.projectSections(for: project)
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

    var body: some View {
        @Bindable var store = store
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
        @Bindable var store = store
        return VStack(spacing: 0) {
            if sections.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        macAlbumHero
                            .padding(.horizontal, ProjectGridLayout.contentPadding)
                            .padding(.top, ProjectGridLayout.contentPadding)
                            .padding(.bottom, 28)

                        projectEmptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .padding(.horizontal, ProjectGridLayout.contentPadding)
                            .padding(.bottom, ProjectGridLayout.contentPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                MacProjectVideoCollectionView(
                    sections: sections,
                    selection: $store.selectedProjectVideoIDs,
                    header: AnyView(
                        macAlbumHero
                            .padding(.horizontal, ProjectGridLayout.contentPadding)
                            .padding(.top, ProjectGridLayout.contentPadding)
                            .padding(.bottom, 28)
                    ),
                    footer: AnyView(
                        ProjectAlbumFooter(
                            videoCount: totalVideoCount,
                            duration: formattedProjectDuration(totalDuration)
                        )
                        .padding(.horizontal, ProjectGridLayout.contentPadding)
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                    ),
                    onOpen: { store.openProjectVideo($0, in: project) },
                    onEdit: { editingVideo = $0 },
                    onDelete: promptVideoDeletion,
                    onToggleFavorite: toggleFavorite
                )
                .accessibilityIdentifier("project-video-collection")
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

    private var padProjectDetail: some View {
        iosProjectDetail(isCompact: false)
        .navigationTitle(project.resolvedProjectTitle)
    }

    private var phoneProjectDetail: some View {
        iosProjectDetail(isCompact: true)
        .navigationTitle(project.resolvedProjectTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iosProjectDetail(isCompact: Bool) -> some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            if sections.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        heroContent(isCompact: isCompact)
                            .padding(.horizontal, ProjectGridLayout.contentPadding)
                            .padding(.top, ProjectGridLayout.contentPadding)
                            .padding(.bottom, 28)

                        projectEmptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .padding(.horizontal, ProjectGridLayout.contentPadding)
                            .padding(.bottom, ProjectGridLayout.contentPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                IOSProjectVideoCollectionView(
                    sections: sections,
                    selection: $store.selectedProjectVideoIDs,
                    isEditing: isEditingSelection,
                    isCompact: isCompact,
                    header: AnyView(
                        heroContent(isCompact: isCompact)
                            .padding(.horizontal, ProjectGridLayout.contentPadding)
                            .padding(.top, ProjectGridLayout.contentPadding)
                            .padding(.bottom, 28)
                    ),
                    footer: AnyView(
                        ProjectAlbumFooter(
                            videoCount: totalVideoCount,
                            duration: formattedProjectDuration(totalDuration)
                        )
                        .padding(.horizontal, ProjectGridLayout.contentPadding)
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                    ),
                    onEditingChanged: setIOSSelectionMode,
                    onOpen: { store.openProjectVideo($0, in: project) },
                    onEdit: { editingVideo = $0 },
                    onDelete: promptVideoDeletion,
                    onToggleFavorite: toggleFavorite
                )
                .accessibilityIdentifier("project-video-collection")
            }
        }
    }

    private func setIOSSelectionMode(_ isActive: Bool) {
        editMode?.wrappedValue = isActive ? .active : .inactive
    }
    #endif

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
                EditButton()

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
            }
            .disabled(store.selectedProjectVideoIDs.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
        }
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
