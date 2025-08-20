//
//  FolderTransfer.swift
//  Pangolin
//
//  Created by Matt Kevan on 17/08/2025.
//

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

struct FolderTransfer: Codable, Transferable {
    let id: UUID
    let name: String
    let parentId: UUID?
    
    init(folder: Folder) {
        self.id = folder.id!
        self.name = folder.name!
        self.parentId = folder.parentFolder?.id
    }
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}