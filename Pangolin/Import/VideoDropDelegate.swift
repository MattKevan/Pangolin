//
//  VideoDropDelegate.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Import/DragDropHandler.swift
import SwiftUI
import UniformTypeIdentifiers

final class ThreadSafeURLCollector {
    private var urls: [URL] = []
    private let lock = NSLock()

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func allURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

struct VideoDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let library: Library
    let importer: VideoImporter
    @EnvironmentObject var libraryManager: LibraryManager
    
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }
    
    func dropEntered(info: DropInfo) {
        isTargeted = true
    }
    
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        
        let providers = info.itemProviders(for: [.fileURL])
        let urlCollector = ThreadSafeURLCollector()
        
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urlCollector.append(url)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            Task {
                if let context = libraryManager.viewContext {
                    await importer.importFiles(urlCollector.allURLs(), to: library, context: context)
                }
            }
        }
        
        return true
    }
}
