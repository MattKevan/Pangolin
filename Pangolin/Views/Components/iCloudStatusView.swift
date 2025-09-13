//
//  iCloudStatusView.swift
//  Pangolin
//
//  Comprehensive iCloud status display following Apple's best practices
//  Uses proper URLResourceKey APIs for accurate status tracking
//

import SwiftUI
import Foundation

// MARK: - Comprehensive iCloud Status

struct iCloudStatusView: View {
    let video: Video
    @EnvironmentObject var videoFileManager: VideoFileManager
    @State private var iCloudStatus: iCloudFileStatus = .unknown
    @State private var downloadProgress: Double = 0.0
    @State private var showingDownloadAlert = false
    
    var body: some View {
        HStack(spacing: 4) {
            statusIcon
                .font(.system(size: 12))
                .foregroundColor(statusColor)
            
            if iCloudStatus == .downloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 30, height: 2)
                    .scaleEffect(0.8)
            }
            
            // Action button for non-downloaded files
            if iCloudStatus == .notDownloaded {
                Button(action: downloadVideo) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("Download from iCloud")
            }
        }
        .task {
            await updateiCloudStatus()
        }
        .onChange(of: video) {
            Task { await updateiCloudStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { _ in
            Task { await updateiCloudStatus() }
        }
        .alert("Download Error", isPresented: $showingDownloadAlert) {
            Button("OK") { }
        } message: {
            Text("Failed to download the video from iCloud. Please check your internet connection.")
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch iCloudStatus {
        case .unknown:
            Image(systemName: "questionmark.circle")
        case .notUbiquitous:
            Image(systemName: "internaldrive")
        case .downloaded, .current:
            Image(systemName: "checkmark.circle.fill")
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down")
        case .downloading:
            Image(systemName: "icloud.and.arrow.down.fill")
        case .uploading:
            Image(systemName: "icloud.and.arrow.up.fill")
        case .uploaded:
            Image(systemName: "icloud.fill")
        case .conflicts:
            Image(systemName: "exclamationmark.triangle.fill")
        case .error:
            Image(systemName: "xmark.circle.fill")
        }
    }
    
    private var statusColor: Color {
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
    
    @MainActor
    private func updateiCloudStatus() async {
        guard let fileURL = video.fileURL else {
            iCloudStatus = .unknown
            return
        }
        
        do {
            let status = try await GetiCloudFileStatus.status(for: fileURL)
            iCloudStatus = status.status
            downloadProgress = status.downloadProgress
        } catch {
            print("Failed to get iCloud status: \(error)")
            iCloudStatus = .error
        }
    }
    
    private func downloadVideo() {
        guard video.fileURL != nil else { return }
        
        Task {
            do {
                _ = try await videoFileManager.getVideoFileURL(for: video, downloadIfNeeded: true)
                await updateiCloudStatus()
            } catch {
                print("Failed to download video: \(error)")
                showingDownloadAlert = true
            }
        }
    }
}

// MARK: - Comprehensive iCloud Status Types

enum iCloudFileStatus {
    case unknown
    case notUbiquitous        // Local file, not in iCloud
    case downloaded           // Downloaded and current
    case current             // Same as downloaded (Apple's terminology)
    case notDownloaded       // In iCloud but not downloaded locally
    case downloading         // Currently downloading
    case uploading           // Currently uploading
    case uploaded            // Uploaded to iCloud
    case conflicts           // Has unresolved conflicts
    case error              // Error state
    
    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .notUbiquitous: return "Local"
        case .downloaded, .current: return "Downloaded"
        case .notDownloaded: return "In iCloud"
        case .downloading: return "Downloading"
        case .uploading: return "Uploading"
        case .uploaded: return "Uploaded"
        case .conflicts: return "Conflicts"
        case .error: return "Error"
        }
    }
    
    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .notUbiquitous: return "internaldrive"
        case .downloaded, .current: return "checkmark.circle.fill"
        case .notDownloaded: return "icloud.and.arrow.down"
        case .downloading: return "icloud.and.arrow.down.fill"
        case .uploading: return "icloud.and.arrow.up.fill"
        case .uploaded: return "icloud.fill"
        case .conflicts: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

struct iCloudStatusResult {
    let status: iCloudFileStatus
    let downloadProgress: Double
    let error: Error?
}

// MARK: - Proper iCloud Status Checker (Following Apple's Best Practices)

struct GetiCloudFileStatus {
    static func status(for url: URL) async throws -> iCloudStatusResult {
        let resourceKeys: [URLResourceKey] = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemDownloadingErrorKey,
            .ubiquitousItemUploadingErrorKey,
            // Note: ubiquitousItemPercentDownloadedKey is deprecated in macOS
        ]
        
        do {
            let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
            
            // Check if file is ubiquitous (in iCloud)
            guard resourceValues.isUbiquitousItem == true else {
                return iCloudStatusResult(status: .notUbiquitous, downloadProgress: 1.0, error: nil)
            }
            
            // Check for conflicts first
            if resourceValues.ubiquitousItemHasUnresolvedConflicts == true {
                return iCloudStatusResult(status: .conflicts, downloadProgress: 0.0, error: nil)
            }
            
            // Check for errors
            if let downloadError = resourceValues.ubiquitousItemDownloadingError {
                return iCloudStatusResult(status: .error, downloadProgress: 0.0, error: downloadError)
            }
            
            if let uploadError = resourceValues.ubiquitousItemUploadingError {
                return iCloudStatusResult(status: .error, downloadProgress: 0.0, error: uploadError)
            }
            
            // Check upload status
            if resourceValues.ubiquitousItemIsUploading == true {
                return iCloudStatusResult(status: .uploading, downloadProgress: 0.0, error: nil)
            }
            
            if resourceValues.ubiquitousItemIsUploaded == true {
                return iCloudStatusResult(status: .uploaded, downloadProgress: 1.0, error: nil)
            }
            
            // Check download status
            if resourceValues.ubiquitousItemIsDownloading == true {
                // Progress tracking not available in macOS - using indeterminate progress
                return iCloudStatusResult(status: .downloading, downloadProgress: 0.5, error: nil)
            }
            
            // Check detailed download status using Apple's proper API
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                switch downloadStatus {
                case URLUbiquitousItemDownloadingStatus.current:
                    return iCloudStatusResult(status: .current, downloadProgress: 1.0, error: nil)
                case URLUbiquitousItemDownloadingStatus.downloaded:
                    return iCloudStatusResult(status: .downloaded, downloadProgress: 1.0, error: nil)
                case URLUbiquitousItemDownloadingStatus.notDownloaded:
                    return iCloudStatusResult(status: .notDownloaded, downloadProgress: 0.0, error: nil)
                default:
                    return iCloudStatusResult(status: .unknown, downloadProgress: 0.0, error: nil)
                }
            }
            
            return iCloudStatusResult(status: .unknown, downloadProgress: 0.0, error: nil)
            
        } catch {
            return iCloudStatusResult(status: .error, downloadProgress: 0.0, error: error)
        }
    }
}

// MARK: - Compact iCloud Status for Table Cells

struct CompactiCloudStatusView: View {
    let video: Video
    @EnvironmentObject var videoFileManager: VideoFileManager
    @State private var iCloudStatus: iCloudFileStatus = .unknown
    
    var body: some View {
        statusIcon
            .font(.system(size: 11))
            .foregroundColor(statusColor)
            .help(iCloudStatus.displayName)
            .task {
                await updateiCloudStatus()
            }
            .onChange(of: video) {
                Task { await updateiCloudStatus() }
            }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: iCloudStatus.systemImage)
    }
    
    private var statusColor: Color {
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
    // Preview would need mock data
    HStack {
        CompactiCloudStatusView(video: Video())
        iCloudStatusView(video: Video())
    }
}