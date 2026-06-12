import Foundation
import Testing
@testable import Pangolin

struct FileSystemManagerTests {
    @Test("Media relative path strips local library videos root")
    func mediaRelativePathStripsLocalLibraryRoot() {
        let libraryURL = URL(fileURLWithPath: "/tmp/Pangolin/Library")
        let videoURL = libraryURL
            .appendingPathComponent("Videos", isDirectory: true)
            .appendingPathComponent("2026-06-11", isDirectory: true)
            .appendingPathComponent("clip.mp4")

        let relativePath = FileSystemManager.mediaRelativePath(
            for: videoURL,
            libraryURL: libraryURL,
            cloudRootURL: nil
        )

        #expect(relativePath == "2026-06-11/clip.mp4")
    }

    @Test("Media relative path strips cloud videos root")
    func mediaRelativePathStripsCloudVideosRoot() {
        let libraryURL = URL(fileURLWithPath: "/tmp/Pangolin/Library")
        let cloudRootURL = URL(fileURLWithPath: "/tmp/Mobile Documents/iCloud.com.newindustries.pangolin")
        let videoURL = cloudRootURL
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent("Videos", isDirectory: true)
            .appendingPathComponent("1234.mp4")

        let relativePath = FileSystemManager.mediaRelativePath(
            for: videoURL,
            libraryURL: libraryURL,
            cloudRootURL: cloudRootURL
        )

        #expect(relativePath == "1234.mp4")
    }
}
