import CoreData
import SwiftUI

struct ProjectThumbnailMembership: Equatable {
    let videoIDs: Set<NSManagedObjectID>
    let folderIDs: Set<NSManagedObjectID>

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
    static func reconcile(_ project: Folder) -> Bool {
        guard let context = project.managedObjectContext,
              !context.hasChanges else {
            return false
        }

        let resolvedVideoID = project.resolvedProjectThumbnailVideo?.id
        guard project.projectThumbnailVideoID != resolvedVideoID else { return false }

        project.projectThumbnailVideoID = resolvedVideoID
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
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

struct ProjectsGridView: View {
    @EnvironmentObject private var store: FolderNavigationStore

    private let projectSelectionAction: ((Folder) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 24, alignment: .top)
    ]

    private var projects: [Folder] {
        store.projects()
    }

    init(projectSelectionAction: ((Folder) -> Void)? = nil) {
        self.projectSelectionAction = projectSelectionAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Projects")
                    .font(.title2.weight(.semibold))

                if projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "square.grid.2x2",
                        description: Text("Create a project to organize sections and videos.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(projects, id: \.objectID) { project in
                            ProjectCard(project: project) {
                                if let projectSelectionAction {
                                    projectSelectionAction(project)
                                } else {
                                    store.openProject(project)
                                }
                            }
                            .accessibilityIdentifier("project-card-\(project.id?.uuidString ?? project.objectID.uriRepresentation().absoluteString)")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Projects")
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var store: FolderNavigationStore

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    @State private var showingHighlightsPlaceholder = false

    let project: Folder
    let showsPhoneToolbar: Bool
    let opensVideoOnSingleTap: Bool

    init(
        project: Folder,
        showsPhoneToolbar: Bool = false,
        opensVideoOnSingleTap: Bool = false
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
    }

    #if os(macOS)
    private var macProjectDetail: some View {
        List(selection: $store.selectedProjectVideoIDs) {
            macAlbumHero
                .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 28, trailing: 24))
                .listRowSeparator(.hidden)

            if sections.isEmpty {
                projectEmptyState
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24))
                    .listRowSeparator(.hidden)
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(Array(section.videos.enumerated()), id: \.element.objectID) { index, video in
                            if let videoID = video.id {
                                ProjectVideoRow(
                                    video: video,
                                    ordinal: index + 1,
                                    isSelected: false,
                                    showsSelectionAccessory: false,
                                    usesNativeListStyling: true,
                                    tapAction: nil
                                )
                                .tag(videoID)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                                .accessibilityIdentifier("project-video-row-\(videoID.uuidString)")
                            }
                        }
                    } header: {
                        ProjectAlbumSectionHeader(title: section.title)
                            .accessibilityIdentifier("project-section-\(section.id)")
                    }
                }

                ProjectAlbumFooter(
                    videoCount: totalVideoCount,
                    duration: formattedProjectDuration(totalDuration)
                )
                .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 28, trailing: 24))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .contextMenu(forSelectionType: UUID.self) { selection in
            if ProjectVideoSelectionPolicy.primaryActionID(
                selection: selection,
                visibleIDs: displayedVideoIDs
            ) != nil {
                Button("Open Video") {
                    _ = openProjectVideo(from: selection)
                }
            }
        } primaryAction: { selection in
            _ = openProjectVideo(from: selection)
        }
        .accessibilityIdentifier("project-video-list")
        .onChange(of: displayedVideoIDs) { _, visibleIDs in
            store.selectedProjectVideoIDs = ProjectVideoSelectionPolicy.reconciledSelection(
                store.selectedProjectVideoIDs,
                visibleIDs: visibleIDs
            )
        }
        .onKeyPress(.return) {
            openSelectedProjectVideo() ? .handled : .ignored
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

    private func openSelectedProjectVideo() -> Bool {
        guard let selectedID = ProjectVideoSelectionPolicy.activationID(
            selection: store.selectedProjectVideoIDs,
            visibleIDs: displayedVideoIDs
        ), let video = orderedDisplayedVideos.first(where: { $0.id == selectedID }) else {
            return false
        }

        store.openProjectVideo(video, in: project)
        return true
    }

    private func openProjectVideo(from selection: Set<UUID>) -> Bool {
        guard let selectedID = ProjectVideoSelectionPolicy.primaryActionID(
            selection: selection,
            visibleIDs: displayedVideoIDs
        ), let video = orderedDisplayedVideos.first(where: { $0.id == selectedID }) else {
            return false
        }

        store.openProjectVideo(video, in: project)
        return true
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
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private func isVideoSelected(_ video: Video) -> Bool {
        guard let videoID = video.id else { return false }
        return store.selectedProjectVideoIDs.contains(videoID)
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

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.resolvedProjectTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !project.resolvedProjectProvider.isEmpty {
                        Text(project.resolvedProjectProvider)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ProjectSyncedThumbnailImage(project: project, contentMode: .fill) {
            placeholderThumbnail
        }
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

    @State private var thumbnailRevision: UInt64 = 0
    @State private var membership: ProjectThumbnailMembership

    init(
        project: Folder,
        contentMode: ContentMode,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.project = project
        self.contentMode = contentMode
        self.placeholder = placeholder()
        _membership = State(initialValue: ProjectThumbnailMembership(project: project))
    }

    private var resolvedVideo: Video? {
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
            object: project.managedObjectContext
        )) { notification in
            guard let context = project.managedObjectContext,
                  let change = ProjectThumbnailChangePolicy.change(
                    for: notification,
                    in: context
                  ) else { return }

            let currentMembership = ProjectThumbnailMembership(project: project)
            let shouldRefresh = ProjectThumbnailChangePolicy.shouldRefresh(
                change: change,
                previous: membership,
                current: currentMembership
            )
            membership = currentMembership
            if shouldRefresh {
                thumbnailRevision &+= 1
            }
        }
        .task(id: thumbnailRevision) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            ProjectThumbnailReconciler.reconcile(project)
        }
    }
}

private struct ProjectSectionHeader: View {
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
