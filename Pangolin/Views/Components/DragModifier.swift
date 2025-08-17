//
//  DragModifier.swift
//  Pangolin
//
//  Created by Matt Kevan on 17/08/2025.
//

import SwiftUI

struct DragModifier: ViewModifier {
    let video: Video
    let selectedVideos: Set<Video>
    let sourcePlaylist: Playlist?
    
    func body(content: Content) -> some View {
        if selectedVideos.contains(video) && selectedVideos.count > 1 {
            // Drag batch of videos
            content
                .draggable(VideoBatchTransfer(videos: Array(selectedVideos), sourcePlaylist: sourcePlaylist)) {
                    batchDragPreview
                }
        } else {
            // Drag single video
            content
                .draggable(VideoTransfer(video: video, sourcePlaylist: sourcePlaylist)) {
                    singleDragPreview
                }
        }
    }
    
    @ViewBuilder
    private var batchDragPreview: some View {
        VStack {
            HStack {
                Image(systemName: "video")
                    .font(.title)
                Text("\(selectedVideos.count)")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            Text("\(selectedVideos.count) videos")
                .font(.caption)
        }
        .padding()
        .background(Color.accentColor.opacity(0.8))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var singleDragPreview: some View {
        VStack {
            Image(systemName: "video")
                .font(.title)
            Text(video.title)
                .font(.caption)
                .lineLimit(1)
        }
        .padding()
        .background(Color.gray.opacity(0.8))
        .cornerRadius(8)
    }
}