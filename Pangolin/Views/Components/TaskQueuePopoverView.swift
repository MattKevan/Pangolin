//
//  TaskQueuePopoverView.swift
//  Pangolin
//
//  Browser-style task queue popover
//

import SwiftUI

struct TaskQueuePopoverView: View {
    @StateObject private var taskManager = TaskQueueManager.shared
    
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
            if taskManager.taskGroups.isEmpty {
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
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(taskManager.taskGroups) { group in
                            TaskGroupRowView(group: group)
                            
                            if group.id != taskManager.taskGroups.last?.id {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
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