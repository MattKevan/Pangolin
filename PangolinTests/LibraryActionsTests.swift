import Foundation
import Testing
@testable import Pangolin

// Drives LibraryManager.shared; serialized so it cannot race other tests' library lifecycle.
@Suite(.serialized)
struct LibraryActionsTests {
    @MainActor
    private func withOpenLibrary(
        _ body: (LibraryActions, Library) async throws -> Void
    ) async throws {
        let manager = LibraryManager.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinLibraryActions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try await manager.loadLibrary(at: directory)
        do {
            try await body(LibraryActions(), library)
        } catch {
            await manager.closeCurrentLibrary()
            throw error
        }
        library.uploadOptimizationPreset = .original
        await manager.closeCurrentLibrary()
    }

    @Test("With no library open neither action is available")
    @MainActor
    func nothingAvailableWithoutALibrary() async {
        await LibraryManager.shared.closeCurrentLibrary()
        let actions = LibraryActions()

        #expect(!actions.canOptimizeAll)
        #expect(!actions.canApplyStoragePolicy)

        actions.requestOptimizeAll()
        #expect(!actions.isConfirmingOptimizeAll)
    }

    @Test("Optimising needs an upload preset other than Keep Originals")
    @MainActor
    func optimiseNeedsAPreset() async throws {
        try await withOpenLibrary { actions, library in
            library.uploadOptimizationPreset = .original
            #expect(!actions.canOptimizeAll)
            #expect(actions.canApplyStoragePolicy)

            actions.requestOptimizeAll()
            #expect(!actions.isConfirmingOptimizeAll)

            library.uploadOptimizationPreset = .balanced
            #expect(actions.canOptimizeAll)
        }
    }

    @Test("Requesting an optimise asks for confirmation instead of starting")
    @MainActor
    func optimiseAsksFirst() async throws {
        try await withOpenLibrary { actions, library in
            library.uploadOptimizationPreset = .balanced
            #expect(!actions.isConfirmingOptimizeAll)

            actions.requestOptimizeAll()

            #expect(actions.isConfirmingOptimizeAll)
        }
    }
}
