//
//  DetailView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/DetailView.swift
import SwiftUI
import AVKit

struct DetailView: View {
    let video: Video?
    @StateObject private var playerViewModel = VideoPlayerViewModel()
    
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
                    // Video Player with Poster Frame (2/3 of height)
                    VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
                        .frame(height: geometry.size.height * 0.67)
                    
                    // Controls Bar
                    VideoControlsBar(viewModel: playerViewModel)
                        .frame(height: 60)
                        .background(controlsBackgroundColor)
                    
                    // Bottom area (1/3 of height minus controls)
                    VideoInfoView(video: video)
                        .frame(maxHeight: .infinity)
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