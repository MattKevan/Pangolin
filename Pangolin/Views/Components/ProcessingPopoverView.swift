import SwiftUI

struct ProcessingPopoverView: View {
    @ObservedObject var processingManager: ProcessingQueueManager
    @EnvironmentObject private var libraryManager: LibraryManager
    @StateObject private var videoFileManager = VideoFileManager.shared

    let onViewAllTapped: () -> Void

    init(processingManager: ProcessingQueueManager, onViewAllTapped: @escaping () -> Void = {}) {
        self.processingManager = processingManager
        self.onViewAllTapped = onViewAllTapped
    }

    private var activeTasks: [ProcessingTask] {
        processingManager.queue.filter { $0.status.isActive }
    }

    private var failedTasks: [ProcessingTask] {
        processingManager.queue.filter { $0.status == .failed || $0.status == .cancelled }
    }

    private var transferIssues: [VideoCloudTransferSnapshot] {
        videoFileManager.failedTransferSnapshots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if activeTasks.isEmpty && failedTasks.isEmpty && transferIssues.isEmpty {
                Text("No active tasks")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                if !activeTasks.isEmpty {
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
                }

                if !transferIssues.isEmpty {
                    if !activeTasks.isEmpty {
                        Divider()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transfer Issues")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(Array(transferIssues.prefix(3))) { issue in
                            TransferIssueRow(
                                issue: issue,
                                onRetry: {
                                    Task {
                                        await videoFileManager.retryTransfer(videoID: issue.videoID)
                                    }
                                }
                            )
                        }

                        if transferIssues.count > 3 {
                            Text("... and \(transferIssues.count - 3) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if !failedTasks.isEmpty {
                    if !activeTasks.isEmpty || !transferIssues.isEmpty {
                        Divider()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Failed Tasks")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(Array(failedTasks.prefix(3)), id: \.id) { task in
                            CompactTaskRowView(task: task)
                        }

                        if failedTasks.count > 3 {
                            Text("... and \(failedTasks.count - 3) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                HStack {
                    StatPill(title: "Active", count: processingManager.activeTasks, color: .blue)
                    StatPill(title: "Failed", count: processingManager.failedTasks, color: .red)
                    StatPill(title: "Issues", count: transferIssues.count, color: .orange)
                }

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

                    if transferIssues.count > 0,
                       let library = libraryManager.currentLibrary {
                        Button("Retry Issues") {
                            Task {
                                await videoFileManager.retryAllFailedTransfers(in: library)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !failedTasks.isEmpty {
                        Button("Retry Failed") {
                            for task in failedTasks {
                                processingManager.retryTask(task)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 360)
    }
}

private struct TransferIssueRow: View {
    let issue: VideoCloudTransferSnapshot
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.videoTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(issue.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Retry", action: onRetry)
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

// MARK: - Compact Task Row

struct CompactTaskRowView: View {
    @ObservedObject var task: ProcessingTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.type.systemImage)
                .foregroundColor(taskTypeColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(task.type.displayName)
                        .font(.caption)
                        .fontWeight(.medium)

                    Spacer()

                    Image(systemName: task.status.systemImage)
                        .foregroundColor(statusColor)
                        .font(.system(size: 10))
                }

                if task.status == .processing || task.status == .paused || task.status == .completed {
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
        case .downloadRemoteVideo: return .indigo
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
        case .paused: return .yellow
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

#Preview {
    ProcessingPopoverView(processingManager: ProcessingQueueManager.shared)
        .environmentObject(LibraryManager.shared)
}
