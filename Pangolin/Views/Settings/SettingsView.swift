//
//  SettingsView.swift
//  Pangolin
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            StorageSettingsPane()
                .tabItem {
                    Label("Storage", systemImage: "externaldrive.badge.icloud")
                }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

#Preview {
    SettingsView()
        .environmentObject(LibraryManager.shared)
        .environmentObject(StoragePolicyManager.shared)
        .environmentObject(VideoFileManager.shared)
}
