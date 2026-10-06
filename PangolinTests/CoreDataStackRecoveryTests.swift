import CoreData
import Foundation
import Testing
@testable import Pangolin

@Suite(.serialized)
struct CoreDataStackRecoveryTests {
    private func makeLibraryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinStackRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A corrupt database is reported, not silently replaced")
    @MainActor
    func corruptDatabaseIsReportedAndLeftInPlace() async throws {
        let directory = try makeLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = CoreDataStack.storeURL(forLibraryAt: directory)
        let garbage = Data(repeating: 0x42, count: 4_096)
        try garbage.write(to: storeURL)

        var reportedCorruption = false
        do {
            _ = try await CoreDataStack.getInstance(for: directory)
        } catch CoreDataStackError.storeCorrupted {
            reportedCorruption = true
        }

        #expect(reportedCorruption)
        #expect(try Data(contentsOf: storeURL) == garbage)
    }

    @Test("Quarantining moves the database and its sidecars aside together")
    func quarantineMovesDatabaseAndSidecars() throws {
        let directory = try makeLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = CoreDataStack.storeURL(forLibraryAt: directory)
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: storeURL.path + suffix))
        }

        try CoreDataStack.quarantineStore(at: storeURL)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!remaining.contains("Library.sqlite"))
        #expect(!remaining.contains("Library.sqlite-wal"))
        #expect(!remaining.contains("Library.sqlite-shm"))
        #expect(remaining.filter { $0.contains(".corrupted-") }.count == 3)
    }

    @Test("Only SQLite corruption codes count as corruption, including wrapped ones")
    func corruptionDetection() {
        let corrupt = NSError(domain: NSSQLiteErrorDomain, code: 11)
        let notADatabase = NSError(domain: NSSQLiteErrorDomain, code: 26)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_030, userInfo: [NSUnderlyingErrorKey: corrupt])
        let otherSQLite = NSError(domain: NSSQLiteErrorDomain, code: 13)
        let sameCodeElsewhere = NSError(domain: NSCocoaErrorDomain, code: 11)

        let unreadable = NSError(domain: NSCocoaErrorDomain, code: 259, userInfo: [NSSQLiteErrorDomain: 26])
        let codeInUserInfo = NSError(domain: NSCocoaErrorDomain, code: 134_030, userInfo: [NSSQLiteErrorDomain: 11])
        let permissionDenied = NSError(domain: NSCocoaErrorDomain, code: 513)

        #expect(CoreDataStack.isStoreCorruption(unreadable))
        #expect(CoreDataStack.isStoreCorruption(codeInUserInfo))
        #expect(!CoreDataStack.isStoreCorruption(permissionDenied))
        #expect(CoreDataStack.isStoreCorruption(corrupt))
        #expect(CoreDataStack.isStoreCorruption(notADatabase))
        #expect(CoreDataStack.isStoreCorruption(wrapped))
        #expect(!CoreDataStack.isStoreCorruption(otherSQLite))
        #expect(!CoreDataStack.isStoreCorruption(sameCodeElsewhere))
    }
}
