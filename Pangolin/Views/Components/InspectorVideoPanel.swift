//
//  InspectorVideoPanel.swift
//  Pangolin
//

import SwiftUI
import AppKit

struct InspectorVideoPanel: View {
    let video: Video?
    let allowOpenInNewWindow: Bool

    @StateObject private var playerViewModel = VideoPlayerViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if let video {
                VideoPlayerWithPosterView(
                    video: video,
                    viewModel: playerViewModel,
                    showInfoOverlay: false,
                    showOverlayOnHoverOnly: true,
                    showsUtilityButtons: true,
                    onPictureInPicture: startPictureInPicture,
                    onOpenInNewWindow: openInNewWindow
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(aspectRatio(for: video), contentMode: .fit)
                .background(Color.black)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title ?? "Untitled Video")
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 12) {
                        Text(video.formattedDuration)
                            .foregroundStyle(.secondary)

                        if let resolution = video.resolution, !resolution.isEmpty {
                            Text(resolution)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else {
                ContentUnavailableView("No Video", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            loadSelectedVideo()
        }
        .onChange(of: video?.id) { _, _ in
            loadSelectedVideo()
        }
    }

    private func loadSelectedVideo() {
        guard let video else {
            playerViewModel.player = nil
            playerViewModel.currentVideo = nil
            playerViewModel.isPlaying = false
            playerViewModel.currentTime = 0
            playerViewModel.duration = 0
            return
        }

        playerViewModel.loadVideo(video)
    }

    private func openInNewWindow() {
        guard allowOpenInNewWindow,
              let id = video?.id?.uuidString else { return }
        openWindow(id: "video-player-window", value: id)
    }

    private func startPictureInPicture() {
        if !playerViewModel.isPlaying {
            playerViewModel.play()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.sendAction(NSSelectorFromString("togglePictureInPicture:"), to: nil, from: nil)
        }
    }

    private func aspectRatio(for video: Video) -> CGFloat {
        guard let resolution = video.resolution else { return 16.0 / 9.0 }

        let separators = CharacterSet(charactersIn: "x×")
        let parts = resolution
            .lowercased()
            .components(separatedBy: separators)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return 16.0 / 9.0
        }

        return CGFloat(parts[0] / parts[1])
    }
}
