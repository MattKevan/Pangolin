//
//  VideoInfoView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct VideoInfoView: View {
    let video: Video
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title and metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    HStack {
                        Text(video.formattedDuration)
                        Text("•")
                        Text(video.resolution ?? "Unknown")
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Divider()
                
                // File info
                VStack(alignment: .leading, spacing: 8) {
                    Text("File Information")
                        .font(.headline)
                    
                    InfoRow(label: "Filename", value: video.fileName)
                    InfoRow(label: "Format", value: video.videoFormat ?? "Unknown")
                    InfoRow(label: "Frame Rate", value: String(format: "%.1f fps", video.frameRate))
                    InfoRow(label: "Date Added", value: DateFormatter.localizedString(from: video.dateAdded, dateStyle: .medium, timeStyle: .short))
                    
                    if let lastPlayed = video.lastPlayed {
                        InfoRow(label: "Last Played", value: DateFormatter.localizedString(from: lastPlayed, dateStyle: .medium, timeStyle: .short))
                    }
                    
                    InfoRow(label: "Play Count", value: String(video.playCount))
                }
                
                if video.hasSubtitles {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Subtitles")
                            .font(.headline)
                        
                        if let subtitles = video.subtitles {
                            ForEach(Array(subtitles), id: \.id) { subtitle in
                                HStack {
                                    Text(subtitle.displayName)
                                    Spacer()
                                    Text(subtitle.format.uppercased())
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }
}