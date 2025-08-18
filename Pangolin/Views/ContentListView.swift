//
//  ContentListView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

extension Notification.Name {
    static let contentUpdated = Notification.Name("contentUpdated")
}

struct ContentListView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject var libraryManager: LibraryManager
    let searchText: String
    
    
    var body: some View {
        #if os(macOS)
        macOSNavigationView
        #else
        iOSNavigationView
        #endif
    }
    
    @ViewBuilder
    private var macOSNavigationView: some View {
        NavigationStack(path: $store.navigationPath) {
            FolderContentView(folderID: store.selectedTopLevelFolder?.id)
                .environmentObject(store)
                .environmentObject(libraryManager)
                .navigationDestination(for: UUID.self) { folderID in
                    FolderContentView(folderID: folderID)
                        .environmentObject(store)
                        .environmentObject(libraryManager)
                }
        }
        .searchable(text: .constant(searchText), prompt: "Search videos")
    }
    
    @ViewBuilder
    private var iOSNavigationView: some View {
        NavigationStack(path: $store.navigationPath) {
            FolderContentView(folderID: store.selectedTopLevelFolder?.id)
                .environmentObject(store)
                .environmentObject(libraryManager)
                .navigationDestination(for: UUID.self) { folderID in
                    FolderContentView(folderID: folderID)
                        .environmentObject(store)
                        .environmentObject(libraryManager)
                }
        }
        .searchable(text: .constant(searchText), prompt: "Search videos")
    }
}
