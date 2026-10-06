import Foundation
import Testing
@testable import Pangolin

struct VideoImporterRollbackTests {
    @MainActor
    private func makeFixture() throws -> (root: URL, source: URL, staging: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinImportRollback-\(UUID().uuidString)", isDirectory: true)
        let stagingDirectory = root.appendingPathComponent("Library/Videos", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let staging = stagingDirectory.appendingPathComponent("clip.mp4")
        try Data("video".utf8).write(to: staging)
        return (root, sourceDirectory.appendingPathComponent("clip.mp4"), staging)
    }

    @Test("A failed import of a copied file removes the staging copy")
    @MainActor
    func copiedFileStagingIsRemoved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        VideoImporter().restoreSource(fromStaging: fixture.staging, to: fixture.source, wasCopied: true)

        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    @Test("A failed import of a moved file puts the user's file back")
    @MainActor
    func movedFileIsRestoredToItsSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        VideoImporter().restoreSource(fromStaging: fixture.staging, to: fixture.source, wasCopied: false)

        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        #expect(try Data(contentsOf: fixture.source) == Data("video".utf8))
    }

    @Test("A moved file that cannot be restored is kept, never deleted")
    @MainActor
    func unrestorableMovedFileIsKept() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unreachableSource = fixture.root
            .appendingPathComponent("Missing/Folder", isDirectory: true)
            .appendingPathComponent("clip.mp4")

        VideoImporter().restoreSource(fromStaging: fixture.staging, to: unreachableSource, wasCopied: false)

        #expect(FileManager.default.fileExists(atPath: fixture.staging.path))
    }
}
