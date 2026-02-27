//
//  SearchResultsView.swift
//  Pangolin
//
//  Created by Matt Kevan on 12/09/2025.
//

import Foundation
import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var folderStore: FolderNavigationStore
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
                            isSearching: searchManager.isSearching,
                            onSelectCitation: handleCitationSelection
                        )
                    }

                    if searchManager.isSearching && !hasResults {
                        LoadingStateView()
                            .background(.regularMaterial)
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
    }

    private var shouldShowMinimumCharactersHint: Bool {
        !trimmedQuery.isEmpty && trimmedQuery.count < 2 && !searchManager.isSearching
    }

    private func handleCitationSelection(_ citation: SearchCitation) {
        guard let row = searchManager.presentedResults.first(where: { $0.id == citation.videoID }) else { return }
        folderStore.openFromSearchCitation(row.video, seekTo: citation.timestampStart, source: citation.source)
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

private struct SearchAnswerPanel: View {
    let model: SearchAnswerPanelModel
    let query: String
    let searchManager: SearchManager
    let onSelectCitation: (SearchCitation) -> Void

    var body: some View {
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search Summary")
                        .font(.headline)
                    Text("Based on \(model.scopeLabel) results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundColor(.accentColor)
            }

            Text(model.summaryText)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.citations) { citation in
                    Button {
                        onSelectCitation(citation)
                    } label: {
                        SearchCitationRowView(
                            citation: citation,
                            query: query,
                            searchManager: searchManager
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct SearchCitationRowView: View {
    let citation: SearchCitation
    let query: String
    let searchManager: SearchManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(citation.videoTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text("·")
                    .foregroundColor(.secondary)

                Text(citationSourceLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let timeLabel = formattedTimeRange(start: citation.timestampStart, end: citation.timestampEnd) {
                    Text("· \(timeLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text(searchManager.highlightedText(for: citation.snippet, query: query))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var citationSourceLabel: String {
        if citation.source == .translation, let languageCode = citation.languageCode {
            return "Translation (\(languageCode.uppercased()))"
        }
        return citation.source.displayName
    }
}

private struct SearchResultsTableView: View {
    let rows: [SearchResultRowModel]
    @Binding var selectedItems: Set<UUID>
    @ObservedObject var searchManager: SearchManager
    let folderStore: FolderNavigationStore
    let isSearching: Bool
    let onSelectCitation: (SearchCitation) -> Void

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
                        searchManager: searchManager,
                        onSelectCitation: onSelectCitation
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

    private func toggleFavorite(_ video: Video) {
        guard let context = video.managedObjectContext else { return }
        context.perform {
            video.isFavorite.toggle()
            do {
                try context.save()
            } catch {
                print("Error toggling favorite from search results: \(error)")
            }
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
    let onSelectCitation: (SearchCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(searchManager.highlightedText(for: row.snippet, query: query))
                .lineLimit(3)

            

            
        }
        .padding(.vertical, 2)
    }

    private var bestSourceLabel: String {
        if row.bestSource == .translation,
           let languageCode = row.citations.first(where: { $0.source == .translation })?.languageCode {
            return "Translation (\(languageCode.uppercased()))"
        }
        return row.bestSource.displayName
    }
}

private func formattedTimeRange(start: TimeInterval?, end: TimeInterval?) -> String? {
    guard let start else { return nil }
    let startLabel = formattedTimestamp(start)
    guard let end else { return startLabel }
    let normalizedEnd = max(end, start)
    if abs(normalizedEnd - start) < 0.25 {
        return startLabel
    }
    return "\(startLabel)-\(formattedTimestamp(normalizedEnd))"
}

private func formattedTimestamp(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

#Preview {
    SearchResultsView()
        .environmentObject(SearchManager())
        .environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))
        .environmentObject(VideoFileManager.shared)
}
