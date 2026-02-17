// Views/VideoPlayerView.swift
import SwiftUI
import AVKit

#if os(macOS)
struct VideoPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = viewModel.player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        viewModel.playerView = playerView
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = viewModel.player
        viewModel.playerView = nsView
    }
}
#elseif os(iOS)
struct VideoPlayerView: UIViewControllerRepresentable {
    @ObservedObject var viewModel: VideoPlayerViewModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = viewModel.player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = viewModel.player
    }
}
#endif
