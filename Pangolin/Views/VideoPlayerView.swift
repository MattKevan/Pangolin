//
//  VideoPlayerView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/Components/VideoPlayerView.swift
import SwiftUI
import AVKit

struct VideoPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = viewModel.player
        playerView.controlsStyle = .none // We'll use custom controls
        playerView.showsFullScreenToggleButton = true
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = viewModel.player
    }
}

#if os(iOS)
struct VideoPlayerView: UIViewRepresentable {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    func makeUIView(context: Context) -> UIView {
        let controller = AVPlayerViewController()
        controller.player = viewModel.player
        controller.showsPlaybackControls = false // Custom controls
        return controller.view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Update if needed
    }
}
#endif