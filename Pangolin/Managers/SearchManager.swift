//
//  SearchManager.swift
//  Pangolin
//
//  Created by Matt Kevan on 12/09/2025.
//

import Foundation
import CoreData
import SwiftUI
import Combine

@MainActor
class SearchManager: ObservableObject {
    @Published var searchText = ""
    @Published var isSearchActive = false
    @Published var searchResults: [Video] = []
    @Published var searchScope: SearchScope = .all
    @Published var isSearching = false
    @Published var hasSearched = false // Track if search has been performed

    // Improved search configuration
    private var searchTask: Task<Void, Never>?
    private var searchRequestID: UInt64 = 0
    private let debounceDelay: TimeInterval = 0.5  // Increased for better performance
    private let minimumQueryLength = 2  // Don't search until 2+ characters
    
    enum SearchScope: String, CaseIterable, Identifiable {
        case all = "All"
        case titles = "Titles"
        case transcripts = "Transcripts"
        case summaries = "Summaries"
        
        var id: String { rawValue }
        
        var systemImage: String {
            switch self {
            case .all: return "magnifyingglass"
            case .titles: return "textformat"
            case .transcripts: return "doc.text"
            case .summaries: return "doc.text.below.ecg"
            }
        }
    }
    
    init() {
        // Apple-recommended approach: immediate response with proper task-based debouncing
        $searchText
            .removeDuplicates()
            .sink { [weak self] newText in
                self?.scheduleSearch(query: newText)
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()

    private func resetSearchState(results: [Video] = [], isSearching: Bool = false, hasSearched: Bool = false) {
        if results.isEmpty {
            if !self.searchResults.isEmpty {
                self.searchResults = []
            }
        } else {
            self.searchResults = results
        }

        if self.isSearching != isSearching {
            self.isSearching = isSearching
        }

        if self.hasSearched != hasSearched {
            self.hasSearched = hasSearched
        }
    }
    
    private func scheduleSearch(query: String) {
        // Cancel any existing search task
        searchTask?.cancel()
        searchRequestID &+= 1
        let requestID = searchRequestID

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle empty queries immediately
        if trimmedQuery.isEmpty {
            Task { @MainActor in
                resetSearchState()
            }
            return
        }

        // Don't search until minimum length reached
        if trimmedQuery.count < minimumQueryLength {
            Task { @MainActor in
                resetSearchState()
            }
            return
        }

        // Clear stale results immediately when the query changes, then fetch new ones after debounce.
        if !searchResults.isEmpty {
            searchResults = []
        }
        if hasSearched {
            hasSearched = false
        }
        if isSearching {
            isSearching = false
        }

        // Create new search task with proper cancellation
        searchTask = Task { @MainActor [weak self] in
            do {
                // Wait for debounce period
                try await Task.sleep(for: .milliseconds(Int(self?.debounceDelay ?? 0.5 * 1000)))

                // Check if cancelled during sleep
                guard !Task.isCancelled,
                      self?.searchRequestID == requestID else {
                    return
                }

                if self?.isSearching != true {
                    self?.isSearching = true
                }

                // Perform the actual search
                await self?.performSearch(query: trimmedQuery, requestID: requestID)
            } catch {
                // Task was cancelled
                await MainActor.run {
                    guard self?.searchRequestID == requestID else { return }
                    if self?.isSearching == true {
                        self?.isSearching = false
                    }
                }
            }
        }
    }
    
    private func performSearch(query: String, requestID: UInt64? = nil) async {
        guard let context = LibraryManager.shared.viewContext,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetSearchState()
            return
        }

        do {
            let results = try await searchVideos(query: query, in: context)
            if let requestID, requestID != searchRequestID {
                return
            }
            searchResults = results
            hasSearched = true
        } catch {
            if let requestID, requestID != searchRequestID {
                return
            }
            print("Search error: \(error)")
            searchResults = []
            hasSearched = true
        }

        if let requestID, requestID != searchRequestID {
            return
        }
        if isSearching {
            isSearching = false
        }
    }
    
    private func searchVideos(query: String, in context: NSManagedObjectContext) async throws -> [Video] {
        let currentScope = searchScope
        
        return try await withCheckedThrowingContinuation { continuation in
            context.perform { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                
                do {
                    let request: NSFetchRequest<Video> = Video.fetchRequest()
                    let predicate = self.buildSearchPredicate(query: query, scope: currentScope)
                    request.predicate = predicate
                    request.sortDescriptors = [
                        NSSortDescriptor(keyPath: \Video.title, ascending: true)
                    ]
                    request.fetchLimit = 100 // Limit results for performance
                    
                    let results = try context.fetch(request)
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    nonisolated private func buildSearchPredicate(query: String, scope: SearchScope) -> NSPredicate {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch scope {
        case .all:
            return NSPredicate(format:
                "title CONTAINS[cd] %@ OR " +
                "fileName CONTAINS[cd] %@ OR " +
                "transcriptText CONTAINS[cd] %@ OR " +
                "transcriptSummary CONTAINS[cd] %@",
                trimmedQuery, trimmedQuery, trimmedQuery, trimmedQuery
            )
        case .titles:
            return NSPredicate(format:
                "title CONTAINS[cd] %@ OR fileName CONTAINS[cd] %@",
                trimmedQuery, trimmedQuery
            )
        case .transcripts:
            return NSPredicate(format:
                "transcriptText CONTAINS[cd] %@",
                trimmedQuery
            )
        case .summaries:
            return NSPredicate(format:
                "transcriptSummary CONTAINS[cd] %@",
                trimmedQuery
            )
        }
    }
    
    func clearSearch() {
        searchTask?.cancel()
        Task { @MainActor in
            searchRequestID &+= 1
            if !searchText.isEmpty {
                searchText = ""
            }
            resetSearchState()
            if isSearchActive {
                isSearchActive = false
            }
        }
    }
    
    func activateSearch() {
        Task { @MainActor in
            isSearchActive = true
        }
    }

    func deactivateSearch() {
        Task { @MainActor in
            isSearchActive = false
        }
        clearSearch()
    }
    
    // Manual search trigger (called on Return key press)
    func performManualSearch() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        // Cancel any existing search and perform immediately
        searchTask?.cancel()
        searchRequestID &+= 1
        let requestID = searchRequestID
        Task { @MainActor in
            if !isSearching {
                isSearching = true
            }
            await performSearch(query: trimmedQuery, requestID: requestID)
        }
    }
    
    // Get highlighted text for search results
    func highlightedText(for text: String, query: String) -> AttributedString {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AttributedString(text)
        }
        
        var attributedString = AttributedString(text)
        let range = text.range(of: query, options: [.caseInsensitive])
        
        if let range = range {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            
            if let attributedRange = Range(NSRange(location: start, length: length), in: attributedString) {
                attributedString[attributedRange].font = .system(.body, design: .default, weight: .bold)
                attributedString[attributedRange].backgroundColor = .yellow.opacity(0.3)
            }
        }
        
        return attributedString
    }
    
    // Get context snippet for transcript/summary matches
    func getContextSnippet(for text: String, query: String, contextLength: Int = 50) -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive]) else {
            return String(text.prefix(contextLength * 2))
        }
        
        let startIndex = max(text.startIndex, text.index(range.lowerBound, offsetBy: -contextLength, limitedBy: text.startIndex) ?? text.startIndex)
        let endIndex = min(text.endIndex, text.index(range.upperBound, offsetBy: contextLength, limitedBy: text.endIndex) ?? text.endIndex)
        
        let snippet = String(text[startIndex..<endIndex])
        let prefix = startIndex > text.startIndex ? "..." : ""
        let suffix = endIndex < text.endIndex ? "..." : ""
        
        return prefix + snippet + suffix
    }
}
