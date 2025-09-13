//
//  SyncStatusIndicator.swift
//  Pangolin
//
//  Sync status indicator for the main toolbar
//  Shows real-time CloudKit sync status and progress
//

import SwiftUI

struct SyncStatusIndicator: View {
    @ObservedObject var syncEngine: PangolinSyncEngine
    @State private var showSyncPopover = false
    
    var body: some View {
        Button {
            showSyncPopover.toggle()
        } label: {
            ZStack {
                // Main sync status icon
                syncStatusIcon
                    .font(.system(size: 14))
                    .foregroundColor(syncStatusColor)
                
                // Badge for pending operations count
                if syncBadgeCount > 0 {
                    Text("\(syncBadgeCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 12, height: 12)
                        .background(syncBadgeColor)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
                
                // Progress indicator overlay for active syncing
                if case .syncing = syncEngine.syncStatus {
                    ProgressView(value: overallProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                        .offset(x: -6, y: 6)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityLabel("Sync status")
            .accessibilityValue(accessibilityDescription)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSyncPopover, arrowEdge: .top) {
            SyncStatusPopoverView(syncEngine: syncEngine)
        }
        .help(helpText)
    }
    
    // MARK: - Computed Properties
    
    private var syncStatusIcon: Image {
        switch syncEngine.syncStatus {
        case .idle:
            return Image(systemName: "icloud")
        case .syncing:
            return Image(systemName: "arrow.triangle.2.circlepath.icloud")
        case .error:
            return Image(systemName: "icloud.slash")
        case .offline:
            return Image(systemName: "wifi.slash")
        case .accountIssue:
            return Image(systemName: "person.crop.circle.badge.exclamationmark")
        case .quotaExceeded:
            return Image(systemName: "icloud.fill")
        }
    }
    
    private var syncStatusColor: Color {
        switch syncEngine.syncStatus {
        case .idle:
            return .primary
        case .syncing:
            return .blue
        case .error:
            return .red
        case .offline:
            return .orange
        case .accountIssue:
            return .yellow
        case .quotaExceeded:
            return .red
        }
    }
    
    private var syncBadgeCount: Int {
        syncEngine.pendingUploads.count + syncEngine.pendingDownloads.count
    }
    
    private var syncBadgeColor: Color {
        switch syncEngine.syncStatus {
        case .error:
            return .red
        case .syncing:
            return .blue
        case .offline, .accountIssue:
            return .orange
        default:
            return .gray
        }
    }
    
    private var overallProgress: Double {
        let uploadProgress = syncEngine.uploadProgress
        let downloadProgress = syncEngine.downloadProgress
        return (uploadProgress + downloadProgress) / 2.0
    }
    
    private var helpText: String {
        switch syncEngine.syncStatus {
        case .idle:
            if syncBadgeCount > 0 {
                return "Sync: \(syncBadgeCount) pending operations"
            } else {
                return "Sync: Up to date"
            }
        case .syncing:
            return "Sync: In progress (\(Int(overallProgress * 100))%)"
        case .error(let errors):
            return "Sync: \(errors.count) error(s)"
        case .offline:
            return "Sync: Offline"
        case .accountIssue:
            return "Sync: iCloud account issue"
        case .quotaExceeded:
            return "Sync: iCloud storage full"
        }
    }
    
    private var accessibilityDescription: String {
        helpText
    }
}

// MARK: - Sync Status Popover

struct SyncStatusPopoverView: View {
    @ObservedObject var syncEngine: PangolinSyncEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "icloud")
                    .foregroundColor(.blue)
                Text("iCloud Sync")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // Overall Status
            HStack {
                Text("Status:")
                    .fontWeight(.medium)
                Spacer()
                statusLabel
            }
            
            // Account Status
            HStack {
                Text("iCloud Account:")
                    .fontWeight(.medium)
                Spacer()
                accountStatusLabel
            }
            
            // Progress Information
            if case .syncing = syncEngine.syncStatus {
                VStack(alignment: .leading, spacing: 8) {
                    if !syncEngine.pendingUploads.isEmpty {
                        HStack {
                            Text("Uploading:")
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(syncEngine.pendingUploads.count) videos")
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: syncEngine.uploadProgress)
                            .progressViewStyle(.linear)
                    }
                    
                    if !syncEngine.pendingDownloads.isEmpty {
                        HStack {
                            Text("Downloading:")
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(syncEngine.pendingDownloads.count) videos")
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: syncEngine.downloadProgress)
                            .progressViewStyle(.linear)
                    }
                }
            }
            
            // Recent Errors
            if case .error(let errors) = syncEngine.syncStatus, !errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Errors:")
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                    
                    ForEach(errors.prefix(3), id: \.id) { error in
                        Text("• \(error.message)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if errors.count > 3 {
                        Text("... and \(errors.count - 3) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Last Sync
            if let lastSync = syncEngine.lastSyncDate {
                HStack {
                    Text("Last Sync:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Action Buttons
            HStack {
                if case .error = syncEngine.syncStatus {
                    Button("Retry Failed") {
                        Task {
                            await syncEngine.retryFailedSyncs()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Spacer()
                
                Button("Manual Sync") {
                    Task {
                        await syncEngine.startSync()
                    }
                }
                .disabled(syncEngine.syncStatus == .syncing)
            }
        }
        .padding()
        .frame(width: 280)
    }
    
    private var statusLabel: some View {
        HStack(spacing: 4) {
            switch syncEngine.syncStatus {
            case .idle:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Up to date")
                    .foregroundColor(.green)
            case .syncing:
                ProgressView()
                    .controlSize(.mini)
                Text("Syncing...")
                    .foregroundColor(.blue)
            case .error(let errors):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text("\(errors.count) error(s)")
                    .foregroundColor(.red)
            case .offline:
                Image(systemName: "wifi.slash")
                    .foregroundColor(.orange)
                Text("Offline")
                    .foregroundColor(.orange)
            case .accountIssue:
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundColor(.yellow)
                Text("Account Issue")
                    .foregroundColor(.yellow)
            case .quotaExceeded:
                Image(systemName: "icloud.fill")
                    .foregroundColor(.red)
                Text("Storage Full")
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
    }
    
    private var accountStatusLabel: some View {
        HStack(spacing: 4) {
            switch syncEngine.accountStatus {
            case .available:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Available")
                    .foregroundColor(.green)
            case .noAccount:
                Image(systemName: "person.crop.circle.badge.minus")
                    .foregroundColor(.red)
                Text("Not Signed In")
                    .foregroundColor(.red)
            case .restricted:
                Image(systemName: "lock.circle")
                    .foregroundColor(.orange)
                Text("Restricted")
                    .foregroundColor(.orange)
            case .couldNotDetermine:
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.gray)
                Text("Unknown")
                    .foregroundColor(.gray)
            case .temporarilyUnavailable:
                Image(systemName: "clock.circle")
                    .foregroundColor(.yellow)
                Text("Temporarily Unavailable")
                    .foregroundColor(.yellow)
            @unknown default:
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.gray)
                Text("Unknown")
                    .foregroundColor(.gray)
            }
        }
        .font(.caption)
    }
}

#Preview {
    let tempURL = FileManager.default.temporaryDirectory
    let tempStack = try! CoreDataStack.getInstance(for: tempURL)
    let syncEngine = PangolinSyncEngine(localStore: tempStack, libraryURL: tempURL)
    
    return SyncStatusIndicator(syncEngine: syncEngine)
        .frame(width: 300, height: 200)
}