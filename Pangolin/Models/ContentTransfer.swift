//
//  ContentTransfer.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import Foundation
import CoreTransferable

struct ContentTransfer: Codable, Transferable {
    let itemIDs: [UUID]
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}