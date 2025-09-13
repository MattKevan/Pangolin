//
//  DetailView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import AVKit

struct DetailView: View {
    // Selection now comes from the navigation store
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var syncEngine: PangolinSyncEngine
    
    // Legacy initializer parameter kept for compatibility; if provided, it will seed the initial selection.
    let video: Video?
    
    @StateObject private var playerViewModel = VideoPlayerViewModel()
    
    // CORRECTED: Use platform-specific color APIs.
    private var controlsBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }
    
    private var windowBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }
    
    // Subtle, platform-appropriate background for the framed player box
    private var framedPlayerBackground: some ShapeStyle {
        #if os(macOS)
        return .regularMaterial
        #else
        return Color(.secondarySystemBackground)
        #endif
    }
    
    var body: some View {
        GeometryReader { geometry in
            // Main content column only: video + controls on top, hierarchical content below.
            VStack(spacing: 0) {
                // Top: Framed Video Player
                VStack(spacing: 0) {
                    VideoPlayerWithPosterView(video: effectiveSelectedVideo, viewModel: playerViewModel)
                        .frame(height: max(200, geometry.size.height * 0.6)) // adaptive split without a draggable control
                        // Remove the solid black background so it doesn't bleed under the sidebar
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
                .padding(12) // space around the framed player box
                
                // Controls Bar (fixed height)
                VideoControlsBar(viewModel: playerViewModel)
                    .frame(height: 60)
                    .background(controlsBackgroundColor)
                
                // Bottom: Hierarchical content (library browser)
                HierarchicalContentView(searchText: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.clear)
            }
            .onAppear {
                // Seed initial selection if DetailView was constructed with a video
                if let initial = video, store.selectedVideo == nil {
                    store.selectVideo(initial)
                }
            }
            .onChange(of: store.selectedVideo?.id) { _, _ in
                // Load selected video so duration/slider are available; playback remains paused until user presses play.
                if let v = store.selectedVideo {
                    playerViewModel.loadVideo(v)
                } else {
                    // Clear player if selection cleared
                    playerViewModel.player = nil
                    playerViewModel.currentVideo = nil
                    playerViewModel.isPlaying = false
                    playerViewModel.currentTime = 0
                    playerViewModel.duration = 0
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // The effective selected video comes from the store; falls back to the initializer parameter if store has none.
    private var effectiveSelectedVideo: Video? {
        return store.selectedVideo ?? video
    }
}
