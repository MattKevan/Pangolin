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
    
    var body: some View {
        GeometryReader { geometry in
            if let video = video {
                VStack(spacing: 0) {
                    // Video Player (2/3 of height)
                    VideoPlayerView(viewModel: playerViewModel)
                        .frame(height: geometry.size.height * 0.67)
                    
                    // Controls Bar
                    VideoControlsBar(viewModel: playerViewModel)
                        .frame(height: 60)
                        .background(Color(NSColor.controlBackgroundColor))
                    
                    // Bottom area (1/3 of height minus controls)
                    VideoInfoView(video: video)
                        .frame(maxHeight: .infinity)
                        .background(Color(NSColor.windowBackgroundColor))
                }
                .onAppear {
                    playerViewModel.loadVideo(video)
                }
            } else {
                ContentUnavailableView(
                    "Select a Video",
                    systemImage: "play.rectangle",
                    description: Text("Choose a video from the list to start watching")
                )
            }
        }
        .onChange(of: video?.id) { _ in
            if let video = video {
                playerViewModel.loadVideo(video)
            }
        }
    }
}