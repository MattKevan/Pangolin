import Foundation

enum ProcessingTaskType: String, CaseIterable, Codable {
    case importVideo = "import_video"
    case generateThumbnail = "generate_thumbnail"
    case transcribe = "transcribe"
    case translate = "translate"
    case summarize = "summarize"
    case ensureLocalAvailability = "ensure_local_availability"
    case fileOperation = "file_operation"
    
    var displayName: String {
        switch self {
        case .importVideo: return "Import"
        case .generateThumbnail: return "Thumbnail"
        case .transcribe: return "Transcription"
        case .translate: return "Translation"
        case .summarize: return "Summary"
        case .ensureLocalAvailability: return "Ensure Local Availability"
        case .fileOperation: return "File Operation"
        }
    }
    
    var systemImage: String {
        switch self {
        case .importVideo: return "square.and.arrow.down"
        case .generateThumbnail: return "photo"
        case .transcribe: return "waveform"
        case .translate: return "translate"
        case .summarize: return "doc.text.below.ecg"
        case .ensureLocalAvailability: return "arrow.down.circle"
        case .fileOperation: return "folder"
        }
    }
    
    var dependencies: [ProcessingTaskType] {
        switch self {
        case .importVideo:
            return []
        case .generateThumbnail:
            return [.ensureLocalAvailability]
        case .transcribe:
            return [.ensureLocalAvailability]
        case .translate:
            return [.transcribe]
        case .summarize:
            return [.transcribe] // Can work with either original or translated text
        case .ensureLocalAvailability:
            return [] // local availability checks are independent
        case .fileOperation:
            return []
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
class ProcessingTask: ObservableObject, Identifiable, @preconcurrency Codable {
    let id: UUID
    let videoID: UUID?
    let sourceURLPath: String?
    let libraryID: UUID?
    let type: ProcessingTaskType
    let itemName: String?
    let force: Bool
    let followUpTypes: [ProcessingTaskType]
    let preferredLocaleIdentifier: String?
    let targetLocaleIdentifier: String?
    @Published var status: ProcessingTaskStatus
    @Published var progress: Double
    @Published var errorMessage: String?
    @Published var statusMessage: String
    let createdAt: Date
    @Published var startedAt: Date?
    @Published var completedAt: Date?
    
    init(videoID: UUID, type: ProcessingTaskType, itemName: String? = nil, force: Bool = false, followUpTypes: [ProcessingTaskType] = [], preferredLocaleIdentifier: String? = nil, targetLocaleIdentifier: String? = nil) {
        self.id = UUID()
        self.videoID = videoID
        self.sourceURLPath = nil
        self.libraryID = nil
        self.type = type
        self.itemName = itemName
        self.force = force
        self.followUpTypes = followUpTypes
        self.preferredLocaleIdentifier = preferredLocaleIdentifier
        self.targetLocaleIdentifier = targetLocaleIdentifier
        self.status = .pending
        self.progress = 0.0
        self.errorMessage = nil
        self.statusMessage = "Waiting to start..."
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
    }

    init(sourceURL: URL, libraryID: UUID?, type: ProcessingTaskType, itemName: String? = nil, force: Bool = false, followUpTypes: [ProcessingTaskType] = []) {
        self.id = UUID()
        self.videoID = nil
        self.sourceURLPath = sourceURL.path
        self.libraryID = libraryID
        self.type = type
        self.itemName = itemName
        self.force = force
        self.followUpTypes = followUpTypes
        self.preferredLocaleIdentifier = nil
        self.targetLocaleIdentifier = nil
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
        case id, videoID, sourceURLPath, libraryID, type, itemName, force, followUpTypes, preferredLocaleIdentifier, targetLocaleIdentifier, status, progress, errorMessage, statusMessage
        case createdAt, startedAt, completedAt
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        videoID = try container.decodeIfPresent(UUID.self, forKey: .videoID)
        sourceURLPath = try container.decodeIfPresent(String.self, forKey: .sourceURLPath)
        libraryID = try container.decodeIfPresent(UUID.self, forKey: .libraryID)
        type = try container.decode(ProcessingTaskType.self, forKey: .type)
        itemName = try container.decodeIfPresent(String.self, forKey: .itemName)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        followUpTypes = try container.decodeIfPresent([ProcessingTaskType].self, forKey: .followUpTypes) ?? []
        preferredLocaleIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredLocaleIdentifier)
        targetLocaleIdentifier = try container.decodeIfPresent(String.self, forKey: .targetLocaleIdentifier)
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
        try container.encodeIfPresent(videoID, forKey: .videoID)
        try container.encodeIfPresent(sourceURLPath, forKey: .sourceURLPath)
        try container.encodeIfPresent(libraryID, forKey: .libraryID)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(itemName, forKey: .itemName)
        try container.encode(force, forKey: .force)
        try container.encode(followUpTypes, forKey: .followUpTypes)
        try container.encodeIfPresent(preferredLocaleIdentifier, forKey: .preferredLocaleIdentifier)
        try container.encodeIfPresent(targetLocaleIdentifier, forKey: .targetLocaleIdentifier)
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
        case .importVideo: return 20.0
        case .generateThumbnail: return 5.0
        case .transcribe: return 30.0 // Depends on video length
        case .translate: return 10.0
        case .summarize: return 15.0
        case .ensureLocalAvailability: return 20.0 // Depends on file size and network speed
        case .fileOperation: return 10.0
        }
    }
    
    var displayTitle: String {
        if let itemName, !itemName.isEmpty {
            return "\(type.displayName): \(itemName)"
        }
        return "\(type.displayName)"
    }

    var uniqueKey: String {
        if let videoID {
            return "video:\(videoID.uuidString):\(type.rawValue)"
        }
        if let sourceURLPath {
            return "source:\(sourceURLPath):\(type.rawValue)"
        }
        return "task:\(id.uuidString):\(type.rawValue)"
    }
}
