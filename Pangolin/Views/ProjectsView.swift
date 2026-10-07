import CoreData
import SwiftUI
#if os(macOS)
import AppKit
#endif


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
                            .padding(.horizontal, ProjectPageLayout.contentPadding)
                            .padding(.top, ProjectPageLayout.contentPadding)
                            .padding(.bottom, 28)

                        projectEmptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .padding(.horizontal, ProjectPageLayout.contentPadding)
                            .padding(.bottom, ProjectPageLayout.contentPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProjectVideoList(
                    sections: sections,
                    selection: $store.selectedProjectVideoIDs,
                    onOpen: { store.openProjectVideo($0, in: project) },
                    onEdit: { editingVideo = $0 },
                    onDelete: promptVideoDeletion,
                    onToggleFavorite: toggleFavorite
                ) {
                    macAlbumHero
                        .padding(ProjectPageLayout.contentPadding)
                        .background(.quaternary.opacity(0.4))
                }
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
                            .padding(.horizontal, ProjectPageLayout.contentPadding)
                            .padding(.top, ProjectPageLayout.contentPadding)
                            .padding(.bottom, 28)

                        projectEmptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .padding(.horizontal, ProjectPageLayout.contentPadding)
                            .padding(.bottom, ProjectPageLayout.contentPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProjectVideoList(
                    sections: sections,
                    selection: $store.selectedProjectVideoIDs,
                    onOpen: { store.openProjectVideo($0, in: project) },
                    onEdit: { editingVideo = $0 },
                    onDelete: promptVideoDeletion,
                    onToggleFavorite: toggleFavorite
                ) {
                    heroContent(isCompact: isCompact)
                        .padding(ProjectPageLayout.contentPadding)
                        .background(.quaternary.opacity(0.4))
                }
                .accessibilityIdentifier("project-video-collection")
            }
        }
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
        ProjectSummary.stats(videoCount: totalVideoCount, duration: totalDuration)
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
            .buttonStyle(.glassProminent)
            .disabled(continueWatchingVideo == nil)

            Button("Highlights") {
                showingHighlightsPlaceholder = true
            }
            .buttonStyle(.glass)
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
