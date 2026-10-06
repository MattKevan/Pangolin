//
//  ProjectVideoList.swift
//  Pangolin
//

import SwiftUI

/// A project's videos as a numbered list grouped by section, under a header that scrolls with it.
struct ProjectVideoList<Header: View>: View {
    let sections: [ProjectSectionSnapshot]
    @Binding var selection: Set<UUID>
    let header: Header
    let onOpen: (Video) -> Void
    let onEdit: (Video) -> Void
    let onDelete: (Video) -> Void
    let onToggleFavorite: (Video) -> Void

    #if os(iOS)
    @Environment(\.editMode) private var editMode
    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }
    #endif

    init(
        sections: [ProjectSectionSnapshot],
        selection: Binding<Set<UUID>>,
        onOpen: @escaping (Video) -> Void,
        onEdit: @escaping (Video) -> Void,
        onDelete: @escaping (Video) -> Void,
        onToggleFavorite: @escaping (Video) -> Void,
        @ViewBuilder header: () -> Header
    ) {
        self.sections = sections
        self._selection = selection
        self.onOpen = onOpen
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onToggleFavorite = onToggleFavorite
        self.header = header()
    }

    private var videosByID: [UUID: Video] {
        sections.flatMap(\.videos).reduce(into: [:]) { result, video in
            if let id = video.id, result[id] == nil {
                result[id] = video
            }
        }
    }

    var body: some View {
        List(selection: $selection) {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()

            ForEach(sections) { section in
                Section {
                    ForEach(Array(section.videos.enumerated()), id: \.element.objectID) { index, video in
                        if let id = video.id {
                            row(for: video, number: index + 1)
                                .tag(id)
                        }
                    }
                } header: {
                    SectionTitle(title: section.title)
                }
            }
        }
        .listStyle(.plain)
        #if os(macOS)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            guard VideoTableInteractionPolicy.shouldOpen(selectionCount: ids.count),
                  let id = ids.first, let video = videosByID[id] else { return }
            onOpen(video)
        }
        #else
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        }
        #endif
    }

    @ViewBuilder
    private func row(for video: Video, number: Int) -> some View {
        let content = ProjectVideoRow(
            video: video,
            number: number,
            onOpen: { onOpen(video) },
            onEdit: { onEdit(video) },
            onDelete: { onDelete(video) },
            onToggleFavorite: { onToggleFavorite(video) }
        )
        #if os(iOS)
        // In editing mode a tap selects; otherwise it opens the video.
        if isEditing {
            content
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture { onOpen(video) }
        }
        #else
        content
        #endif
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first, let video = videosByID[id] {
            Button("Open Video") { onOpen(video) }
            Button(
                video.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: video.isFavorite ? "heart.slash" : "heart"
            ) { onToggleFavorite(video) }
            Button("Edit Video") { onEdit(video) }
            Divider()
            Button("Delete Video", role: .destructive) { onDelete(video) }
        } else if ids.count > 1 {
            Text("\(ids.count) Videos Selected")
        }
    }

    private struct SectionTitle: View {
        let title: String

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Divider()
            }
            .padding(.top, 12)
            .textCase(nil)
        }
    }
}
