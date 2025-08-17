//
//  MainView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var selectedPlaylist: Playlist?
    @State private var selectedVideo: Video?
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            SidebarView(selectedPlaylist: $selectedPlaylist)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } content: {
            // Content
            ContentListView(
                playlist: selectedPlaylist,
                selectedVideo: $selectedVideo,
                searchText: searchText
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
            .searchable(text: $searchText, prompt: "Search videos")
        } detail: {
            // Detail
            DetailView(video: selectedVideo)
                .navigationSplitViewColumnWidth(min: 500, ideal: 700)
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
    }
}
