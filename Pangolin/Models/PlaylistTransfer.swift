//
//  PlaylistTransfer.swift
//  Pangolin
//
//  Created by Matt Kevan on 17/08/2025.
//

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

struct PlaylistTransfer: Codable, Transferable {
    let id: UUID
    let name: String
    let sortOrder: Int32
    let parentId: UUID?
    
    init(playlist: Playlist) {
        self.id = playlist.id
        self.name = playlist.name
        self.sortOrder = playlist.sortOrder
        self.parentId = playlist.parentPlaylist?.id
    }
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}