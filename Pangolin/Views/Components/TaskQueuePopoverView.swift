//
//  TaskQueuePopoverView.swift
//  Pangolin
//
//  Browser-style task queue popover
//

import SwiftUI

struct TaskQueuePopoverView: View {
    @StateObject private var taskManager = TaskQueueManager.shared
    @EnvironmentObject private var syncEngine: PangolinSyncEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Background Tasks")
                    .font(.headline)
                
                if taskManager.hasActiveTasks {
                    Text("(\(taskManager.activeTaskCount) active)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if !taskManager.taskGroups.filter({ !$0.isActive }).isEmpty {
                    Button("Clear Completed") {
                        taskManager.clearCompletedTasks()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            // Task Groups List  
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Regular Tasks
                    ForEach(taskManager.taskGroups) { group in
                        TaskGroupRowView(group: group)
                        
                        if group.id != taskManager.taskGroups.last?.id || hasSyncTasks {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    
                    // Sync Tasks
                    if hasSyncTasks {
                        SyncTasksSection(syncEngine: syncEngine)
                    }
                    
                    // Empty state
                    if taskManager.taskGroups.isEmpty && !hasSyncTasks {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No active tasks")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(.regularMaterial)
        #endif
    }
    
    private var hasSyncTasks: Bool {
        switch syncEngine.syncStatus {
        case .syncing:
            return true
        case .error:
            return true
        default:
            return !syncEngine.pendingUploads.isEmpty || !syncEngine.pendingDownloads.isEmpty
        }
    }
}

struct TaskGroupRowView: View {
    @ObservedObject var group: TaskGroup
    @StateObject private var taskManager = TaskQueueManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Task icon
                Image(systemName: group.icon)
                    .font(.title3)
                    .foregroundStyle(group.isActive ? .primary : .secondary)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Task name
                    Text(group.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    // Progress bar
                    ProgressView(value: group.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 6)
                    
                    // Current file and percentage
                    HStack {
                        if !group.currentItem.isEmpty {
                            Text("Current: \(group.currentItem)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        Text("\(Int(group.progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                
                // Cancel button
                if group.isActive && group.canCancel {
                    Button {
                        Task {
                            await taskManager.cancelTaskGroup(id: group.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .help("Cancel task")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
        )
        .opacity(group.isActive ? 1.0 : 0.6)
    }
}

// MARK: - Sync Tasks Section

struct SyncTasksSection: View {
    @ObservedObject var syncEngine: PangolinSyncEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Upload tasks
            if !syncEngine.pendingUploads.isEmpty {
                SyncTaskRowView(
                    icon: "icloud.and.arrow.up",
                    title: "Uploading to iCloud",
                    progress: syncEngine.uploadProgress,
                    itemCount: syncEngine.pendingUploads.count,
                    isActive: syncEngine.syncStatus == .syncing
                )
                
                if !syncEngine.pendingDownloads.isEmpty {
                    Divider()
                        .padding(.leading, 16)
                }
            }
            
            // Download tasks
            if !syncEngine.pendingDownloads.isEmpty {
                SyncTaskRowView(
                    icon: "icloud.and.arrow.down",
                    title: "Downloading from iCloud",
                    progress: syncEngine.downloadProgress,
                    itemCount: syncEngine.pendingDownloads.count,
                    isActive: syncEngine.syncStatus == .syncing
                )
            }
            
            // Error state
            if case .error(let errors) = syncEngine.syncStatus {
                Divider()
                    .padding(.leading, 16)
                
                SyncErrorRowView(errors: errors, syncEngine: syncEngine)
            }
        }
    }
}

struct SyncTaskRowView: View {
    let icon: String
    let title: String
    let progress: Double
    let itemCount: Int
    let isActive: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Sync icon
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isActive ? .blue : .secondary)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Task name
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    // Progress bar
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(height: 6)
                        .tint(.blue)
                    
                    // Item count and percentage
                    HStack {
                        Text("\(itemCount) video\(itemCount != 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isActive ? 1.0 : 0.6)
    }
}

struct SyncErrorRowView: View {
    let errors: [SyncError]
    @ObservedObject var syncEngine: PangolinSyncEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Error icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Error title
                    Text("Sync Errors")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    // Error count
                    Text("\(errors.count) error\(errors.count != 1 ? "s" : "") occurred")
                        .font(.caption)
                        .foregroundStyle(.red)
                    
                    // Most recent error
                    if let latestError = errors.first {
                        Text(latestError.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                
                // Retry button
                Button("Retry") {
                    Task {
                        await syncEngine.retryFailedSyncs()
                    }
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    TaskQueuePopoverView()
        .onAppear {
            // Add some sample tasks for preview
            let manager = TaskQueueManager.shared
            let importId = manager.startTaskGroup(type: .importing, totalItems: 13)
            Task {
                await manager.updateTaskGroup(id: importId, completedItems: 8, currentItem: "video_file_001.mp4")
            }
            
            let transcribeId = manager.startTaskGroup(type: .transcribing, totalItems: 5)
            Task {
                await manager.updateTaskGroup(id: transcribeId, completedItems: 2, currentItem: "interview_part_2.mp4")
            }
            
            let thumbId = manager.startTaskGroup(type: .generatingThumbnails, totalItems: 1)
            Task {
                await manager.updateTaskGroup(id: thumbId, completedItems: 0, currentItem: "presentation.mov")
            }
        }
}