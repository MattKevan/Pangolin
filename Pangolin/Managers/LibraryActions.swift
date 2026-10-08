//
//  LibraryActions.swift
//  Pangolin
//

import Foundation
import Observation

/// Library-wide maintenance actions, shared by the macOS Library menu and the menus on iPad and iPhone.
///
/// Optimising re-encodes videos and replaces their iCloud copies, so it asks first: the surface
/// that shows the menu calls `requestOptimizeAll()` and the root view presents the confirmation.
@MainActor
@Observable
final class LibraryActions {
    static let shared = LibraryActions()

    var isConfirmingOptimizeAll = false

    @ObservationIgnored private let libraryManager: LibraryManager
    @ObservationIgnored private let storagePolicyManager: StoragePolicyManager
    @ObservationIgnored private let optimizer: VideoLibraryOptimizationManager

    init(
        libraryManager: LibraryManager = .shared,
        storagePolicyManager: StoragePolicyManager = .shared,
        optimizer: VideoLibraryOptimizationManager = .shared
    ) {
        self.libraryManager = libraryManager
        self.storagePolicyManager = storagePolicyManager
        self.optimizer = optimizer
    }

    /// Needs a library, an upload preset other than "Keep Originals", and no run already under way.
    var canOptimizeAll: Bool {
        guard let library = libraryManager.currentLibrary else { return false }
        return library.uploadOptimizationPreset.isEnabled && !optimizer.isOptimizing
    }

    var canApplyStoragePolicy: Bool {
        libraryManager.currentLibrary != nil && !storagePolicyManager.isApplyingPolicy
    }

    func requestOptimizeAll() {
        guard canOptimizeAll else { return }
        isConfirmingOptimizeAll = true
    }

    func optimizeAll() async {
        guard let library = libraryManager.currentLibrary else { return }
        await optimizer.optimizeAllVideos(in: library, preset: library.uploadOptimizationPreset)
    }

    func applyStoragePolicy() async {
        guard let library = libraryManager.currentLibrary else { return }
        await storagePolicyManager.applyPolicy(for: library)
    }
}
