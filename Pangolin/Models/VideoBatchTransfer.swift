//
//  VideoBatchTransfer.swift
//  Pangolin
//
//  Created by Matt Kevan on 17/08/2025.
//

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

struct VideoBatchTransfer: Codable, Transferable {
    let videoIds: [UUID]
    let titles: [String]
    let sourcePlaylistId: UUID?
    
    init(videos: [Video], sourcePlaylist: Playlist? = nil) {
        self.videoIds = videos.map { $0.id }
        self.titles = videos.map { $0.title }
        self.sourcePlaylistId = sourcePlaylist?.id
    }
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}