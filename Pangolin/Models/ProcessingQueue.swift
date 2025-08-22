import Foundation

@MainActor
class ProcessingQueue: ObservableObject {
    @Published private(set) var tasks: [ProcessingTask] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var isPaused = false
    
    private let maxConcurrentTasks = 2 // Limit concurrent processing to avoid overwhelming the system
    private var processingTaskIDs: Set<UUID> = []
    
    // MARK: - Queue Statistics
    
    var totalTasks: Int {
        tasks.count
    }
    
    var completedTasks: Int {
        tasks.filter { $0.status == .completed }.count
    }
    
    var failedTasks: Int {
        tasks.filter { $0.status == .failed }.count
    }
    
    var activeTasks: Int {
        tasks.filter { $0.status.isActive }.count
    }
    
    var overallProgress: Double {
        guard !tasks.isEmpty else { return 0.0 }
        let totalProgress = tasks.reduce(0.0) { $0 + $1.progress }
        return totalProgress / Double(tasks.count)
    }
    
    var currentlyProcessing: [ProcessingTask] {
        tasks.filter { $0.status == .processing }
    }
    
    var hasActiveTasks: Bool {
        activeTasks > 0
    }
    
    // MARK: - Task Management
    
    func addTask(_ task: ProcessingTask) {
        // Check if task already exists for this video and type
        if !tasks.contains(where: { $0.videoID == task.videoID && $0.type == task.type }) {
            tasks.append(task)
            updateTaskDependencies()
        }
    }
    
    func addTasks(_ newTasks: [ProcessingTask]) {
        for task in newTasks {
            addTask(task)
        }
    }
    
    func removeTask(_ task: ProcessingTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            let removedTask = tasks[index]
            
            // Cancel if currently processing
            if removedTask.status == .processing {
                removedTask.markAsCancelled()
                processingTaskIDs.remove(removedTask.id)
            }
            
            tasks.remove(at: index)
            updateTaskDependencies()
        }
    }
    
    func cancelTask(_ task: ProcessingTask) {
        task.markAsCancelled()
        processingTaskIDs.remove(task.id)
        updateTaskDependencies()
    }
    
    func retryTask(_ task: ProcessingTask) {
        guard task.status == .failed || task.status == .cancelled else { return }
        task.reset()
        updateTaskDependencies()
    }
    
    func clearCompleted() {
        tasks.removeAll { $0.status == .completed }
    }
    
    func clearFailed() {
        tasks.removeAll { $0.status == .failed }
    }
    
    func clearAll() {
        // Cancel any processing tasks
        for task in currentlyProcessing {
            task.markAsCancelled()
        }
        processingTaskIDs.removeAll()
        tasks.removeAll()
        isProcessing = false
    }
    
    // MARK: - Queue Control
    
    func pauseProcessing() {
        isPaused = true
    }
    
    func resumeProcessing() {
        isPaused = false
        updateTaskDependencies()
    }
    
    func togglePause() {
        if isPaused {
            resumeProcessing()
        } else {
            pauseProcessing()
        }
    }
    
    // MARK: - Dependency Management
    
    private func updateTaskDependencies() {
        guard !isPaused else { return }
        
        for task in tasks {
            guard task.status == .pending || task.status == .waitingForDependencies else { continue }
            
            if areDependenciesSatisfied(for: task) {
                task.status = .pending
            } else {
                task.status = .waitingForDependencies
                task.statusMessage = "Waiting for dependencies..."
            }
        }
        
        updateProcessingState()
    }
    
    private func areDependenciesSatisfied(for task: ProcessingTask) -> Bool {
        let dependencies = task.type.dependencies
        
        for dependencyType in dependencies {
            let dependencyTask = tasks.first { otherTask in
                otherTask.videoID == task.videoID && 
                otherTask.type == dependencyType
            }
            
            // If dependency task exists and is not completed, dependencies are not satisfied
            if let depTask = dependencyTask, depTask.status != .completed {
                return false
            }
            
            // If dependency task doesn't exist, check if the video already has the required data
            if dependencyTask == nil && !hasRequiredData(for: task.videoID, type: dependencyType) {
                return false
            }
        }
        
        return true
    }
    
    private func hasRequiredData(for videoID: UUID, type: ProcessingTaskType) -> Bool {
        // This would need to check the actual video object
        // For now, we'll assume that if no task exists, the data might already be available
        // This should be implemented to check the actual video's transcript/translation/summary status
        return false
    }
    
    private func updateProcessingState() {
        let wasProcessing = isProcessing
        isProcessing = hasActiveTasks && !isPaused
        
        // Notify if processing state changed
        if wasProcessing != isProcessing {
            objectWillChange.send()
        }
    }
    
    // MARK: - Task Retrieval
    
    func getReadyTasks() -> [ProcessingTask] {
        let availableSlots = max(0, maxConcurrentTasks - processingTaskIDs.count)
        guard availableSlots > 0, !isPaused else { return [] }
        
        return Array(tasks
            .filter { $0.status == .pending && areDependenciesSatisfied(for: $0) }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(availableSlots))
    }
    
    func markTaskAsProcessing(_ task: ProcessingTask) {
        processingTaskIDs.insert(task.id)
        task.markAsStarted()
        updateProcessingState()
    }
    
    func markTaskAsFinished(_ task: ProcessingTask) {
        processingTaskIDs.remove(task.id)
        updateTaskDependencies()
    }
    
    // MARK: - Bulk Operations
    
    func createTasksForVideo(_ videoID: UUID, types: [ProcessingTaskType]) -> [ProcessingTask] {
        let newTasks = types.map { ProcessingTask(videoID: videoID, type: $0) }
        addTasks(newTasks)
        return newTasks
    }
    
    func createTasksForVideos(_ videoIDs: [UUID], types: [ProcessingTaskType]) -> [ProcessingTask] {
        var allTasks: [ProcessingTask] = []
        for videoID in videoIDs {
            let tasks = createTasksForVideo(videoID, types: types)
            allTasks.append(contentsOf: tasks)
        }
        return allTasks
    }
    
    // MARK: - Persistence Support
    
    func getTasksData() -> Data? {
        try? JSONEncoder().encode(tasks)
    }
    
    func loadTasksData(_ data: Data) {
        if let loadedTasks = try? JSONDecoder().decode([ProcessingTask].self, from: data) {
            tasks = loadedTasks
            
            // Reset any tasks that were processing when the app was closed
            for task in tasks where task.status == .processing {
                task.reset()
            }
            
            processingTaskIDs.removeAll()
            updateTaskDependencies()
        }
    }
}

// MARK: - Queue Extensions

extension ProcessingQueue {
    func tasksForVideo(_ videoID: UUID) -> [ProcessingTask] {
        tasks.filter { $0.videoID == videoID }
    }
    
    func taskForVideo(_ videoID: UUID, type: ProcessingTaskType) -> ProcessingTask? {
        tasks.first { $0.videoID == videoID && $0.type == type }
    }
    
    func hasTask(for videoID: UUID, type: ProcessingTaskType) -> Bool {
        taskForVideo(videoID, type: type) != nil
    }
    
    func getTasksByStatus(_ status: ProcessingTaskStatus) -> [ProcessingTask] {
        tasks.filter { $0.status == status }
    }
    
    func getTasksSortedByPriority() -> [ProcessingTask] {
        tasks.sorted { first, second in
            // Prioritize by status first, then by creation date
            if first.status != second.status {
                return first.status.rawValue < second.status.rawValue
            }
            return first.createdAt < second.createdAt
        }
    }
}