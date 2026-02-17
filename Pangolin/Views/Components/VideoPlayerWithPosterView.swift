//
//  VideoPlayerWithPosterView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct VideoPlayerWithPosterView: View {
    let video: Video?
    @ObservedObject var viewModel: VideoPlayerViewModel
    #if os(macOS)
    @State private var posterDismissedForSelection = false
    #endif
    
    var body: some View {
        ZStack {
            Color.black
            
            if video != nil {
                VideoPlayerView(viewModel: viewModel)
                    .overlay {
                        #if os(macOS)
                        if let selectedVideo = video, shouldShowPoster {
                            posterOverlay(for: selectedVideo)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                        #endif
                    }
            } else {
                ContentUnavailableView(
                    "No video selected",
                    systemImage: "video.slash",
                    description: Text("Select a video from the library to start playing")
                )
                .foregroundColor(.white)
            }
        }
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                withAnimation(.easeInOut(duration: 0.15)) {
                    posterDismissedForSelection = true
                }
            }
        }
        .onChange(of: video?.id) { _, _ in
            posterDismissedForSelection = false
        }
        .onChange(of: viewModel.isPlaying) { _, isPlaying in
            if isPlaying {
                posterDismissedForSelection = true
            }
        }
        .onChange(of: viewModel.currentTime) { _, newTime in
            if newTime > posterStartThreshold {
                posterDismissedForSelection = true
            }
        }
        #endif
    }

    #if os(macOS)
    private var posterStartThreshold: TimeInterval { 0.35 }

    private var shouldShowPoster: Bool {
        guard let selectedVideo = video else { return false }
        guard !viewModel.isPlaying else { return false }
        guard !posterDismissedForSelection else { return false }
        return isAtStart(selectedVideo)
    }

    private func isAtStart(_ video: Video) -> Bool {
        let persistedPosition = max(0, video.playbackPosition)
        let livePosition: TimeInterval = (viewModel.currentVideo?.id == video.id) ? max(0, viewModel.currentTime) : 0
        return max(persistedPosition, livePosition) <= posterStartThreshold
    }

    @ViewBuilder
    private func posterOverlay(for video: Video) -> some View {
        if let thumbnailURL = video.thumbnailURL,
           FileManager.default.fileExists(atPath: thumbnailURL.path) {
            AsyncImage(url: thumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } placeholder: {
                Color.black
            }
        } else {
            Color.black
        }
    }
    #endif
}

#Preview {
    // Preview with mock data
    VideoPlayerWithPosterView(
        video: nil,
        viewModel: VideoPlayerViewModel()
    )
    .frame(height: 400)
    .background(Color.black)
}
