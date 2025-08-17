//
//  VideoListRow.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct VideoListRow: View {
    let video: Video
    
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 120, height: 67.5)
                .overlay(
                    Image(systemName: "play.rectangle.fill")
                        .foregroundColor(.gray.opacity(0.5))
                )
            
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
    }
    
    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
