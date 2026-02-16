import SwiftUI

struct SmartFolderTablePane: View {
    let title: String
    let videos: [Video]
    let selectedVideo: Video?
    let onSelectVideo: (Video) -> Void

    @State private var selectedVideoIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            SmartFolderHeader(title: title)

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
        guard selection.count == 1,
              let selectedID = selection.first,
              let selected = videos.first(where: { $0.id == selectedID }) else {
            return
        }

        onSelectVideo(selected)
    }

    private func syncSelectedVideoForTable() {
        let availableIDs = Set(videos.compactMap(\.id))
        if let selectedID = selectedVideo?.id, availableIDs.contains(selectedID) {
            selectedVideoIDs = [selectedID]
        } else {
            selectedVideoIDs = []
        }
    }
}

private struct SmartFolderHeader: View {
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
