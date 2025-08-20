//
//  VideoInfoView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct VideoInfoView: View {
    // Use @ObservedObject for a managed object to ensure the view updates on change
    @ObservedObject var video: Video
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title and metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title!)
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
                
                // Favorite Button
                Button(action: toggleFavorite) {
                    Label(video.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: video.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.bordered)
                .tint(video.isFavorite ? .red : .secondary)

                Divider()
                
                // File info
                VStack(alignment: .leading, spacing: 8) {
                    Text("File Information")
                        .font(.headline)
                    
                    InfoRow(label: "Filename", value: video.fileName!)
                    InfoRow(label: "Format", value: video.videoFormat ?? "Unknown")
                    InfoRow(label: "Frame Rate", value: String(format: "%.1f fps", video.frameRate))
                    InfoRow(label: "Date Added", value: DateFormatter.localizedString(from: video.dateAdded!, dateStyle: .medium, timeStyle: .short))
                    
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
                            ForEach(Array(subtitles as! Set<Subtitle>), id: \.id) { subtitle in
                                HStack {
                                    Text(subtitle.displayName)
                                    Spacer()
                                    Text(subtitle.format!.uppercased())
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

    private func toggleFavorite() {
        video.isFavorite.toggle()
        Task {
            await libraryManager.save()
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
