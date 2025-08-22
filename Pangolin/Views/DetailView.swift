//
//  DetailView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI
import AVKit

struct DetailView: View {
    let video: Video?
    @StateObject private var playerViewModel = VideoPlayerViewModel()
    @State private var splitRatio: Double = 0.67 // Default 67% for video, 33% for details
    
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
    
    var body: some View {
        GeometryReader { geometry in
            if let video = video {
                VStack(spacing: 0) {
                    // Top panel: Video Player with Poster Frame
                    VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
                        .frame(height: max(200, geometry.size.height * splitRatio - 30)) // Reserve 30pt for controls
                    
                    // Controls Bar (fixed height)
                    VideoControlsBar(viewModel: playerViewModel)
                        .frame(height: 60)
                        .background(controlsBackgroundColor)
                    
                    // Draggable Splitter
                    DraggableSplitter(
                        splitRatio: $splitRatio,
                        totalSize: geometry.size.height,
                        minRatio: 0.3, // Minimum 30% for video
                        maxRatio: 0.85, // Maximum 85% for video
                        isVertical: true
                    )
                    .frame(height: 8)
                    .background(Color.clear)
                    
                    // Bottom panel: Detail tabs
                    VideoDetailTabView(video: video)
                        .frame(height: max(150, geometry.size.height * (1 - splitRatio) - 38)) // Reserve space for controls and splitter
                        .background(windowBackgroundColor)
                }
            } else {
                ContentUnavailableView(
                    "Select a Video",
                    systemImage: "play.rectangle",
                    description: Text("Choose a video from the list to start watching")
                )
            }
        }
    }
}
