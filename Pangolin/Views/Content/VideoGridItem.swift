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
    
    var body: some View {
        VStack {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        Image(systemName: "play.rectangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.gray.opacity(0.5))
                    )
                
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
        .draggable(VideoTransfer(id: video.id, title: video.title)) {
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
        #else
        .onDrag {
            NSItemProvider(object: "\(video.id)" as NSString)
        }
        #endif
    }
}
