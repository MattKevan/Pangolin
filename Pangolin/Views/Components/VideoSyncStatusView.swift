//
//  VideoSyncStatusView.swift
//  Pangolin
//
//  Enhanced sync status indicators for videos in table views
//  Combines iCloud file status with CKSyncEngine sync status
//

import SwiftUI

struct VideoSyncStatusView: View {
    let video: Video
    @EnvironmentObject var syncEngine: PangolinSyncEngine
    @State private var iCloudStatus: iCloudFileStatus = .unknown
    
    var body: some View {
        ZStack {
            // Base iCloud file status icon
            statusIcon
                .font(.system(size: 11))
                .foregroundColor(statusColor)
                .opacity(syncStatusOpacity)
            
            // Sync status overlay
            if let videoID = video.id,
               let syncStatus = syncEngine.videoStatuses[videoID] {
                syncStatusOverlay(syncStatus)
            }
        }
        .help(helpText)
        .task {
            await updateiCloudStatus()
        }
        .onChange(of: video) {
            Task { await updateiCloudStatus() }
        }
        // Add context menu for sync actions
        .contextMenu {
            if let videoID = video.id {
                syncContextMenu(for: videoID)
            }
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: iCloudStatus.systemImage)
    }
    
    @ViewBuilder
    private func syncStatusOverlay(_ syncStatus: VideoSyncStatus) -> some View {
        switch syncStatus {
        case .uploading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 8, height: 8)
                .offset(x: 3, y: -3)
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 8, height: 8)
                .offset(x: 3, y: -3)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 6))
                .foregroundColor(.red)
                .background(Color.white)
                .clipShape(Circle())
                .offset(x: 4, y: -4)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 6))
                .foregroundColor(.yellow)
                .background(Color.white)
                .clipShape(Circle())
                .offset(x: 4, y: -4)
        case .retrying:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 6, height: 6)
                .offset(x: 4, y: -4)
        case .synced, .local:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func syncContextMenu(for videoID: UUID) -> some View {
        if let syncStatus = syncEngine.videoStatuses[videoID] {
            switch syncStatus {
            case .local:
                Button("Upload to iCloud") {
                    Task {
                        try await syncEngine.uploadVideo(video)
                    }
                }
                .disabled(syncEngine.syncStatus == .offline || syncEngine.syncStatus == .accountIssue)
            case .error:
                Button("Retry Sync") {
                    Task {
                        try await syncEngine.uploadVideo(video)
                    }
                }
            case .conflict:
                Button("Resolve Conflict") {
                    // This would open a conflict resolution UI
                    // For now, just retry the sync
                    Task {
                        try await syncEngine.uploadVideo(video)
                    }
                }
            default:
                EmptyView()
            }
        }
        
        Divider()
        
        Button("Show Sync Details") {
            // This could show detailed sync information
        }
    }
    
    private var statusColor: Color {
        guard let videoID = video.id,
              let syncStatus = syncEngine.videoStatuses[videoID] else {
            // Fall back to file status colors
            switch iCloudStatus {
            case .unknown: return .gray
            case .notUbiquitous: return .primary
            case .downloaded, .current, .uploaded: return .green
            case .notDownloaded: return .blue
            case .downloading, .uploading: return .orange
            case .conflicts: return .yellow
            case .error: return .red
            }
        }
        
        // Use sync status colors when available
        switch syncStatus {
        case .local:
            return .primary
        case .synced:
            return .green
        case .uploading, .downloading, .retrying:
            return .blue
        case .conflict:
            return .yellow
        case .error:
            return .red
        }
    }
    
    private var syncStatusOpacity: Double {
        guard let videoID = video.id,
              let syncStatus = syncEngine.videoStatuses[videoID] else {
            return 1.0
        }
        
        // Dim the base icon when sync operations are in progress
        switch syncStatus {
        case .uploading, .downloading, .retrying:
            return 0.6
        default:
            return 1.0
        }
    }
    
    private var helpText: String {
        guard let videoID = video.id,
              let syncStatus = syncEngine.videoStatuses[videoID] else {
            return iCloudStatus.displayName
        }
        
        let baseStatus = iCloudStatus.displayName
        let syncDescription: String
        
        switch syncStatus {
        case .local:
            syncDescription = "Local only - click to upload"
        case .synced:
            syncDescription = "Synced"
        case .uploading(let progress):
            syncDescription = "Uploading (\(Int(progress * 100))%)"
        case .downloading(let progress):
            syncDescription = "Downloading (\(Int(progress * 100))%)"
        case .conflict:
            syncDescription = "Sync conflict - right-click to resolve"
        case .error(let error):
            syncDescription = "Sync error: \(error.message)"
        case .retrying:
            syncDescription = "Retrying sync..."
        }
        
        return "\(baseStatus) • \(syncDescription)"
    }
    
    @MainActor
    private func updateiCloudStatus() async {
        guard let fileURL = video.fileURL else {
            iCloudStatus = .unknown
            return
        }
        
        do {
            let status = try await GetiCloudFileStatus.status(for: fileURL)
            iCloudStatus = status.status
        } catch {
            iCloudStatus = .error
        }
    }
}

#Preview {
    let tempURL = FileManager.default.temporaryDirectory
    let tempStack = try! CoreDataStack.getInstance(for: tempURL)
    let syncEngine = PangolinSyncEngine(localStore: tempStack, libraryURL: tempURL)
    
    return VideoSyncStatusView(video: Video())
        .environmentObject(syncEngine)
        .frame(width: 50, height: 30)
}