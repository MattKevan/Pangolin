// ProcessingQueueManager.swift
// Simplified stub for compatibility

import Foundation
import SwiftUI

// Simple stub to replace the complex processing queue
class ProcessingQueueManager: ObservableObject {
    static let shared = ProcessingQueueManager()

    @Published var activeTaskCount: Int = 0
    @Published var totalTaskCount: Int = 0
    @Published var queue: [ProcessingTask] = []
    @Published var isPaused: Bool = false
    @Published var overallProgress: Double = 0.0

    // Additional computed properties for compatibility
    var totalTasks: Int { totalTaskCount }
    var activeTasks: Int { activeTaskCount }
    var completedTasks: Int { 0 }
    var failedTasks: Int { 0 }

    private init() {}

    // Stub methods for compatibility
    func addTask(for video: Any, type: TaskType) {
        // No-op in simplified version
    }

    func removeTask(id: UUID) {
        // No-op in simplified version
    }

    func clearAllTasks() {
        // No-op in simplified version
    }

    func addTranscriptionOnly(for videos: [Any]) {
        // No-op in simplified version
    }

    func addTranslationOnly(for videos: [Any]) {
        // No-op in simplified version
    }

    func addThumbnailsOnly(for videos: [Any]) {
        // No-op in simplified version
    }

    func resumeProcessing() {
        isPaused = false
    }

    func pauseProcessing() {
        isPaused = true
    }

    func clearCompleted() {
        // No-op in simplified version
    }

    func retryTask(id: UUID) {
        // No-op in simplified version
    }

    func retryTask(_ task: ProcessingTask) {
        retryTask(id: task.id)
    }

    func clearFailed() {
        // No-op in simplified version
    }

    func cancelTask(_ task: ProcessingTask) {
        // No-op in simplified version
    }

    func cancelTask(id: UUID) {
        // No-op in simplified version
    }

    func removeTask(_ task: ProcessingTask) {
        removeTask(id: task.id)
    }

    func clearAll() {
        // No-op in simplified version
    }

    func addSummaryOnly(for videos: [Any]) {
        // No-op in simplified version
    }

    func togglePause() {
        isPaused.toggle()
    }

    func addFullProcessingWorkflow(for videos: [Any]) {
        // No-op in simplified version
    }

    func addTranscriptionAndSummary(for videos: [Any]) {
        // No-op in simplified version
    }
}

// Simple task type enum
enum TaskType {
    case iCloudDownload
    case thumbnailGeneration
    case transcription
    case constant // For compatibility
}