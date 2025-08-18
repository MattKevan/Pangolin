//
//  MainView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var folderStore: FolderNavigationStore
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    init() {
        // Initialize the store with a placeholder, will be updated in onAppear
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: LibraryManager.shared))
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .environmentObject(folderStore)
        } content: {
            // Simple content view that reacts to folder selection
            ContentListView(searchText: searchText)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
                .searchable(text: $searchText, prompt: "Search videos")
                .environmentObject(folderStore)
        } detail: {
            // Detail
            let _ = print("🏠 MainView: Passing video to DetailView: \(folderStore.selectedVideo?.title ?? "nil")")
            DetailView(video: folderStore.selectedVideo)
                .navigationSplitViewColumnWidth(min: 500, ideal: 700)
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
    }
}
