//
//  VideoPlayerWithPosterView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct VideoPlayerWithPosterView: View {
    let video: Video?
    let viewModel: VideoPlayerViewModel
    
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
                    dismissPoster()
                }
            }
        }
        .onChange(of: viewModel.isPlaying) { _, isPlaying in
            if isPlaying {
                dismissPoster()
            }
        }
        .onChange(of: viewModel.currentTime) { _, newTime in
            if newTime > posterStartThreshold {
                dismissPoster()
            }
        }
        #endif
    }

    #if os(macOS)
    private var posterStartThreshold: TimeInterval { 0.35 }

    private var shouldShowPoster: Bool {
        guard let selectedVideo = video else { return false }
        guard let videoID = selectedVideo.id else { return false }
        guard !viewModel.isPlaying else { return false }
        guard !viewModel.isPosterDismissed(for: videoID) else { return false }
        return isAtStart(selectedVideo)
    }

    private func dismissPoster() {
        guard let videoID = video?.id else { return }
        viewModel.dismissPoster(for: videoID)
    }

    private func isAtStart(_ video: Video) -> Bool {
        let persistedPosition = max(0, video.playbackPosition)
        let livePosition: TimeInterval = (viewModel.currentVideo?.id == video.id) ? max(0, viewModel.currentTime) : 0
        return max(persistedPosition, livePosition) <= posterStartThreshold
    }

    @ViewBuilder
    private func posterOverlay(for video: Video) -> some View {
        SyncedThumbnailImage(video: video, contentMode: .fit) {
            Color.black
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
