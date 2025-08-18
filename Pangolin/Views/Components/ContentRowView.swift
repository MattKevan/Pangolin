//
//  ContentRowView.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI

struct ContentRowView: View {
    let content: ContentType
    let isSelected: Bool
    let showCheckbox: Bool
    let viewMode: ViewMode
    @Binding var selectedItems: Set<UUID>
    
    @EnvironmentObject private var store: FolderNavigationStore
    @State private var isDropTargeted = false
    
    enum ViewMode {
        case grid
        case list
    }
    
    // The payload for dragging, which now correctly includes all selected items
    private var dragPayload: ContentTransfer {
        // If the dragged item is part of a larger selection, drag all selected items.
        // Otherwise, just drag the single item.
        if selectedItems.contains(content.id) {
            return ContentTransfer(itemIDs: Array(selectedItems))
        } else {
            return ContentTransfer(itemIDs: [content.id])
        }
    }
    
    var body: some View {
        Group {
            switch viewMode {
            case .grid:
                gridContent
            case .list:
                listContent
            }
        }
        .draggable(dragPayload)
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
            // Only folders can be drop targets
            guard case .folder(let folder) = content else { return false }
            
            if let provider = providers.first {
                let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                    if let data = data,
                       let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) {
                        
                        // Prevent dropping a folder onto itself or one of its own children
                        if !transfer.itemIDs.contains(folder.id) {
                            Task { @MainActor in
                                await store.moveItems(Set(transfer.itemIDs), to: folder.id)
                                // Force immediate UI update
                                NotificationCenter.default.post(name: .contentUpdated, object: nil)
                            }
                        }
                    }
                }
                return true
            }
            return false
        }
    }
    
    @ViewBuilder
    private var gridContent: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(content.isFolder ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                    .frame(height: 120)
                
                contentIcon
                    .font(.system(size: 40))
                    .foregroundColor(content.isFolder ? .blue : .primary)
                
                if showCheckbox {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isSelected ? .blue : .gray)
                                .background(Color.white)
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(content.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                if case .folder(let folder) = content {
                    Text("\(folder.itemCount) items")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if case .video(let video) = content {
                    Text(video.formattedDuration)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(isSelected && !showCheckbox ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private var listContent: some View {
        HStack {
            if showCheckbox {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
            }
            
            contentIcon
                .font(.system(size: 20))
                .foregroundColor(content.isFolder ? .blue : .primary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(content.name)
                    .lineLimit(1)
                
                HStack {
                    if case .folder(let folder) = content {
                        Text("\(folder.itemCount) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if case .video(let video) = content {
                        Text(video.formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(ByteCountFormatter().string(fromByteCount: video.fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected && !showCheckbox ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .overlay(
             RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private var contentIcon: some View {
        switch content {
        case .folder:
            Image(systemName: "folder.fill")
        case .video(let video):
            if let thumbnailURL = video.thumbnailURL,
               FileManager.default.fileExists(atPath: thumbnailURL.path) {
                AsyncImage(url: thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "video.fill")
                        .foregroundColor(.gray)
                }
                .frame(width: viewMode == .grid ? 80 : 20, height: viewMode == .grid ? 45 : 15)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .allowsHitTesting(false)
            } else {
                Image(systemName: "video.fill")
            }
        }
    }
}
