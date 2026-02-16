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
    let showsDurationOverlay: Bool
    let showsCloudStatusOverlay: Bool
    
    init(
        video: Video,
        size: CGSize = CGSize(width: 160, height: 90),
        showsDurationOverlay: Bool = true,
        showsCloudStatusOverlay: Bool = true
    ) {
        self.video = video
        self.size = size
        self.showsDurationOverlay = showsDurationOverlay
        self.showsCloudStatusOverlay = showsCloudStatusOverlay
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
                            Image(systemName: "play.rectangle.fill")
                                .font(.title2)
                                .foregroundColor(.gray.opacity(0.6))
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
        .overlay {
            if showsDurationOverlay {
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
            }
        }
        .overlay {
            if showsCloudStatusOverlay {
                HStack {
                    Spacer()
                    VStack {
                        cloudStatusIcon
                        Spacer()
                    }
                    .padding(4)
                }
            }
        }
    }
    
    @ViewBuilder
    private var cloudStatusIcon: some View {
        switch resolvedFileStatus {
        case .cloudOnly:
            Image(systemName: "icloud")
                .font(.caption)
                .foregroundColor(.white)
                .background(Circle().fill(.blue))
                .frame(width: 16, height: 16)
                .help("File is in iCloud - tap to download")
                
        case .downloading:
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption)
                .foregroundColor(.white)
                .background(Circle().fill(.blue))
                .frame(width: 16, height: 16)
                .help("Downloading from iCloud")
                
        case .missing:
            Image(systemName: "exclamationmark.icloud")
                .font(.caption)
                .foregroundColor(.white)
                .background(Circle().fill(.red))
                .frame(width: 16, height: 16)
                .help("File not found")
                
        case .local:
            // File is available locally - no icon needed (like Finder)
            EmptyView()
            
        case .error:
            Image(systemName: "questionmark.diamond")
                .font(.caption)
                .foregroundColor(.white)
                .background(Circle().fill(.gray))
                .frame(width: 16, height: 16)
                .help("Invalid file path")
        }
    }
    
    private var resolvedFileStatus: VideoFileStatus {
        if let rawState = video.fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            return status
        }

        if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
            return .cloudOnly
        }

        return .local
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
