//
//  StorageSettingsPane.swift
//  Pangolin
//

import SwiftUI

struct StorageSettingsPane: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var storagePolicyManager: StoragePolicyManager

    @State private var selectedPreference: LibraryStoragePreference = .optimizeStorage
    @State private var cacheLimitGB: Int = 10
    @State private var localUsageBytes: Int64 = 0
    @State private var cloudOnlyCount: Int = 0
    @State private var isHydratingForm = false
    @State private var isRefreshingStats = false
    @State private var isApplyingChanges = false

    private var currentLibrary: Library? {
        libraryManager.currentLibrary
    }

    var body: some View {
        Form {
            if let library = currentLibrary {
                Section("Video Storage") {
                    Picker("Storage Mode", selection: $selectedPreference) {
                        ForEach(LibraryStoragePreference.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(selectedPreference.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if selectedPreference == .optimizeStorage {
                        Stepper(value: $cacheLimitGB, in: 1...500, step: 1) {
                            Text("Max Local Video Cache: \(cacheLimitGB) GB")
                        }
                    }
                }

                Section("Status") {
                    HStack {
                        Text("Local Cache In Use")
                        Spacer()
                        if isRefreshingStats {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(library.formattedByteCount(localUsageBytes))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Cloud-Only Videos")
                        Spacer()
                        Text("\(cloudOnlyCount)")
                            .foregroundStyle(.secondary)
                    }

                    if selectedPreference == .optimizeStorage {
                        HStack {
                            Text("Configured Cache Limit")
                            Spacer()
                            Text(library.formattedByteCount(library.resolvedMaxLocalVideoCacheBytes))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Apply Now") {
                        Task {
                            await persistAndApply()
                        }
                    }
                    .disabled(isApplyingChanges || storagePolicyManager.isApplyingPolicy)
                }
            } else {
                ContentUnavailableView(
                    "No Library Open",
                    systemImage: "externaldrive",
                    description: Text("Open a library to configure storage settings.")
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncFormFromCurrentLibrary()
            Task {
                await refreshStats()
            }
        }
        .onChange(of: libraryManager.currentLibrary?.id) { _, _ in
            syncFormFromCurrentLibrary()
            Task {
                await refreshStats()
            }
        }
        .onChange(of: selectedPreference) { _, _ in
            guard !isHydratingForm else { return }
            Task {
                await persistAndApply()
            }
        }
        .onChange(of: cacheLimitGB) { _, _ in
            guard !isHydratingForm, selectedPreference == .optimizeStorage else { return }
            Task {
                await persistAndApply()
            }
        }
    }

    private func syncFormFromCurrentLibrary() {
        guard let library = currentLibrary else { return }
        isHydratingForm = true
        selectedPreference = library.storagePreference
        cacheLimitGB = library.maxLocalCacheGB
        isHydratingForm = false
    }

    private func persistAndApply() async {
        guard let library = currentLibrary else { return }
        guard !isApplyingChanges else { return }

        isApplyingChanges = true
        defer { isApplyingChanges = false }

        library.storagePreference = selectedPreference
        library.maxLocalCacheGB = cacheLimitGB

        await libraryManager.save()
        await storagePolicyManager.applyPolicy(for: library)
        await refreshStats()
    }

    private func refreshStats() async {
        guard let library = currentLibrary else {
            localUsageBytes = 0
            cloudOnlyCount = 0
            return
        }

        isRefreshingStats = true
        defer { isRefreshingStats = false }

        localUsageBytes = await storagePolicyManager.currentLocalVideoUsageBytes(for: library)
        cloudOnlyCount = await storagePolicyManager.currentCloudOnlyVideoCount(for: library)
    }
}

#Preview {
    StorageSettingsPane()
        .environmentObject(LibraryManager.shared)
        .environmentObject(StoragePolicyManager.shared)
}
