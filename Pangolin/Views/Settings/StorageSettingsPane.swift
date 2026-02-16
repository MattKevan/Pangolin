//
//  StorageSettingsPane.swift
//  Pangolin
//

import SwiftUI

struct StorageSettingsPane: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var storagePolicyManager: StoragePolicyManager
    @EnvironmentObject private var videoFileManager: VideoFileManager

    @State private var selectedPreference: LibraryStoragePreference = .optimizeStorage
    @State private var cacheLimitGB: Int = 10
    @State private var localUsageBytes: Int64 = 0
    @State private var cloudOnlyCount: Int = 0
    @State private var transferIssueCounts = VideoTransferIssueCounts()
    @State private var policySummary: StoragePolicySummary?

    @State private var isHydratingForm = false
    @State private var isRefreshingStats = false
    @State private var isApplyingChanges = false
    @State private var isRetryingTransfers = false

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

                    HStack {
                        Text("Configured Cache Limit")
                        Spacer()
                        Text(library.formattedByteCount(library.resolvedMaxLocalVideoCacheBytes))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Transfer Issues") {
                    HStack {
                        Text("Upload Failures")
                        Spacer()
                        Text("\(transferIssueCounts.upload)")
                            .foregroundStyle(issueTextColor(transferIssueCounts.upload))
                    }

                    HStack {
                        Text("Download Failures")
                        Spacer()
                        Text("\(transferIssueCounts.download)")
                            .foregroundStyle(issueTextColor(transferIssueCounts.download))
                    }

                    HStack {
                        Text("Offload Failures")
                        Spacer()
                        Text("\(transferIssueCounts.offload)")
                            .foregroundStyle(issueTextColor(transferIssueCounts.offload))
                    }

                    if let policySummary {
                        HStack(alignment: .top) {
                            Text("Policy")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(policySummary.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)

                                if policySummary.remainingOverageBytes > 0 {
                                    Text("Over limit by \(library.formattedByteCount(policySummary.remainingOverageBytes))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Retry All Failed Transfers") {
                        Task {
                            await retryAllFailedTransfers()
                        }
                    }
                    .disabled(isRetryingTransfers || transferIssueCounts.total == 0)

                    Button("Apply Storage Policy Now") {
                        Task {
                            await applyPolicyNow()
                        }
                    }
                    .disabled(isApplyingChanges || storagePolicyManager.isApplyingPolicy)

                    Button("Apply Settings") {
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
        .onChange(of: storagePolicyManager.lastPolicySummary) { _, _ in
            Task {
                await refreshStats()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { _ in
            Task {
                await refreshStats()
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

    private func applyPolicyNow() async {
        guard let library = currentLibrary else { return }
        guard !isApplyingChanges else { return }

        isApplyingChanges = true
        defer { isApplyingChanges = false }

        await storagePolicyManager.applyPolicy(for: library)
        await refreshStats()
    }

    private func retryAllFailedTransfers() async {
        guard let library = currentLibrary else { return }
        guard !isRetryingTransfers else { return }

        isRetryingTransfers = true
        defer { isRetryingTransfers = false }

        await videoFileManager.retryAllFailedTransfers(in: library)
        await storagePolicyManager.applyPolicy(for: library)
        await refreshStats()
    }

    private func refreshStats() async {
        guard let library = currentLibrary else {
            localUsageBytes = 0
            cloudOnlyCount = 0
            transferIssueCounts = VideoTransferIssueCounts()
            policySummary = nil
            return
        }

        isRefreshingStats = true
        defer { isRefreshingStats = false }

        localUsageBytes = await storagePolicyManager.currentLocalVideoUsageBytes(for: library)
        cloudOnlyCount = await storagePolicyManager.currentCloudOnlyVideoCount(for: library)
        transferIssueCounts = await videoFileManager.failedTransferCounts(in: library)

        if let latestSummary = storagePolicyManager.lastPolicySummary,
           latestSummary.libraryID == library.id {
            policySummary = latestSummary
        } else {
            policySummary = nil
        }
    }

    private func issueTextColor(_ count: Int) -> Color {
        count > 0 ? .orange : .secondary
    }
}

#Preview {
    StorageSettingsPane()
        .environmentObject(LibraryManager.shared)
        .environmentObject(StoragePolicyManager.shared)
        .environmentObject(VideoFileManager.shared)
}
