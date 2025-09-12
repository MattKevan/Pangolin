import Foundation

enum ProcessingTaskType: String, CaseIterable, Codable {
    case transcribe = "transcribe"
    case translate = "translate"
    case summarize = "summarize"
    case iCloudDownload = "icloud_download"
    
    var displayName: String {
        switch self {
        case .transcribe: return "Transcription"
        case .translate: return "Translation"
        case .summarize: return "Summary"
        case .iCloudDownload: return "iCloud Download"
        }
    }
    
    var systemImage: String {
        switch self {
        case .transcribe: return "waveform"
        case .translate: return "translate"
        case .summarize: return "doc.text.below.ecg"
        case .iCloudDownload: return "icloud.and.arrow.down"
        }
    }
    
    var dependencies: [ProcessingTaskType] {
        switch self {
        case .transcribe:
            return []
        case .translate:
            return [.transcribe]
        case .summarize:
            return [.transcribe] // Can work with either original or translated text
        case .iCloudDownload:
            return [] // iCloud downloads are independent
        }
    }
}

enum ProcessingTaskStatus: String, Codable {
    case pending = "pending"
    case waitingForDependencies = "waiting"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .waitingForDependencies: return "Waiting"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    
    var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .waitingForDependencies: return "clock.badge.exclamationmark"
        case .processing: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
    
    var isActive: Bool {
        switch self {
        case .pending, .waitingForDependencies, .processing:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

@MainActor
class ProcessingTask: ObservableObject, Identifiable, Codable {
    let id: UUID
    let videoID: UUID
    let type: ProcessingTaskType
    @Published var status: ProcessingTaskStatus
    @Published var progress: Double
    @Published var errorMessage: String?
    @Published var statusMessage: String
    let createdAt: Date
    @Published var startedAt: Date?
    @Published var completedAt: Date?
    
    init(videoID: UUID, type: ProcessingTaskType) {
        self.id = UUID()
        self.videoID = videoID
        self.type = type
        self.status = .pending
        self.progress = 0.0
        self.errorMessage = nil
        self.statusMessage = "Waiting to start..."
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, videoID, type, status, progress, errorMessage, statusMessage
        case createdAt, startedAt, completedAt
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        videoID = try container.decode(UUID.self, forKey: .videoID)
        type = try container.decode(ProcessingTaskType.self, forKey: .type)
        status = try container.decode(ProcessingTaskStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        statusMessage = try container.decode(String.self, forKey: .statusMessage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(videoID, forKey: .videoID)
        try container.encode(type, forKey: .type)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(statusMessage, forKey: .statusMessage)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
    
    // MARK: - Task Management
    
    func markAsStarted() {
        status = .processing
        startedAt = Date()
        progress = 0.0
        statusMessage = "Starting \(type.displayName.lowercased())..."
    }
    
    func updateProgress(_ newProgress: Double, message: String) {
        progress = max(0.0, min(1.0, newProgress))
        statusMessage = message
    }
    
    func markAsCompleted() {
        status = .completed
        progress = 1.0
        completedAt = Date()
        statusMessage = "\(type.displayName) completed successfully"
        errorMessage = nil
    }
    
    func markAsFailed(error: String) {
        status = .failed
        completedAt = Date()
        errorMessage = error
        statusMessage = "\(type.displayName) failed"
    }
    
    func markAsCancelled() {
        status = .cancelled
        completedAt = Date()
        statusMessage = "\(type.displayName) cancelled"
        errorMessage = nil
    }
    
    func reset() {
        status = .pending
        progress = 0.0
        errorMessage = nil
        statusMessage = "Waiting to start..."
        startedAt = nil
        completedAt = nil
    }
    
    var estimatedDuration: TimeInterval {
        switch type {
        case .transcribe: return 30.0 // Depends on video length
        case .translate: return 10.0
        case .summarize: return 15.0
        case .iCloudDownload: return 20.0 // Depends on file size and network speed
        }
    }
    
    var displayTitle: String {
        return "\(type.displayName)"
    }
}