//
//  VideoFileStatusView.swift
//  Pangolin
//
//  Shows video file availability status and handles downloads
//

import SwiftUI

struct VideoFileStatusView: View {
    let video: Video
    @EnvironmentObject var videoFileManager: VideoFileManager
    @State private var fileStatus: VideoFileStatus = .local
    @State private var showingDownloadAlert = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            Image(systemName: fileStatus.systemImage)
                .foregroundColor(statusColor)
                .font(.caption)
            
            // Status text
            Text(fileStatus.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Download progress or action button
            if let videoId = video.id {
                if videoFileManager.downloadingVideos.contains(videoId) {
                    // Show download progress
                    ProgressView(value: videoFileManager.downloadProgress[videoId] ?? 0.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 40)
                        .scaleEffect(0.8)
                    
                    Button("Cancel") {
                        videoFileManager.cancelDownload(for: video)
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    
                } else if fileStatus == .cloudOnly {
                    // Download button
                    Button("Download") {
                        downloadVideo()
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .task {
            await updateFileStatus()
        }
        .onChange(of: video) { _ in
            Task {
                await updateFileStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { _ in
            Task {
                await updateFileStatus()
            }
        }
        .alert("Storage Unavailable", isPresented: $showingDownloadAlert) {
            Button("OK") { }
        } message: {
            Text("The storage location for this video is not currently available. Please check that external drives are connected or network locations are accessible.")
        }
    }
    
    private var statusColor: Color {
        switch fileStatus {
        case .local:
            return .green
        case .cloudOnly:
            return .blue
        case .downloading:
            return .orange
        case .missing:
            return .red
        case .error:
            return .gray
        }
    }
    
    @MainActor
    private func updateFileStatus() async {
        fileStatus = await video.getVideoFileStatus()
    }
    
    private func downloadVideo() {
        guard let videoId = video.id else { return }
        
        Task {
            do {
                _ = try await video.getAccessibleFileURL(downloadIfNeeded: true)
                await updateFileStatus()
            } catch {
                print("Failed to download video: \(error)")
                // Could show error alert here
            }
        }
    }
}

// MARK: - Video Row with Status

struct VideoRowWithStatusView: View {
    let video: Video
    @EnvironmentObject var videoFileManager: VideoFileManager
    
    var body: some View {
        HStack {
            // Thumbnail
            AsyncImage(url: video.thumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.tertiary)
                    .overlay {
                        Image(systemName: "video")
                            .foregroundColor(.secondary)
                    }
            }
            .frame(width: 60, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            
            // Video info
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title ?? "Unknown")
                    .font(.body)
                    .lineLimit(1)
                
                HStack {
                    Text(video.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    VideoFileStatusView(video: video)
                }
            }
        }
        .environmentObject(videoFileManager)
    }
}

#Preview {
    // Preview would need mock data
    Text("VideoFileStatusView Preview")
}
