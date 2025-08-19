// Views/MainView.swift

import SwiftUI

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var folderStore: FolderNavigationStore
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    // REFACTORED: The initializer now requires the active LibraryManager.
    // This is the standard SwiftUI pattern for initializing a @StateObject
    // that has dependencies, ensuring it's created only once with the correct state.
    init(libraryManager: LibraryManager) {
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .environmentObject(folderStore)
        } content: {
            // Hierarchical Content View - shows content of selected top-level sidebar item
            HierarchicalContentView(searchText: searchText)
                .navigationTitle(folderStore.folderName(for: folderStore.currentFolderID))
                .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
                .searchable(text: $searchText, prompt: "Search videos")
                .environmentObject(folderStore)
        } detail: {
            // Detail View
            DetailView(video: folderStore.selectedVideo)
                .navigationSplitViewColumnWidth(min: 500, ideal: 700)
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
    }
}
