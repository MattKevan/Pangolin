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
    
    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(
                    Image(systemName: "play.rectangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.gray.opacity(0.5))
                )
            
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
    }
}
