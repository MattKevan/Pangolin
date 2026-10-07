//
//  ProjectsListView.swift
//  Pangolin
//

import SwiftUI

/// The list of projects: a thumbnail, the title, the provider and how much is in each.
/// This is the iPhone's root page; Mac and iPad list their projects in the sidebar instead.
struct ProjectsListView: View {
    @Environment(FolderNavigationStore.self) private var store
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager

    let onOpen: (Folder) -> Void

    @State private var projectBeingRenamed: Folder?
    @State private var editedTitle = ""
    @State private var projectPendingDeletion: Folder?

    private var projects: [Folder] {
        _ = store.contentRevision
        return store.projects()
    }

    var body: some View {
        Group {
            if projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "square.grid.2x2",
                    description: Text("Create a project to organize sections and videos.")
                )
            } else {
                List(projects, id: \.objectID) { project in
                    Button {
                        onOpen(project)
                    } label: {
                        ProjectListRow(project: project, summary: summary(for: project))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project-row-\(project.id?.uuidString ?? project.objectID.uriRepresentation().absoluteString)")
                    .contextMenu {
                        rowActions(for: project)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            projectPendingDeletion = project
                        }
                        Button("Rename", systemImage: "pencil") {
                            beginRenaming(project)
                        }
                        .tint(.accentColor)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Projects")
        .projectFolderDrop(
            isEnabled: libraryManager.currentLibrary != nil,
            libraryManager: libraryManager
        )
        .alert("Rename Project", isPresented: isRenaming) {
            TextField("Project name", text: $editedTitle)
            Button("Cancel", role: .cancel) {
                projectBeingRenamed = nil
            }
            Button("Rename") {
                Task { await commitRename() }
            }
        }
        .alert("Delete Project?", isPresented: isConfirmingDeletion) {
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                Task { await confirmDeletion() }
            }
        } message: {
            Text("This project and all its contents will be permanently deleted from your library and removed from disk. This action cannot be undone.")
        }
    }

    @ViewBuilder
    private func rowActions(for project: Folder) -> some View {
        Button("Open", systemImage: "arrow.up.right") { onOpen(project) }
        Button("Rename", systemImage: "pencil") { beginRenaming(project) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            projectPendingDeletion = project
        }
    }

    private func summary(for project: Folder) -> String {
        ProjectSummary.stats(
            videoCount: store.projectVideos(in: project).count,
            duration: store.totalDuration(for: project)
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { projectBeingRenamed != nil }, set: { if !$0 { projectBeingRenamed = nil } })
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { projectPendingDeletion != nil }, set: { if !$0 { projectPendingDeletion = nil } })
    }

    private func beginRenaming(_ project: Folder) {
        editedTitle = project.resolvedProjectTitle
        projectBeingRenamed = project
    }

    private func commitRename() async {
        guard let project = projectBeingRenamed, let projectID = project.id else { return }
        projectBeingRenamed = nil

        if let title = ProjectRenamePolicy.savedTitle(
            draft: editedTitle,
            current: project.resolvedProjectTitle
        ) {
            await store.renameItem(id: projectID, to: title)
        }
    }

    private func confirmDeletion() async {
        guard let projectID = projectPendingDeletion?.id else {
            projectPendingDeletion = nil
            return
        }
        projectPendingDeletion = nil

        if await store.deleteItems([projectID]), store.lastSelectedProjectID == projectID {
            store.lastSelectedProjectID = nil
        }
    }
}

private struct ProjectListRow: View {
    @ObservedObject var project: Folder
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            ProjectSyncedThumbnailImage(project: project, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(project.resolvedProjectTitle)
                    .font(.headline)
                    .lineLimit(1)

                if !project.resolvedProjectProvider.isEmpty {
                    Text(project.resolvedProjectProvider)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}
