//
//  VideoListRow.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct VideoListRow: View {
    let video: Video
    let isSelected: Bool
    let showCheckbox: Bool
    let sourcePlaylist: Playlist?
    let selectedVideos: Set<Video>
    
    var body: some View {
        HStack {
            if showCheckbox {
                Button(action: {}) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                .allowsHitTesting(false)
            }
            
            VideoThumbnailView(video: video, size: CGSize(width: 120, height: 67.5))
            
            VStack(alignment: .leading) {
                Text(video.title)
                    .lineLimit(1)
                
                HStack {
                    Text(video.formattedDuration)
                    Text("•")
                    Text(formatFileSize(video.fileSize))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        #if os(macOS)
        .modifier(DragModifier(video: video, selectedVideos: selectedVideos, sourcePlaylist: sourcePlaylist))
        #else
        .onDrag {
            NSItemProvider(object: "\(video.id)" as NSString)
        }
        #endif
    }
    
    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
}
