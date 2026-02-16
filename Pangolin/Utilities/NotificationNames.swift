//
//  NotificationNames.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import Foundation

extension Notification.Name {
    static let triggerSearch = Notification.Name("com.pangolin.triggerSearch")
    static let triggerRename = Notification.Name("com.pangolin.triggerRename")
    static let triggerCreateFolder = Notification.Name("com.pangolin.triggerCreateFolder")
    static let triggerImportVideos = Notification.Name("com.pangolin.triggerImportVideos")

    /// Notification posted when the content of a folder or library has been updated (e.g., after an import).
    static let contentUpdated = Notification.Name("com.pangolin.contentUpdated")
}
