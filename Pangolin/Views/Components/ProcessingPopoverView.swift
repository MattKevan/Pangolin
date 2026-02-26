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

    private var cloudSyncStatus: ProcessingQueueManager.CloudSyncQueueStatus? {
        processingManager.cloudSyncQueueStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            if activeTasks.isEmpty && failedTasks.isEmpty && transferIssues.isEmpty && cloudSyncStatus == nil {
                Text("No active tasks")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                if let cloudSyncStatus {
                    CloudSyncStatusRow(status: cloudSyncStatus)

                    if !activeTasks.isEmpty || !transferIssues.isEmpty || !failedTasks.isEmpty {
                        Divider()
                    }
                }

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
                        Text("Transfer issues")
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
                        Text("Failed tasks")
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
                        Button("Retry issues") {
                            Task {
                                await videoFileManager.retryAllFailedTransfers(in: library)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !failedTasks.isEmpty {
                        Button("Retry failed") {
                            for task in failedTasks {
                                processingManager.retryTask(task)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !failedTasks.isEmpty || !transferIssues.isEmpty {
                        Button("Clear issues") {
                            processingManager.clearFailed()
                            videoFileManager.clearAllTransferIssues()
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

private struct CloudSyncStatusRow: View {
    let status: ProcessingQueueManager.CloudSyncQueueStatus

    private var tintColor: Color {
        switch status.phase {
        case .syncing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    private var titleText: String {
        status.phase == .syncing ? "iCloud sync" : "iCloud sync status"
    }

    var body: some View {
        HStack(spacing: 8) {
            

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(titleText)
                        .font(.caption)
                        .fontWeight(.medium)

                    Spacer()

                    if status.isActive {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }

                Text(status.detail)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
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
            

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(primaryTitleText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    
                }

                if task.status == .processing || task.status == .paused || task.status == .completed {
                    progressIndicator
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

    @ViewBuilder
    private var progressIndicator: some View {
        switch progressPresentation {
        case .determinate(let value):
            ProgressView(value: value)
                .progressViewStyle(LinearProgressViewStyle())
                .scaleEffect(y: 0.5)
        case .indeterminate:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
                    .scaleEffect(y: 0.5)

                if let detail = indeterminateDetailText {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private enum ProgressPresentation {
        case determinate(Double)
        case indeterminate
    }

    private var progressPresentation: ProgressPresentation {
        if task.status == .completed {
            return .determinate(1.0)
        }

        if usesDeterminateProgress {
            return .determinate(task.progress)
        }

        return .indeterminate
    }

    private var usesDeterminateProgress: Bool {
        switch task.type {
        case .downloadRemoteVideo:
            return true
        case .ensureLocalAvailability:
            return true
        case .transcribe, .translate, .summarize, .generateThumbnail, .importVideo, .fileOperation:
            return false
        }
    }

    private var primaryTitleText: String {
        guard task.status.isActive,
              let itemName = sanitizedItemName else {
            return task.type.displayName
        }

        let verb: String
        switch task.type {
        case .downloadRemoteVideo:
            verb = "Downloading"
        case .importVideo:
            verb = "Importing"
        case .generateThumbnail:
            verb = "Generating thumbnail for"
        case .transcribe:
            verb = "Transcribing"
        case .translate:
            verb = "Translating"
        case .summarize:
            verb = "Summarising"
        case .ensureLocalAvailability:
            verb = "Downloading from iCloud"
        case .fileOperation:
            verb = "Processing"
        }

        if task.status == .paused {
            return "\(verb) \(itemName) (Paused)"
        }
        return "\(verb) \(itemName)"
    }

    private var indeterminateDetailText: String? {
        if task.status == .paused {
            return task.statusMessage
        }

        // For active tasks, the title already includes the action + item name.
        if task.status == .processing || task.status == .waitingForDependencies || task.status == .pending {
            return nil
        }

        return task.statusMessage
    }

    private var sanitizedItemName: String? {
        guard let itemName = task.itemName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemName.isEmpty else {
            return nil
        }
        return itemName
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
