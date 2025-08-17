//
//  VideoThumbnailView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct VideoThumbnailView: View {
    let video: Video
    let size: CGSize
    
    init(video: Video, size: CGSize = CGSize(width: 160, height: 90)) {
        self.video = video
        self.size = size
    }
    
    var body: some View {
        Group {
            if let thumbnailURL = video.thumbnailURL,
               FileManager.default.fileExists(atPath: thumbnailURL.path) {
                AsyncImage(url: thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.7)
                        )
                }
            } else {
                // Fallback placeholder
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.title2)
                                .foregroundColor(.gray.opacity(0.6))
                            
                            Text("No Preview")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            // Duration overlay
            HStack {
                Spacer()
                VStack {
                    Spacer()
                    Text(video.formattedDuration)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
        )
    }
}

#Preview {
    // Preview placeholder since we need actual video data
    Rectangle()
        .fill(Color.gray.opacity(0.2))
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            VStack {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                Text("Thumbnail Preview")
                    .font(.caption)
            }
            .foregroundColor(.gray)
        )
}