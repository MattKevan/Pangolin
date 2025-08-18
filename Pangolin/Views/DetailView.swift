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
                let _ = print("📱 DetailView: Showing video: \(video.title)")  
                VStack(spacing: 0) {
                    // Video Player with Poster Frame
                    VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
                        .frame(height: geometry.size.height * 0.67)
                    
                    // Controls Bar
                    VideoControlsBar(viewModel: playerViewModel)
                        .frame(height: 60)
                        .background(controlsBackgroundColor)
                    
                    // Bottom area
                    VideoInfoView(video: video)
                        .frame(maxHeight: .infinity)
                        .background(windowBackgroundColor)
                }
            } else {
                let _ = print("📱 DetailView: No video selected")
                ContentUnavailableView(
                    "Select a Video",
                    systemImage: "play.rectangle",
                    description: Text("Choose a video from the list to start watching")
                )
            }
        }
    }
}
