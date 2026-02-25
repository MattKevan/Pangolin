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
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService
    
    // Legacy initializer parameter kept for compatibility; if provided, it will seed the initial selection.
    let video: Video?
    
    @StateObject private var playerViewModel = VideoPlayerViewModel()
    @State private var splitRatio: Double = 1.0 / 3.0
    @State private var selectedInspectorTab: InspectorTab = .transcript
    @State private var isControlsInspectorPresented = true
    
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
            VStack(spacing: 0) {
                if !playerViewModel.isExternalPlaybackActive {
                    // Top: Video Player + Controls (resizable)
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            VideoPlayerWithPosterView(video: effectiveSelectedVideo, viewModel: playerViewModel)
                                .frame(maxHeight: .infinity)
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
                    }
                    .frame(height: geometry.size.height * splitRatio)
                    
                    DraggableSplitter(
                        splitRatio: $splitRatio,
                        totalSize: geometry.size.height,
                        minRatio: 0.2,
                        maxRatio: 0.8,
                        isVertical: true
                    )
                }
                
                // Bottom: Inline Inspector (fills remaining space)
                InspectorContentView(video: effectiveSelectedVideo, playerViewModel: playerViewModel, selectedTab: $selectedInspectorTab)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
                    .frame(maxHeight: .infinity)
            }
            .onAppear {
                // Seed initial selection if DetailView was constructed with a video
                if let initial = video, store.selectedVideo == nil {
                    store.selectVideo(initial)
                }
                if let selected = effectiveSelectedVideo,
                   ((playerViewModel.currentVideo?.id != selected.id) || (playerViewModel.player == nil)) {
                    playerViewModel.loadVideo(selected)
                }
                syncControlsInspectorVisibility()
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
                syncControlsInspectorVisibility()
            }
            .onChange(of: selectedInspectorTab) { _, _ in
                syncControlsInspectorVisibility()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let selectedVideo = effectiveSelectedVideo {
                        Button {
                            toggleFavorite(video: selectedVideo)
                        } label: {
                            Image(systemName: selectedVideo.isFavorite ? "heart.fill" : "heart")
                        }
                        .help(selectedVideo.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    }

                    if canShowControlsInspector {
                        Button {
                            isControlsInspectorPresented.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(isControlsInspectorPresented ? "Hide Processing Controls" : "Show Processing Controls")
                    }
                }
            }
            #if os(macOS)
            .inspector(isPresented: controlsInspectorBinding) {
                if let selectedVideo = effectiveSelectedVideo,
                   selectedInspectorTab.supportsRightControlsInspector {
                    ProcessingControlsInspectorView(tab: selectedInspectorTab, video: selectedVideo)
                        .environmentObject(libraryManager)
                        .environmentObject(transcriptionService)
                }
            }
            #endif
        }
    }
    
    // The effective selected video comes from the store; falls back to the initializer parameter if store has none.
    private var effectiveSelectedVideo: Video? {
        return store.selectedVideo ?? video
    }

    private var canShowControlsInspector: Bool {
        effectiveSelectedVideo != nil && selectedInspectorTab.supportsRightControlsInspector
    }

    #if os(macOS)
    private var controlsInspectorBinding: Binding<Bool> {
        Binding(
            get: { canShowControlsInspector && isControlsInspectorPresented },
            set: { isControlsInspectorPresented = $0 }
        )
    }
    #endif

    private func syncControlsInspectorVisibility() {
        isControlsInspectorPresented = canShowControlsInspector
    }

    private func toggleFavorite(video: Video) {
        guard let context = libraryManager.viewContext else { return }

        video.isFavorite.toggle()

        do {
            try context.save()
        } catch {
            print("❌ FAVORITE: Failed to save favorite status from detail toolbar: \(error)")
            video.isFavorite.toggle()
        }
    }
}
