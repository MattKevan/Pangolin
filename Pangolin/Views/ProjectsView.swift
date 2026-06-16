import SwiftUI
#if os(macOS)
import AppKit
#endif

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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroContent(isCompact: false)

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
                                        showsSelectionAccessory: false,
                                        tapAction: {
                                            handleMacSelection(for: video)
                                        },
                                        doubleClickAction: {
                                            store.openProjectVideo(video, in: project)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(project.resolvedProjectTitle)
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
                                },
                                doubleClickAction: nil
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
        Group {
            if let thumbnailURL = project.projectThumbnailURL,
               FileManager.default.fileExists(atPath: thumbnailURL.path) {
                AsyncImage(url: thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderThumbnail(cornerRadius: cornerRadius)
                }
            } else {
                placeholderThumbnail(cornerRadius: cornerRadius)
            }
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

    #if os(macOS)
    private func handleMacSelection(for video: Video) {
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
        let extendingSelection = modifierFlags.contains(.command)
        let rangeSelecting = modifierFlags.contains(.shift)
        store.selectProjectVideo(
            video,
            in: orderedDisplayedVideos,
            extendingSelection: extendingSelection,
            rangeSelecting: rangeSelecting
        )
    }
    #endif

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
        if let thumbnailURL = project.projectThumbnailURL,
           FileManager.default.fileExists(atPath: thumbnailURL.path) {
            AsyncImage(url: thumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderThumbnail
            }
        } else {
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

private struct ProjectVideoRow: View {
    let video: Video
    let ordinal: Int
    let isSelected: Bool
    let showsSelectionAccessory: Bool
    let tapAction: () -> Void
    let doubleClickAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
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

                if showsSelectionAccessory {
                    Button(action: tapAction) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: toggleFavorite) {
                    Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(video.isFavorite ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 24)

                Text(video.formattedDuration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)

                Menu {
                    Button(video.isFavorite ? "Remove favourite" : "Add favourite", systemImage: video.isFavorite ? "heart.slash" : "heart") {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                tapAction()
            }
            .onTapGesture(count: 2) {
                doubleClickAction?()
            }

            Divider()
                .padding(.leading, 44)
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
