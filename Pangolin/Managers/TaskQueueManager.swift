//
//  TaskQueueManager.swift
//  Pangolin
//
//  Background task queue manager with grouped tasks
//

import Foundation
import SwiftUI

@MainActor
class TaskQueueManager: ObservableObject {
    static let shared = TaskQueueManager()
    
    @Published var taskGroups: [TaskGroup] = []
    
    private init() {}
    
    // MARK: - Public Interface
    
    var hasActiveTasks: Bool {
        !taskGroups.filter { $0.isActive }.isEmpty
    }
    
    var activeTaskCount: Int {
        taskGroups.filter { $0.isActive }.count
    }
    
    var overallProgress: Double {
        let activeGroups = taskGroups.filter { $0.isActive }
        guard !activeGroups.isEmpty else { return 0.0 }
        
        let totalProgress = activeGroups.reduce(0.0) { sum, group in
            sum + group.progress
        }
        return totalProgress / Double(activeGroups.count)
    }
    
    // MARK: - Task Group Management
    
    func startTaskGroup(type: TaskGroupType, totalItems: Int, canCancel: Bool = true) -> UUID {
        let group = TaskGroup(
            type: type,
            totalItems: totalItems,
            canCancel: canCancel
        )
        taskGroups.append(group)
        return group.id
    }
    
    func updateTaskGroup(id: UUID, completedItems: Int, currentItem: String) async {
        guard let group = taskGroups.first(where: { $0.id == id }) else { return }
        
        // Ensure updates happen on main thread
        await MainActor.run {
            group.completedItems = completedItems
            group.currentItem = currentItem
        }
    }
    
    func completeTaskGroup(id: UUID) async {
        guard let group = taskGroups.first(where: { $0.id == id }) else { return }
        
        // Ensure updates happen on main thread
        await MainActor.run {
            group.isActive = false
            group.completedItems = group.totalItems
            
            // Auto-remove completed groups after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.removeTaskGroup(id: id)
            }
        }
    }
    
    func cancelTaskGroup(id: UUID) async {
        guard let group = taskGroups.first(where: { $0.id == id }) else { return }
        
        // Ensure updates happen on main thread
        await MainActor.run {
            group.isActive = false
            
            // Notify services to cancel their operations
            NotificationCenter.default.post(
                name: .taskGroupCancelled,
                object: nil,
                userInfo: ["groupId": id, "type": group.type]
            )
            
            removeTaskGroup(id: id)
        }
    }
    
    func removeTaskGroup(id: UUID) {
        taskGroups.removeAll { $0.id == id }
    }
    
    func clearCompletedTasks() {
        taskGroups.removeAll { !$0.isActive }
    }
}

// MARK: - Task Group Model

class TaskGroup: ObservableObject, Identifiable {
    let id = UUID()
    let type: TaskGroupType
    
    @Published var totalItems: Int
    @Published var completedItems: Int = 0
    @Published var currentItem: String = ""
    @Published var isActive: Bool = true
    @Published var canCancel: Bool
    
    init(type: TaskGroupType, totalItems: Int, canCancel: Bool = true) {
        self.type = type
        self.totalItems = totalItems
        self.canCancel = canCancel
    }
    
    var progress: Double {
        guard totalItems > 0 else { return 0.0 }
        return Double(completedItems) / Double(totalItems)
    }
    
    var displayName: String {
        switch type {
        case .importing:
            return "Importing \(totalItems) file\(totalItems == 1 ? "" : "s")"
        case .transcribing:
            return "Transcribing \(totalItems) file\(totalItems == 1 ? "" : "s")"
        case .summarizing:
            return "Summarizing \(totalItems) file\(totalItems == 1 ? "" : "s")"
        case .generatingThumbnails:
            return "Generating thumbnails"
        case .fileOperations:
            return "File operations"
        }
    }
    
    var icon: String {
        switch type {
        case .importing:
            return "square.and.arrow.down"
        case .transcribing:
            return "waveform"
        case .summarizing:
            return "doc.text"
        case .generatingThumbnails:
            return "photo"
        case .fileOperations:
            return "folder"
        }
    }
}

// MARK: - Task Group Types

enum TaskGroupType: String, CaseIterable {
    case importing
    case transcribing
    case summarizing
    case generatingThumbnails
    case fileOperations
}

// MARK: - Notifications

extension Notification.Name {
    static let taskGroupCancelled = Notification.Name("taskGroupCancelled")
}