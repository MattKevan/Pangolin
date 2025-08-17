//
//  VideoGridItem.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct VideoGridItem: View {
    let video: Video
    let isSelected: Bool
    let showCheckbox: Bool
    let sourcePlaylist: Playlist?
    let selectedVideos: Set<Video>
    
    var body: some View {
        VStack {
            ZStack(alignment: .topLeading) {
                VideoThumbnailView(video: video, size: CGSize(width: 180, height: 101))
                
                if showCheckbox {
                    Button(action: {}) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .background(Color.white.opacity(0.8))
                            .clipShape(Circle())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
            
            Text(video.title)
                .lineLimit(2)
                .font(.caption)
            
            Text(video.formattedDuration)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        #if os(macOS)
        .modifier(DragModifier(video: video, selectedVideos: selectedVideos, sourcePlaylist: sourcePlaylist))
        #else
        .onDrag {
            NSItemProvider(object: "\(video.id)" as NSString)
        }
        #endif
    }
    
}
