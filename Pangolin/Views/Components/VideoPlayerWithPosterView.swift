//
//  VideoPlayerWithPosterView.swift
//  Pangolin
//

import SwiftUI
import AVKit

struct VideoPlayerWithPosterView: View {
    let video: Video?
    @ObservedObject var viewModel: VideoPlayerViewModel

    var showInfoOverlay: Bool = true
    var showOverlayOnHoverOnly: Bool = false
    var showsUtilityButtons: Bool = false
    var onPictureInPicture: (() -> Void)? = nil
    var onOpenInNewWindow: (() -> Void)? = nil

    @State private var showPlayer = false
    @State private var hasStartedPlaying = false
    @State private var isHovering = false

    private var shouldShowOverlayControls: Bool {
        if showOverlayOnHoverOnly {
            return isHovering
        }
        return true
    }

    var body: some View {
        ZStack {
            Color.black

            if let video = video {
                if !showPlayer && !hasStartedPlaying {
                    posterFrameView(for: video)
                } else {
                    VideoPlayerView(viewModel: viewModel)
                }

                if shouldShowOverlayControls {
                    overlayControls
                }

                if showInfoOverlay {
                    videoInfoOverlay(for: video)
                }
            } else {
                ContentUnavailableView(
                    "No Video Selected",
                    systemImage: "video.slash",
                    description: Text("Select a video from the library to start playing")
                )
                .foregroundColor(.white)
            }
        }
        #if os(macOS)
        .onHover { hovering in
            isHovering = hovering
        }
        #endif
        .onChange(of: video?.id) { _, _ in
            showPlayer = false
            hasStartedPlaying = false
        }
        .onChange(of: viewModel.isPlaying) { _, newValue in
            if newValue {
                showPlayer = true
                hasStartedPlaying = true
            }
        }
    }

    @ViewBuilder
    private func posterFrameView(for video: Video) -> some View {
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
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    VStack(spacing: 12) {
                        Image(systemName: "video")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.7))

                        Text(video.title ?? "Untitled Video")
                            .font(.title2)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding()
                )
        }
    }

    private var overlayControls: some View {
        VStack {
            if showsUtilityButtons {
                HStack {
                    Spacer()

                    if let onPictureInPicture {
                        Button(action: onPictureInPicture) {
                            Image(systemName: "pip")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Picture in Picture")
                    }

                    if let onOpenInNewWindow {
                        Button(action: onOpenInNewWindow) {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in New Window")
                    }
                }
                .padding(12)
            }

            Spacer()

            Button(action: togglePlayback) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .animation(.easeInOut(duration: 0.15), value: shouldShowOverlayControls)
    }

    @ViewBuilder
    private func videoInfoOverlay(for video: Video) -> some View {
        VStack {
            Spacer()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title ?? "Untitled Video")
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

    private func togglePlayback() {
        guard let video else { return }

        if viewModel.player == nil || video != viewModel.currentVideo {
            viewModel.loadVideo(video)
        }

        if viewModel.isPlaying {
            viewModel.pause()
        } else {
            viewModel.play()
            showPlayer = true
            hasStartedPlaying = true
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "00:00"
    }
}

#Preview {
    VideoPlayerWithPosterView(
        video: nil,
        viewModel: VideoPlayerViewModel()
    )
    .frame(height: 400)
    .background(Color.black)
}
