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

    private var displayTitle: String {
        let title = video.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    private var displayFileName: String {
        let fileName = video.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fileName.isEmpty ? "Unknown" : fileName
    }

    private var displayDateAdded: String {
        guard let dateAdded = video.dateAdded else { return "Unknown" }
        return DateFormatter.localizedString(from: dateAdded, dateStyle: .medium, timeStyle: .short)
    }

    private var sortedSubtitles: [Subtitle] {
        let subtitleSet = video.subtitles as? Set<Subtitle> ?? []
        return subtitleSet.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title and metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text(displayTitle)
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
                    
                    InfoRow(label: "Filename", value: displayFileName)
                    InfoRow(label: "Format", value: video.videoFormat ?? "Unknown")
                    InfoRow(label: "Frame Rate", value: String(format: "%.1f fps", video.frameRate))
                    InfoRow(label: "Date Added", value: displayDateAdded)
                    
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

                        if sortedSubtitles.isEmpty {
                            Text("No subtitles available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(sortedSubtitles, id: \.objectID) { subtitle in
                                HStack {
                                    Text(subtitle.displayName)
                                    Spacer()
                                    Text((subtitle.format ?? "unknown").uppercased())
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
        Task { await libraryManager.save() }
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
