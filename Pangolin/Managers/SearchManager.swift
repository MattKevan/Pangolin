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
    
    private var debounceTimer: Timer?
    private let debounceDelay: TimeInterval = 0.3
    
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
        // Apple-recommended approach: live search on text changes
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] newText in
                Task { @MainActor in
                    await self?.performSearch(query: newText)
                }
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private func scheduleSearch(query: String) {
        debounceTimer?.invalidate()
        
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchResults = []
            isSearching = false
            return
        }
        
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.performSearch(query: query)
            }
        }
    }
    
    private func performSearch(query: String) async {
        isSearching = true
        
        guard let context = LibraryManager.shared.viewContext,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        do {
            let results = try await searchVideos(query: query, in: context)
            searchResults = results
        } catch {
            print("Search error: \(error)")
            searchResults = []
        }
        
        isSearching = false
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
        searchText = ""
        searchResults = []
        isSearchActive = false
        isSearching = false
        debounceTimer?.invalidate()
    }
    
    func activateSearch() {
        isSearchActive = true
    }
    
    func deactivateSearch() {
        isSearchActive = false
        clearSearch()
    }
    
    // Manual search trigger (called on Return key press)
    func performManualSearch() {
        Task { @MainActor in
            await performSearch(query: searchText)
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