//
//  NotificationNames.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import Foundation

extension Notification.Name {
    /// Notification posted when the content of a folder or library has been updated (e.g., after an import).
    static let contentUpdated = Notification.Name("com.pangolin.contentUpdated")
}
