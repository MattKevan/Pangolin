//
//  DeletionConfirmationView.swift
//  Pangolin
//
//  Created by Claude on 21/08/2025.
//

import SwiftUI

struct DeletionConfirmationView: View {
    let items: [DeletionItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.title2)
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            // Warning message
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
            
            // Items list (if more than 1 item or if we want to show names)
            if items.count > 1 || items.count == 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Items to delete:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(items.prefix(10), id: \.id) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.isFolder ? "folder" : "play.rectangle")
                                        .foregroundColor(item.isFolder ? .orange : .primary)
                                        .font(.caption)
                                    
                                    Text(item.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                            
                            if items.count > 10 {
                                Text("and \(items.count - 10) more...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            // Buttons
            HStack {
                Spacer()
                
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Button("Delete", role: .destructive) {
                    onConfirm()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }
    
    private var title: String {
        if items.count == 1 {
            return items.first!.isFolder ? "Delete Folder" : "Delete Video"
        } else {
            let folderCount = items.filter { $0.isFolder }.count
            let videoCount = items.count - folderCount
            
            if folderCount > 0 && videoCount > 0 {
                return "Delete \(items.count) Items"
            } else if folderCount > 0 {
                return "Delete \(folderCount) Folder\(folderCount == 1 ? "" : "s")"
            } else {
                return "Delete \(videoCount) Video\(videoCount == 1 ? "" : "s")"
            }
        }
    }
    
    private var message: String {
        let hasFolder = items.contains { $0.isFolder }
        let hasVideo = items.contains { !$0.isFolder }
        
        if items.count == 1 {
            if items.first!.isFolder {
                return "This folder and all its contents will be permanently deleted from your library and removed from disk. This action cannot be undone."
            } else {
                return "This video will be permanently deleted from your library and removed from disk. This action cannot be undone."
            }
        } else {
            var message = "These items will be permanently deleted from your library"
            if hasFolder && hasVideo {
                message += ". Folders and their contents will be removed from disk"
            } else if hasFolder {
                message += ". All folders and their contents will be removed from disk"
            } else {
                message += " and removed from disk"
            }
            message += ". This action cannot be undone."
            return message
        }
    }
}

struct DeletionItem {
    let id: UUID
    let name: String
    let isFolder: Bool
    
    init(folder: Folder) {
        self.id = folder.id!
        self.name = folder.name!
        self.isFolder = true
    }
    
    init(video: Video) {
        self.id = video.id!
        self.name = video.title!
        self.isFolder = false
    }
    
    init(id: UUID, name: String, isFolder: Bool) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
    }
}

#Preview {
    DeletionConfirmationView(
        items: [
            DeletionItem(id: UUID(), name: "Sample Folder", isFolder: true),
            DeletionItem(id: UUID(), name: "Sample Video.mp4", isFolder: false)
        ],
        onConfirm: {},
        onCancel: {}
    )
}