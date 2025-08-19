//
//  HierarchicalContent.swift
//  Pangolin
//
//  Created by Claude on 19/08/2025.
//

import Foundation
import SwiftUI

// MARK: - Hierarchical Content Model for OutlineGroup/hierarchical List

/// Represents content items in a hierarchical structure for use with SwiftUI OutlineGroup
struct HierarchicalContentItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let contentType: ContentType
    var children: [HierarchicalContentItem]?
    
    /// Initialize from a folder (with potential children)
    init(folder: Folder) {
        self.id = folder.id
        self.name = folder.name
        self.contentType = .folder(folder)
        
        // Combine child folders and videos into hierarchical structure
        var childItems: [HierarchicalContentItem] = []
        
        // Add child folders (which can have their own children)
        for childFolder in folder.childFoldersArray {
            childItems.append(HierarchicalContentItem(folder: childFolder))
        }
        
        // Add videos (leaf nodes - no children)
        for video in folder.videosArray {
            childItems.append(HierarchicalContentItem(video: video))
        }
        
        // Set children to nil if empty (indicates leaf node for OutlineGroup)
        self.children = childItems.isEmpty ? nil : childItems
    }
    
    /// Initialize from a video (leaf node)
    init(video: Video) {
        self.id = video.id
        self.name = video.title
        self.contentType = .video(video)
        self.children = nil // Videos are always leaf nodes
    }
    
    /// Whether this item has children (for disclosure triangle display)
    var hasChildren: Bool {
        return children != nil
    }
    
    /// Whether this represents a folder
    var isFolder: Bool {
        if case .folder = contentType { return true }
        return false
    }
    
    /// Get the underlying folder (if this is a folder item)
    var folder: Folder? {
        if case .folder(let folder) = contentType { return folder }
        return nil
    }
    
    /// Get the underlying video (if this is a video item)
    var video: Video? {
        if case .video(let video) = contentType { return video }
        return nil
    }
}

// MARK: - Extensions for SwiftUI Integration

extension HierarchicalContentItem {
    /// Static keypath for children (required by hierarchical List)
    static let childrenKeyPath: WritableKeyPath<HierarchicalContentItem, [HierarchicalContentItem]?> = \.children
}