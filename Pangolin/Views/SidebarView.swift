import SwiftUI

enum ProjectSidebarDropPolicy {
    static func canMove(videoIDs: [UUID], isProject: Bool) -> Bool {
        isProject && !videoIDs.isEmpty
    }

    static func shouldConsumePayload(
        videoIDs: [UUID],
        isProject: Bool,
        hasAlreadyHandledSession: Bool
    ) -> Bool {
        canMove(videoIDs: videoIDs, isProject: isProject) && !hasAlreadyHandledSession
    }
}

enum SidebarProjectSelectionPolicy {
    static func canOpen(isProject: Bool) -> Bool {
        isProject
    }

    static func prefersProjectRowHighlight(
        isProjectsDestination: Bool,
        hasSelectedProject: Bool
    ) -> Bool {
        isProjectsDestination && hasSelectedProject
    }

    static func shouldResetProjectDetail(
        isProjectsDestination: Bool,
        hasSelectedProject: Bool
    ) -> Bool {
        isProjectsDestination && hasSelectedProject
    }
}

enum SidebarProjectRowPresentation {
    static let systemImage = "folder"
}

enum ProjectSidebarRowIdentity {
    static func value(projectID: UUID?, objectURI: URL) -> String {
        if let projectID {
            return "project:\(projectID.uuidString)"
        }
        return "object:\(objectURI.absoluteString)"
    }

    static func value(for project: Folder) -> String {
        value(
            projectID: project.id,
            objectURI: project.objectID.uriRepresentation()
        )
    }
}

private struct SidebarProjectRowModel: Identifiable {
    let project: Folder
    let id: String

    init(project: Folder) {
        self.project = project
        id = ProjectSidebarRowIdentity.value(for: project)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager

    @State private var sidebarSelections = Set<SidebarSelection>()
    @State private var isSyncingSelection = false
    @State private var renamingProjectID: UUID?
    @State private var editedProjectTitle = ""
    @FocusState private var focusedProjectID: UUID?
    @State private var projectPendingDeletion: Folder?
    @State private var showingProjectDeletionConfirmation = false
    @State private var projectDropTargetID: UUID?
    @State private var handledProjectDropSessions = Set<DropSession.ID>()

    var body: some View {
        List(selection: $sidebarSelections) {
            Section("Pangolin") {
                sidebarShortcutRow(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    destination: .search,
                    accessibilityID: "sidebar-search"
                )
                sidebarShortcutRow(
                    title: "Projects",
                    systemImage: "square.grid.2x2",
                    destination: .projects,
                    accessibilityID: "sidebar-projects"
                )

                ForEach(SmartCollectionKind.allCases) { smartCollection in
                    sidebarShortcutRow(
                        title: smartCollection.title,
                        systemImage: smartCollection.sidebarIcon,
                        destination: .smartCollection(smartCollection),
                        accessibilityID: "sidebar-\(smartCollection.rawValue)"
                    )
                }
            }

            Section("Projects") {
                ForEach(sidebarProjects) { row in
                    projectSidebarRow(row.project)
                        .tag(SidebarSelection.folder(row.project))
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .projectFolderDrop(
            isEnabled: libraryManager.currentLibrary != nil,
            libraryManager: libraryManager
        )
        .navigationTitle("Library")
        .contextMenu {
            Button("New project") {
                requestNewProject()
            }
            .disabled(libraryManager.currentLibrary == nil)
        }
        
        .onAppear {
            syncSidebarSelections(with: store.selectedSidebarItem)
        }
        .onChange(of: sidebarSelections) { oldSelection, newSelection in
            guard !isSyncingSelection else { return }
            guard oldSelection != newSelection else { return }
            selectSidebarItem(newSelection.first)
        }
        .onChange(of: store.selectedSidebarItem) { _, newSelection in
            syncSidebarSelections(with: newSelection)
        }
        .onChange(of: store.selectedProject?.objectID) { _, _ in
            syncSidebarSelections(with: store.selectedSidebarItem)
        }
        .alert("Delete Project?", isPresented: $showingProjectDeletionConfirmation) {
            Button("Cancel", role: .cancel) {
                cancelProjectDeletion()
            }
            Button("Delete", role: .destructive) {
                Task { await confirmProjectDeletion() }
            }
        } message: {
            Text("This project and all its contents will be permanently deleted from your library and removed from disk. This action cannot be undone.")
        }
    }

    private var sidebarProjects: [SidebarProjectRowModel] {
        store.projects().map { SidebarProjectRowModel(project: $0) }
    }

    @ViewBuilder
    private func sidebarShortcutRow(
        title: String,
        systemImage: String,
        destination: SidebarSelection,
        accessibilityID: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .tag(destination)
            .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder
    private func projectSidebarRow(_ project: Folder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: SidebarProjectRowPresentation.systemImage)

            if let projectID = project.id, renamingProjectID == projectID {
                TextField("Project name", text: $editedProjectTitle)
                    .focused($focusedProjectID, equals: projectID)
                    .onSubmit {
                        Task { await commitProjectRename(for: project) }
                    }
            } else {
                Text(project.resolvedProjectTitle)
            }
        }
        .background {
            if let projectID = project.id, projectDropTargetID == projectID {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .dropDestination(
            for: VideoTableDragTransfer.self,
            isEnabled: project.isProject
        ) { transfers, session in
            handleProjectVideoDrop(
                transfers,
                session: session,
                project: project
            )
        }
        .contextMenu {
            Button("Open") {
                store.openProject(project)
            }
            Button("Rename") {
                beginProjectRename(project)
            }
            Button("Delete", role: .destructive) {
                promptProjectDeletion(of: project)
            }
        }
    }

    private func updateProjectDropTarget(_ isTargeted: Bool, for project: Folder) {
        guard let projectID = project.id else { return }
        if isTargeted {
            projectDropTargetID = projectID
        } else if projectDropTargetID == projectID {
            projectDropTargetID = nil
        }
    }

    private func moveDroppedVideos(
        _ transfers: [VideoTableDragTransfer],
        to project: Folder
    ) -> Bool {
        guard let projectID = project.id else { return false }
        let videoIDs = Array(Set(transfers.flatMap(\.videoIDs)))
        guard ProjectSidebarDropPolicy.canMove(videoIDs: videoIDs, isProject: project.isProject) else {
            return false
        }

        Task { @MainActor in
            await store.moveItems(Set(videoIDs), to: projectID)
        }
        return true
    }

    private func handleProjectVideoDrop(
        _ transfers: [VideoTableDragTransfer],
        session: DropSession,
        project: Folder
    ) {
        switch session.phase {
        case .entering, .active:
            updateProjectDropTarget(true, for: project)
        case .exiting:
            updateProjectDropTarget(false, for: project)
        case .ended, .dataTransferCompleted:
            updateProjectDropTarget(false, for: project)
            let videoIDs = Array(Set(transfers.flatMap(\.videoIDs)))
            guard ProjectSidebarDropPolicy.shouldConsumePayload(
                videoIDs: videoIDs,
                isProject: project.isProject,
                hasAlreadyHandledSession: handledProjectDropSessions.contains(session.id)
            ) else {
                return
            }
            handledProjectDropSessions.insert(session.id)
            _ = moveDroppedVideos(transfers, to: project)
        @unknown default:
            updateProjectDropTarget(false, for: project)
        }
    }

    private func selectSidebarItem(_ selection: SidebarSelection?) {
        if case .projects = selection,
           SidebarProjectSelectionPolicy.shouldResetProjectDetail(
               isProjectsDestination: true,
               hasSelectedProject: store.selectedProject != nil
           ) {
            store.selectProjects()
            return
        }

        guard case let .folder(project)? = selection,
              SidebarProjectSelectionPolicy.canOpen(isProject: project.isProject) else {
            store.selectedSidebarItem = selection
            return
        }

        store.openProject(project)
    }

    private func syncSidebarSelections(with selection: SidebarSelection?) {
        isSyncingSelection = true
        if let visibleSelection = visibleSelection(for: selection) {
            sidebarSelections = [visibleSelection]
        } else {
            sidebarSelections = []
        }
        isSyncingSelection = false
    }

    private func visibleSelection(for selection: SidebarSelection?) -> SidebarSelection? {
        if case .projects = selection,
           SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
               isProjectsDestination: true,
               hasSelectedProject: store.selectedProject != nil
           ),
           let project = store.selectedProject {
            return .folder(project)
        }

        switch selection {
        case .search, .projects, .smartCollection:
            return selection
        case .folder, .video, .none:
            return nil
        }
    }

    private func requestNewProject() {
        NotificationCenter.default.post(name: .triggerCreateFolder, object: nil)
    }

    private func beginProjectRename(_ project: Folder) {
        guard let projectID = project.id else { return }

        renamingProjectID = projectID
        editedProjectTitle = project.resolvedProjectTitle
        Task { @MainActor in
            await Task.yield()
            guard renamingProjectID == projectID else { return }
            focusedProjectID = projectID
        }
    }

    private func commitProjectRename(for project: Folder) async {
        guard let projectID = project.id,
              renamingProjectID == projectID else {
            return
        }

        let title = ProjectRenamePolicy.savedTitle(
            draft: editedProjectTitle,
            current: project.resolvedProjectTitle
        )
        cancelProjectRename()

        if let title {
            await store.renameItem(id: projectID, to: title)
        }
    }

    private func cancelProjectRename() {
        renamingProjectID = nil
        focusedProjectID = nil
        editedProjectTitle = ""
    }

    private func promptProjectDeletion(of project: Folder) {
        projectPendingDeletion = project
        showingProjectDeletionConfirmation = true
    }

    private func cancelProjectDeletion() {
        projectPendingDeletion = nil
        showingProjectDeletionConfirmation = false
    }

    private func confirmProjectDeletion() async {
        guard let projectID = projectPendingDeletion?.id else {
            cancelProjectDeletion()
            return
        }

        let deleted = await store.deleteItems([projectID])
        if deleted {
            if renamingProjectID == projectID {
                cancelProjectRename()
            }
            cancelProjectDeletion()
        }
    }
}
