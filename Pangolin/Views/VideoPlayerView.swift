// Views/VideoPlayerView.swift
import SwiftUI
import AVKit

#if os(macOS)
struct VideoPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = viewModel.player
        playerView.controlsStyle = .none // We'll use custom controls
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
struct VideoPlayerView: UIViewRepresentable {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    func makeUIView(context: Context) -> UIView {
        // We need to wrap the AVPlayerViewController to use its view
        let controller = AVPlayerViewController()
        controller.player = viewModel.player
        controller.showsPlaybackControls = false // Custom controls
        
        // This makes sure the view from the controller is returned
        return controller.view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // This is tricky because we don't have direct access to the controller.
        // For simple player updates, swapping the player on the viewModel should be sufficient.
        // More complex updates might require a Coordinator.
    }
}
#endif
