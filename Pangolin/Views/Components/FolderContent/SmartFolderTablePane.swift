import SwiftUI

struct SmartCollectionTablePane: View {
    let title: String
    let videos: [Video]
    let selectedVideo: Video?
    let onSelectVideo: (Video) -> Void

    @State private var selectedVideoIDs: Set<UUID> = []
    @State private var suppressedProgrammaticSelection: Set<UUID>?

    var body: some View {
        VStack(spacing: 0) {
            SmartCollectionHeader(title: title)

            Group {
                if videos.isEmpty {
                    ContentUnavailableView(
                        "No videos",
                        systemImage: "video",
                        description: Text("No videos found in this collection.")
                    )
                } else {
                    VideoResultsTableView(
                        videos: videos,
                        selectedVideoIDs: $selectedVideoIDs,
                        onSelectionChange: handleSelectionChange
                    )
                    .onAppear(perform: syncSelectedVideoForTable)
                    .onChange(of: selectedVideo?.id) { _, _ in
                        syncSelectedVideoForTable()
                    }
                    .onChange(of: videos.compactMap(\.id)) { _, _ in
                        syncSelectedVideoForTable()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSelectionChange(_ selection: Set<UUID>) {
        if suppressedProgrammaticSelection == selection {
            suppressedProgrammaticSelection = nil
            return
        }

        guard selection.count == 1,
              let selectedID = selection.first,
              let selected = videos.first(where: { $0.id == selectedID }) else {
            return
        }

        onSelectVideo(selected)
    }

    private func syncSelectedVideoForTable() {
        let nextSelection: Set<UUID>
        let availableIDs = Set(videos.compactMap(\.id))
        if let selectedID = selectedVideo?.id, availableIDs.contains(selectedID) {
            nextSelection = [selectedID]
        } else {
            nextSelection = []
        }

        guard selectedVideoIDs != nextSelection else { return }

        suppressedProgrammaticSelection = nextSelection
        selectedVideoIDs = nextSelection

        // Clear the suppression token if the table does not emit a matching onChange callback.
        DispatchQueue.main.async {
            if suppressedProgrammaticSelection == nextSelection {
                suppressedProgrammaticSelection = nil
            }
        }
    }
}

private struct SmartCollectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(backgroundMaterial)
        .overlay(
            Rectangle()
                .fill(separatorColor)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var backgroundMaterial: some View {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    private var separatorColor: Color {
        #if os(macOS)
        Color(NSColor.separatorColor)
        #else
        Color(.separator)
        #endif
    }
}
