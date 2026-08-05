//
//  SearchResultsView.swift
//  Pangolin
//
//  Created by Matt Kevan on 12/09/2025.
//

import Foundation
import SwiftUI

enum SearchVideoSelectionResetPolicy {
    static func shouldClearRowSelection(selectedVideoID: UUID?) -> Bool {
        selectedVideoID == nil
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var searchManager: SearchManager
    @Environment(FolderNavigationStore.self) private var folderStore
    @State private var selectedItems = Set<UUID>()

    private var trimmedQuery: String {
        searchManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchTextEmpty: Bool {
        trimmedQuery.isEmpty
    }

    private var hasResults: Bool {
        !searchManager.presentedResults.isEmpty
    }

    var body: some View {
        Group {
            if isSearchTextEmpty {
                EmptySearchStateView()
            } else {
                ZStack {
                    VStack(spacing: 0) {
                        SearchResultsTableView(
                            rows: searchManager.presentedResults,
                            selectedItems: $selectedItems,
                            searchManager: searchManager,
                            folderStore: folderStore,
                            isSearching: searchManager.isSearching
                        )
                    }

                    if searchManager.isSearching && !hasResults {
                        LoadingStateView()
                    } else if shouldShowMinimumCharactersHint {
                        SearchHintStateView(
                            title: "Keep typing",
                            systemImage: "text.cursor",
                            description: "Type at least 2 characters to search"
                        )
                    } else if searchManager.hasSearched && !hasResults {
                        NoResultsStateView(scope: searchManager.searchScope)
                    }
                }
            }
        }
        .onChange(of: searchManager.searchText) { _, _ in
            selectedItems.removeAll()
        }
        .onChange(of: searchManager.searchScope) { _, _ in
            selectedItems.removeAll()
        }
        .onChange(of: folderStore.selectedVideo?.id) { _, newValue in
            guard SearchVideoSelectionResetPolicy.shouldClearRowSelection(
                selectedVideoID: newValue
            ) else { return }
            selectedItems.removeAll()
        }
    }

    private var shouldShowMinimumCharactersHint: Bool {
        !trimmedQuery.isEmpty && trimmedQuery.count < 2 && !searchManager.isSearching
    }
}

private struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)
            Text("Searching...")
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .pangolinGlassRoundedRect(cornerRadius: 24, interactive: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptySearchStateView: View {
    var body: some View {
        ContentUnavailableView(
            "Search your videos",
            systemImage: "magnifyingglass",
            description: Text("Enter search terms to search videos, transcripts, translations, and summaries")
        )
    }
}

private struct SearchHintStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
    }
}

private struct NoResultsStateView: View {
    let scope: SearchManager.SearchScope

    var body: some View {
        ContentUnavailableView(
            "No results",
            systemImage: "magnifyingglass",
            description: Text("No \(scope.rawValue.lowercased()) matches found. Try a different phrase or scope.")
        )
    }
}

private struct SearchResultsTableView: View {
    let rows: [SearchResultRowModel]
    @Binding var selectedItems: Set<UUID>
    @ObservedObject var searchManager: SearchManager
    let folderStore: FolderNavigationStore
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchResultsHeader(
                resultCount: rows.count,
                query: searchManager.searchText,
                scope: $searchManager.searchScope,
                isSearching: isSearching
            )

            Table(rows, selection: $selectedItems) {
                TableColumn("Title") { row in
                    SearchResultTitleCell(row: row)
                }
                .width(min: 240, ideal: 320)

                TableColumn("Best match") { row in
                    SearchResultSnippetCell(
                        row: row,
                        query: searchManager.searchText,
                        searchManager: searchManager
                    )
                }
                .width(min: 480, ideal: 800)

                
            }
            #if os(macOS)
            .alternatingRowBackgrounds(.enabled)
            #endif
            .onChange(of: selectedItems) { _, newSelection in
                handleSelectionChange(newSelection)
            }
        }
    }

    private func handleSelectionChange(_ selection: Set<UUID>) {
        guard selection.count == 1,
              let selectedID = selection.first,
              let selectedRow = rows.first(where: { $0.id == selectedID }) else { return }

        folderStore.pendingSearchSeekRequest = nil
        if selectedRow.video.folder != nil {
            folderStore.revealVideoLocation(selectedRow.video)
        } else {
            folderStore.openVideoDetailWithoutLocation(selectedRow.video)
        }
    }
}

private struct SearchResultsHeader: View {
    let resultCount: Int
    let query: String
    @Binding var scope: SearchManager.SearchScope
    let isSearching: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(resultCount) \(resultCount == 1 ? "result" : "results")")
                    .font(.headline)

                if !query.isEmpty {
                    Text("for \"\(query)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Picker("Source", selection: $scope) {
                    ForEach(SearchManager.SearchScope.allCases) { scope in
                        Text(scope == .all ? "All Sources" : scope.rawValue)
                            .tag(scope)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scope == .all ? "All Sources" : scope.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundColor(.secondary)
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

private struct SearchResultTitleCell: View {
    let row: SearchResultRowModel

    var body: some View {
        HStack(spacing: 8) {
            VideoThumbnailView(
                video: row.video,
                size: CGSize(width: 40, height: 28),
                showsDurationOverlay: false,
                showsCloudStatusOverlay: false
            )
            .frame(width: 40, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                if row.citations.count > 1 {
                    Text("\(row.citations.count) citations")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct SearchResultSnippetCell: View {
    let row: SearchResultRowModel
    let query: String
    let searchManager: SearchManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(searchManager.highlightedText(for: row.snippet, query: query))
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SearchResultsView()
        .environmentObject(SearchManager())
        .environment(FolderNavigationStore(libraryManager: LibraryManager.shared))
        .environmentObject(VideoFileManager.shared)
}
