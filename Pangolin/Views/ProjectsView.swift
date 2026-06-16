import SwiftUI

struct ProjectsGridView: View {
    @EnvironmentObject private var store: FolderNavigationStore

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 24, alignment: .top)
    ]

    private var projects: [Folder] {
        store.projects()
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
                                store.openProject(project)
                            }
                            .accessibilityIdentifier("project-card-\(project.id?.uuidString ?? project.objectID.uriRepresentation().absoluteString)")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

struct ProjectDetailPlaceholderView: View {
    @EnvironmentObject private var store: FolderNavigationStore

    private var project: Folder? {
        store.selectedProject
    }

    var body: some View {
        Group {
            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        hero(project: project)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Sections")
                                .font(.headline)

                            if project.sectionsArray.isEmpty {
                                Text("This project does not have any sections yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(project.sectionsArray, id: \.objectID) { section in
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(section.name ?? "Untitled Section")
                                        Spacer()
                                        Text("\(section.totalVideoCount) videos")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        }

                        ContentUnavailableView(
                            "Project detail coming next",
                            systemImage: "hammer",
                            description: Text("This placeholder route confirms project navigation while the full sections view is being designed.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No project selected",
                    systemImage: "square.grid.2x2",
                    description: Text("Choose a project from the grid.")
                )
            }
        }
    }

    @ViewBuilder
    private func hero(project: Folder) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let thumbnailURL = project.projectThumbnailURL,
                   FileManager.default.fileExists(atPath: thumbnailURL.path) {
                    AsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay {
                            Image(systemName: "play.rectangle.on.rectangle")
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(project.resolvedProjectTitle)
                    .font(.largeTitle.weight(.bold))

                if !project.resolvedProjectProvider.isEmpty {
                    Text(project.resolvedProjectProvider)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Label("\(project.sectionsArray.count) sections", systemImage: "folder")
                    .foregroundStyle(.secondary)

                Label("\(project.totalVideoCount) videos", systemImage: "video")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("project-detail-placeholder")
    }
}
