//
//  SearchDetailView.swift
//  Pangolin
//
//  Search-specific detail view for displaying selected search results
//

import SwiftUI
import AVKit

struct SearchDetailView: View {
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var libraryManager: LibraryManager
    
    let video: Video
    
    @StateObject private var playerViewModel = VideoPlayerViewModel()
    
    private var framedPlayerBackground: some ShapeStyle {
        #if os(macOS)
        return .regularMaterial
        #else
        return Color(.secondarySystemBackground)
        #endif
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Video Player Section
                VStack(spacing: 0) {
                    VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
                        .frame(height: max(250, geometry.size.height * 0.4))
                        .background(Color.clear)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(framedPlayerBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(12)
                
                // Controls Bar
                // Video Information Section
                SearchVideoInfoView(video: video, searchQuery: searchManager.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.clear)
            }
        }
        .onAppear {
            playerViewModel.loadVideo(video)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search Video Info View
private struct SearchVideoInfoView: View {
    let video: Video
    let searchQuery: String
    @EnvironmentObject private var searchManager: SearchManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Video Title
                VStack(alignment: .leading, spacing: 8) {
                    Text("Title")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    if let title = video.title {
                        Text(searchManager.highlightedText(for: title, query: searchQuery))
                            .font(.title2)
                            .fontWeight(.medium)
                    } else {
                        Text(video.fileName ?? "Unknown Video")
                            .font(.title2)
                            .fontWeight(.medium)
                    }
                }
                
                // Video Details
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Duration:")
                                .foregroundColor(.secondary)
                            Text(video.formattedDuration)
                        }
                        
                        if video.fileSize > 0 {
                            GridRow {
                                Text("File Size:")
                                    .foregroundColor(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file))
                            }
                        }
                        
                        if let folder = video.folder {
                            GridRow {
                                Text("Folder:")
                                    .foregroundColor(.secondary)
                                Text(folder.name ?? "Unknown Folder")
                            }
                        }
                        
                        if let dateAdded = video.dateAdded {
                            GridRow {
                                Text("Added:")
                                    .foregroundColor(.secondary)
                                Text(dateAdded, style: .date)
                            }
                        }
                    }
                    .font(.body)
                }
                
                // Transcript Section (if available and matches search)
                if let transcript = video.transcriptText,
                   !transcript.isEmpty,
                   (searchQuery.isEmpty || transcript.localizedCaseInsensitiveContains(searchQuery)) {
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcript")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        if searchQuery.isEmpty {
                            Text(transcript)
                                .font(.body)
                                .textSelection(.enabled)
                        } else {
                            Text(searchManager.highlightedText(for: transcript, query: searchQuery))
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                // Summary Section (if available and matches search)
                if let summary = video.transcriptSummary,
                   !summary.isEmpty,
                   (searchQuery.isEmpty || summary.localizedCaseInsensitiveContains(searchQuery)) {
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        if searchQuery.isEmpty {
                            Text(summary)
                                .font(.body)
                                .textSelection(.enabled)
                        } else {
                            Text(searchManager.highlightedText(for: summary, query: searchQuery))
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                Spacer()
            }
            .padding(16)
        }
    }
}

#Preview {
    SearchDetailView(video: Video())
        .environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))
        .environmentObject(SearchManager())
        .environmentObject(LibraryManager.shared)
}
