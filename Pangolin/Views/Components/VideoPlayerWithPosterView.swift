//
//  VideoPlayerWithPosterView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import AVKit

struct VideoPlayerWithPosterView: View {
    let video: Video?
    @ObservedObject var viewModel: VideoPlayerViewModel
    @State private var showPlayer = false
    @State private var hasStartedPlaying = false
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // Background color
            Color.black
            
            if let video = video {
                if !showPlayer && !hasStartedPlaying {
                    // Show poster frame (thumbnail)
                    posterFrameView(for: video)
                } else {
                    // Show video player
                    VideoPlayerView(viewModel: viewModel)
                        .onAppear {
                            if !hasStartedPlaying {
                                hasStartedPlaying = true
                            }
                        }
                }
            } else {
                // No video selected state
                ContentUnavailableView(
                    "No Video Selected",
                    systemImage: "video.slash",
                    description: Text("Select a video from the library to start playing")
                )
                .foregroundColor(.white)
            }
        }
        .overlay(alignment: .bottom) {
            if shouldShowControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .onChange(of: video?.id) { oldValue, newValue in
            // Reset state when video changes
            showPlayer = false
            hasStartedPlaying = false
        }
        .onChange(of: viewModel.isPlaying) { oldValue, newValue in
            if newValue {
                showPlayer = true
                hasStartedPlaying = true
            }
        }
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        #endif
    }
    
    @ViewBuilder
    private func posterFrameView(for video: Video) -> some View {
        ZStack {
            // Thumbnail background
            if let thumbnailURL = video.thumbnailURL,
               FileManager.default.fileExists(atPath: thumbnailURL.path) {
                AsyncImage(url: thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            ProgressView()
                                .tint(.white)
                        )
                }
            } else {
                // Fallback when no thumbnail
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "video")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.7))
                            
                            Text(video.title!)
                                .font(.title2)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .padding()
                    )
            }
            
            // Video info overlay
            videoInfoOverlay(for: video)
        }
        .onTapGesture {
            startPlayback()
        }
    }
    
    @ViewBuilder
    private func videoInfoOverlay(for video: Video) -> some View {
        VStack {
            Spacer()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title!)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                    
                    HStack(spacing: 12) {
                        Text(video.formattedDuration)
                        
                        if let resolution = video.resolution, !resolution.isEmpty {
                            Text(resolution)
                        }
                        
                        if video.playbackPosition > 0 {
                            Text("Resume from \(formatTime(video.playbackPosition))")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.7), radius: 1)
                }
                
                Spacer()
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    private func startPlayback() {
        guard let video = video else { return }
        
        // Load video if not already loaded
        if viewModel.player == nil || video != getCurrentVideo() {
            viewModel.loadVideo(video, autoPlay: true)
        } else {
            // Start playing immediately when already loaded
            viewModel.play()
        }
        showPlayer = true
        hasStartedPlaying = true
    }
    
    private func getCurrentVideo() -> Video? {
        return viewModel.currentVideo
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "00:00"
    }

    private var shouldShowControls: Bool {
        isHovering || !viewModel.isPlaying
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                #if os(macOS)
                Button {
                    viewModel.togglePictureInPicture()
                } label: {
                    Image(systemName: "pip")
                }
                .buttonStyle(.plain)
                .help("Picture in Picture")

                Button {
                    viewModel.openInNewWindow()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .buttonStyle(.plain)
                .help("Open in New Window")
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VideoControlsBar(viewModel: viewModel, onPlayPause: playPauseFromOverlay)
                .padding(.bottom, 8)
        }
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func playPauseFromOverlay() {
        if viewModel.isPlaying {
            viewModel.pause()
        } else {
            startPlayback()
        }
    }
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
