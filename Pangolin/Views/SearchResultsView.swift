//
//  SearchResultsView.swift
//  Pangolin
//
//  Created by Matt Kevan on 12/09/2025.
//

import SwiftUI
import CoreData

struct SearchResultsView: View {
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @State private var selectedItems = Set<UUID>()
    @State private var sortOrder: [KeyPathComparator<HierarchicalContentItem>] = []
    
    private var searchResultItems: [HierarchicalContentItem] {
        searchManager.searchResults.map { video in
            HierarchicalContentItem(video: video)
        }
    }
    
    var body: some View {
        Group {
            if searchManager.isSearching {
                // Show loading state
                VStack {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Searching...")
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Empty search state
                ContentUnavailableView(
                    "Search Your Videos",
                    systemImage: "magnifyingglass",
                    description: Text("Enter search terms and press Return to search videos, transcripts, and summaries")
                )
            } else if searchManager.searchResults.isEmpty {
                // No results state
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try different search terms or check your spelling")
                )
            } else {
                // Results table
                VStack(spacing: 0) {
                    // Results header
                    SearchResultsHeader(
                        resultCount: searchManager.searchResults.count,
                        query: searchManager.searchText,
                        scope: searchManager.searchScope
                    )
                    
                    // Results table
                    Table(searchResultItems, selection: $selectedItems, sortOrder: $sortOrder) {
                        TableColumn("Name", value: \.name) { item in
                            SearchResultNameCell(
                                item: item,
                                query: searchManager.searchText,
                                scope: searchManager.searchScope,
                                searchManager: searchManager
                            )
                        }
                        .width(min: 200, ideal: 300)
                        
                        TableColumn("Duration") { item in
                            if let video = item.video {
                                Text(video.formattedDuration)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .width(80)
                        
                        TableColumn("Played") { item in
                            if let video = item.video {
                                Image(systemName: video.playbackPosition > 0 ? "play.circle.fill" : "play.circle")
                                    .foregroundColor(video.playbackPosition > 0 ? .blue : .gray)
                                    .font(.system(size: 14))
                            }
                        }
                        .width(60)
                        
                        TableColumn("Favorite") { item in
                            if let video = item.video {
                                Button {
                                    Task {
                                        await toggleFavorite(video)
                                    }
                                } label: {
                                    Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                                        .foregroundColor(video.isFavorite ? .red : .gray)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .width(60)
                    }
                    #if os(macOS)
                    .alternatingRowBackgrounds()
                    #endif
                    .onChange(of: selectedItems) { _, newSelection in
                        handleSelectionChange(newSelection)
                    }
                    .onChange(of: sortOrder) { _, newSortOrder in
                        // Handle sort order changes if needed
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: searchManager.isSearching)
    }
    
    private func handleSelectionChange(_ selection: Set<UUID>) {
        // Update selected video for the player
        if let firstSelectedID = selection.first,
           let selectedVideo = searchManager.searchResults.first(where: { $0.id == firstSelectedID }) {
            folderStore.selectedVideo = selectedVideo
        }
    }
    
    private func toggleFavorite(_ video: Video) async {
        guard let context = video.managedObjectContext else { return }
        
        await context.perform {
            video.isFavorite.toggle()
            do {
                try context.save()
            } catch {
                print("Error toggling favorite: \(error)")
            }
        }
    }
}

// MARK: - Search Results Header
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
            
            // Search scope indicator
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

// MARK: - Search Result Name Cell
private struct SearchResultNameCell: View {
    let item: HierarchicalContentItem
    let query: String
    let scope: SearchManager.SearchScope
    let searchManager: SearchManager
    
    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let video = item.video {
                VideoThumbnailView(
                    video: video,
                    size: CGSize(width: 40, height: 30)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                // Title with highlighting
                if let video = item.video, let title = video.title {
                    Text(searchManager.highlightedText(for: title, query: query))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                } else {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                
                // Context snippet for transcript/summary matches
                if let video = item.video, !query.isEmpty {
                    contextSnippetView(for: video)
                }
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private func contextSnippetView(for video: Video) -> some View {
        let snippetText = getContextSnippet(for: video)
        if !snippetText.isEmpty {
            Text(searchManager.highlightedText(for: snippetText, query: query))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }
    
    private func getContextSnippet(for video: Video) -> String {
        switch scope {
        case .all:
            // Check transcript first, then summary
            if let transcript = video.transcriptText, !transcript.isEmpty,
               transcript.localizedCaseInsensitiveContains(query) {
                return searchManager.getContextSnippet(for: transcript, query: query)
            } else if let summary = video.transcriptSummary, !summary.isEmpty,
                      summary.localizedCaseInsensitiveContains(query) {
                return searchManager.getContextSnippet(for: summary, query: query)
            }
        case .transcripts:
            if let transcript = video.transcriptText, !transcript.isEmpty {
                return searchManager.getContextSnippet(for: transcript, query: query)
            }
        case .summaries:
            if let summary = video.transcriptSummary, !summary.isEmpty {
                return searchManager.getContextSnippet(for: summary, query: query)
            }
        case .titles:
            // No context snippet needed for titles
            break
        }
        return ""
    }
}

#Preview {
    SearchResultsView()
        .environmentObject(SearchManager())
        .environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))
}