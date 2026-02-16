import SwiftUI

struct BulkProcessingView: View {
    @ObservedObject var processingManager: ProcessingQueueManager
    @Binding var isPresented: Bool
    
    @State private var selectedTasks: Set<UUID> = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with stats
                headerView
                
                Divider()
                
                // Task list
                if processingManager.queue.isEmpty {
                    emptyStateView
                } else {
                    taskListView
                }
                
                Divider()
                
                // Control buttons
                controlButtonsView
            }
            .navigationTitle("Processing Queue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear Completed") {
                        processingManager.clearCompleted()
                    }
                    .disabled(processingManager.completedTasks == 0)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queue Status")
                        .font(.headline)
                    Text(statusDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Overall progress circle
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                        .frame(width: 60, height: 60)
                    
                    Circle()
                        .trim(from: 0, to: processingManager.overallProgress)
                        .stroke(
                            progressColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: processingManager.overallProgress)
                    
                    Text("\(Int(processingManager.overallProgress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            
            // Progress stats
            HStack(spacing: 20) {
                StatView(
                    title: "Total",
                    value: processingManager.totalTasks,
                    color: .primary
                )
                
                StatView(
                    title: "Active",
                    value: processingManager.activeTasks,
                    color: .blue
                )
                
                StatView(
                    title: "Completed",
                    value: processingManager.completedTasks,
                    color: .green
                )
                
                StatView(
                    title: "Failed",
                    value: processingManager.failedTasks,
                    color: .red
                )
            }
        }
        .padding()
        #if os(macOS)
        .background(Color(NSColor.controlBackgroundColor))
        #else
        .background(.regularMaterial)
        #endif
    }
    
    // MARK: - Task List View
    
    private var taskListView: some View {
        List(processingManager.queue, id: \.id, selection: $selectedTasks) { task in
            TaskRowView(task: task, processingManager: processingManager)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listStyle(PlainListStyle())
        .contextMenu(forSelectionType: UUID.self) { selection in
            if !selection.isEmpty {
                taskContextMenu(for: selection)
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Processing Tasks")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("Select videos and choose processing options from the context menu to add tasks to the queue.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Control Buttons
    
    private var controlButtonsView: some View {
        HStack {
            // Pause/Resume button
            Button(processingManager.isPaused ? "Resume Processing" : "Pause Processing") {
                processingManager.togglePause()
            }
            .disabled(processingManager.activeTasks == 0)
            
            Spacer()
            
            // Clear buttons
            HStack(spacing: 8) {
                Button("Clear Failed") {
                    processingManager.clearFailed()
                }
                .disabled(processingManager.failedTasks == 0)
                
                Button("Clear All") {
                    processingManager.clearAll()
                }
                .disabled(processingManager.totalTasks == 0)
            }
        }
        .padding()
        #if os(macOS)
        .background(Color(NSColor.controlBackgroundColor))
        #else
        .background(.regularMaterial)
        #endif
    }
    
    // MARK: - Context Menu
    
    @ViewBuilder
    private func taskContextMenu(for selection: Set<UUID>) -> some View {
        let tasks = processingManager.queue.filter { selection.contains($0.id) }
        let failedTasks = tasks.filter { $0.status == .failed }
        let cancelableTasks = tasks.filter { $0.status.isActive }
        
        if !failedTasks.isEmpty {
            Button("Retry Failed") {
                for task in failedTasks {
                    processingManager.retryTask(task)
                }
            }
        }
        
        if !cancelableTasks.isEmpty {
            Button("Cancel") {
                for task in cancelableTasks {
                    processingManager.cancelTask(task)
                }
            }
        }
        
        Button("Remove from Queue") {
            for task in tasks {
                processingManager.removeTask(task)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var statusDescription: String {
        if processingManager.isPaused {
            return "Processing paused"
        } else if processingManager.activeTasks > 0 {
            return "Processing \(processingManager.activeTasks) task\(processingManager.activeTasks == 1 ? "" : "s")"
        } else if processingManager.totalTasks > 0 {
            return "All tasks completed"
        } else {
            return "Queue is empty"
        }
    }
    
    private var progressColor: Color {
        if processingManager.failedTasks > 0 {
            return .orange
        } else if processingManager.activeTasks > 0 {
            return .blue
        } else {
            return .green
        }
    }
}

// MARK: - Task Row View

struct TaskRowView: View {
    @ObservedObject var task: ProcessingTask
    let processingManager: ProcessingQueueManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Task icon
            Image(systemName: task.type.systemImage)
                .foregroundColor(taskTypeColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.displayTitle)
                        .font(.headline)
                    
                    Spacer()
                    
                    // Status icon
                    Image(systemName: task.status.systemImage)
                        .foregroundColor(statusColor)
                }
                
                Text(task.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if task.status == .processing || task.status == .completed {
                    ProgressView(value: task.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
                
                if let errorMessage = task.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
            
            // Action buttons
            HStack(spacing: 8) {
                if task.status == .failed {
                    Button("Retry") {
                        processingManager.retryTask(id: task.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if task.status.isActive {
                    Button("Cancel") {
                        processingManager.cancelTask(task)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Button("Remove") {
                    processingManager.removeTask(task)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        switch task.status {
        case .completed:
            return .green
        case .failed, .cancelled:
            return .red
        case .processing:
            return .blue
        case .pending, .waitingForDependencies:
            return .orange
        }
    }

    private var taskTypeColor: Color {
        switch task.type {
        case .importVideo: return .orange
        case .generateThumbnail: return .pink
        case .transcribe: return .blue
        case .translate: return .green
        case .summarize: return .purple
        case .ensureLocalAvailability: return .cyan
        case .fileOperation: return .gray
        }
    }
}

// MARK: - Stat View

struct StatView: View {
    let title: String
    let value: Int
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(color)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    BulkProcessingView(
        processingManager: ProcessingQueueManager.shared,
        isPresented: .constant(true)
    )
}
