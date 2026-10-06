//
//  LibraryActionsMenu.swift
//  Pangolin
//

import SwiftUI

/// The Library actions as menu items. Used by the macOS Library menu and by title and context
/// menus elsewhere, so the wording and enabled state stay the same everywhere.
struct LibraryActionsMenuContent: View {
    let actions: LibraryActions

    var body: some View {
        Button("Optimise All Videos…", systemImage: "arrow.down.right.and.arrow.up.left") {
            actions.requestOptimizeAll()
        }
        .disabled(!actions.canOptimizeAll)

        Button("Apply Storage Policy Now", systemImage: "externaldrive") {
            Task { await actions.applyStoragePolicy() }
        }
        .disabled(!actions.canApplyStoragePolicy)
    }
}

extension View {
    /// Presents the confirmation for "Optimise All Videos…" wherever the action was requested from.
    func confirmsOptimizeAll(_ actions: LibraryActions) -> some View {
        @Bindable var actions = actions
        return confirmationDialog(
            "Optimise All Videos?",
            isPresented: $actions.isConfirmingOptimizeAll,
            titleVisibility: .visible
        ) {
            Button("Optimise All Videos") {
                Task { await actions.optimizeAll() }
            }
        } message: {
            Text("Videos larger than the selected target will download, be re-encoded, and replace their iCloud copies. This cannot restore the original quality.")
        }
    }
}
