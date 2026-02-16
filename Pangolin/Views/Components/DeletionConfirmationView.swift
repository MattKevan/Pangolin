//
//  DeletionConfirmationView.swift
//  Pangolin
//
//  Shared delete-alert data models and messaging.
//

import Foundation

struct DeletionAlertContent {
    let title: String
    let message: String
}

struct DeletionItem: Identifiable {
    let id: UUID
    let name: String
    let isFolder: Bool

    init(folder: Folder) {
        self.id = folder.id ?? UUID()
        self.name = folder.name ?? "Unknown Folder"
        self.isFolder = true
    }

    init(video: Video) {
        self.id = video.id ?? UUID()
        self.name = video.title ?? "Unknown Video"
        self.isFolder = false
    }

    init(id: UUID, name: String, isFolder: Bool) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
    }
}

extension Array where Element == DeletionItem {
    var deletionAlertContent: DeletionAlertContent {
        guard !isEmpty else {
            return DeletionAlertContent(
                title: "Delete Item?",
                message: "This action cannot be undone."
            )
        }

        let folderCount = filter(\.isFolder).count
        let videoCount = count - folderCount
        let hasFolder = folderCount > 0
        let hasVideo = videoCount > 0

        let title: String
        if count == 1 {
            title = first?.isFolder == true ? "Delete Folder?" : "Delete Video?"
        } else if hasFolder && hasVideo {
            title = "Delete \(count) Items?"
        } else if hasFolder {
            title = "Delete \(folderCount) Folder\(folderCount == 1 ? "" : "s")?"
        } else {
            title = "Delete \(videoCount) Video\(videoCount == 1 ? "" : "s")?"
        }

        let message: String
        if count == 1 {
            if first?.isFolder == true {
                message = "This folder and all its contents will be permanently deleted from your library and removed from disk. This action cannot be undone."
            } else {
                message = "This video will be permanently deleted from your library and removed from disk. This action cannot be undone."
            }
        } else {
            var value = "These items will be permanently deleted from your library"
            if hasFolder && hasVideo {
                value += ". Folders and their contents will be removed from disk"
            } else if hasFolder {
                value += ". All folders and their contents will be removed from disk"
            } else {
                value += " and removed from disk"
            }
            value += ". This action cannot be undone."
            message = value
        }

        return DeletionAlertContent(title: title, message: message)
    }
}
