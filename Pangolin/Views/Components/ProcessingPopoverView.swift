import SwiftUI

struct ProcessingPopoverView: View {
    @ObservedObject var processingManager: ProcessingQueueManager
    let onViewAllTapped: () -> Void
    
    init(processingManager: ProcessingQueueManager, onViewAllTapped: @escaping () -> Void = {}) {
        self.processingManager = processingManager
        self.onViewAllTapped = onViewAllTapped
    }

    private var activeTasks: [ProcessingTask] {
        processingManager.queue.filter { $0.status.isActive }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Processing Queue")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("View All") {
                    onViewAllTapped()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            
            if activeTasks.isEmpty {
                Text("No active tasks")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Task list
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(activeTasks.prefix(5)), id: \.id) { task in
                        CompactTaskRowView(task: task)
                    }
                    
                    if activeTasks.count > 5 {
                        Text("... and \(activeTasks.count - 5) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Quick stats
                HStack {
                    StatPill(title: "Active", count: processingManager.activeTasks, color: .blue)
                }
                
                // Quick actions
                HStack {
                    if processingManager.isPaused {
                        Button("Resume") {
                            processingManager.resumeProcessing()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if processingManager.activeTasks > 0 {
                        Button("Pause") {
                            processingManager.pauseProcessing()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 280, maxWidth: 320)
    }
}

// MARK: - Compact Task Row

struct CompactTaskRowView: View {
    @ObservedObject var task: ProcessingTask
    
    var body: some View {
        HStack(spacing: 8) {
            // Task type icon
            Image(systemName: task.type.systemImage)
                .foregroundColor(taskTypeColor)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(task.type.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    // Status icon
                    Image(systemName: task.status.systemImage)
                        .foregroundColor(statusColor)
                        .font(.system(size: 10))
                }
                
                if task.status == .processing || task.status == .completed {
                    ProgressView(value: task.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .scaleEffect(y: 0.5)
                } else {
                    Text(task.statusMessage)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
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
    
    private var statusColor: Color {
        switch task.status {
        case .completed: return .green
        case .failed, .cancelled: return .red
        case .processing: return .blue
        case .pending, .waitingForDependencies: return .orange
        }
    }
}

// MARK: - Stat Pill

struct StatPill: View {
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    ProcessingPopoverView(processingManager: ProcessingQueueManager.shared)
}
