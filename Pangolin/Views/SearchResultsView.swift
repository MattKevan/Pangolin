//
//  SearchResultsView.swift
//  Pangolin
//
//  Created by Matt Kevan on 12/09/2025.
//

import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @State private var selectedItems = Set<UUID>()

    private var isSearchTextEmpty: Bool {
        searchManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasResults: Bool {
        !searchManager.searchResults.isEmpty
    }

    var body: some View {
        Group {
            if searchManager.isSearching {
                LoadingStateView()
            } else if isSearchTextEmpty {
                EmptySearchStateView()
            } else if !hasResults {
                NoResultsStateView()
            } else {
                SearchResultsTableView(
                    videos: searchManager.searchResults,
                    selectedItems: $selectedItems,
                    searchManager: searchManager,
                    folderStore: folderStore
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: searchManager.isSearching)
    }
}

private struct LoadingStateView: View {
    var body: some View {
        VStack {
            ProgressView()
                .controlSize(.regular)
            Text("Searching...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptySearchStateView: View {
    var body: some View {
        ContentUnavailableView(
            "Search Your Videos",
            systemImage: "magnifyingglass",
            description: Text("Enter search terms to search videos, transcripts, and summaries")
        )
    }
}

private struct NoResultsStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("Try different search terms or check your spelling")
        )
    }
}

private struct SearchResultsTableView: View {
    let videos: [Video]
    @Binding var selectedItems: Set<UUID>
    let searchManager: SearchManager
    let folderStore: FolderNavigationStore

    var body: some View {
        VStack(spacing: 0) {
            SearchResultsHeader(
                resultCount: videos.count,
                query: searchManager.searchText,
                scope: searchManager.searchScope
            )

            VideoResultsTableView(
                videos: videos,
                selectedVideoIDs: $selectedItems,
                onSelectionChange: handleSelectionChange
            )
        }
    }

    private func handleSelectionChange(_ selection: Set<UUID>) {
        guard selection.count == 1,
              let selectedID = selection.first else { return }
        if let selectedVideo = videos.first(where: { $0.id == selectedID }) {
            guard selectedVideo.folder != nil else {
                folderStore.selectVideo(selectedVideo)
                return
            }

            folderStore.revealVideoLocation(selectedVideo)
        }
    }
}

private struct SearchResultsHeader: View {
    let resultCount: Int
    let query: String
    let scope: SearchManager.SearchScope
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(resultCount) \(resultCount == 1 ? "result" : "results")")
                    .font(.headline)
                
                if !query.isEmpty {
                    Text("for \"\(query)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if scope != .all {
                Text("in \(scope.rawValue)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

#Preview {
    SearchResultsView()
        .environmentObject(SearchManager())
        .environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))
        .environmentObject(VideoFileManager.shared)
}
