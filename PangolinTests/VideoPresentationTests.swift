import CoreData
import Foundation
import SwiftUI
import Testing
@testable import Pangolin

@MainActor
struct VideoPresentationTests {
    /// Owns the in-memory store so the video stays valid for the length of a test.
    private struct Fixture {
        let container: NSPersistentContainer
        let video: Video
    }

    private func makeFixture() throws -> Fixture {
        let bundle = Bundle(for: CoreDataStack.self)
        let modelDirectory = try #require(bundle.url(forResource: "Pangolin", withExtension: "momd"))
        let model = try #require(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("Pangolin 2.mom")))
        let container = NSPersistentContainer(name: "Pangolin", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { Issue.record("In-memory store failed: \(error)") }
        }
        let entity = try #require(NSEntityDescription.entity(forEntityName: "Video", in: container.viewContext))
        return Fixture(container: container, video: Video(entity: entity, insertInto: container.viewContext))
    }

    @Test("A video is listed by its trimmed title, then its file name, then a placeholder")
    func listTitleFallsBack() throws {
        let fixture = try makeFixture()
        let video = fixture.video
        video.title = "  Introduction  "
        video.fileName = "intro.mp4"
        #expect(video.listTitle == "Introduction")

        video.title = "   "
        #expect(video.listTitle == "intro.mp4")

        video.fileName = nil
        #expect(video.listTitle == "Untitled Video")
    }

    @Test("Watch status maps to a hollow, half filled or filled dot")
    func watchStatusSymbols() throws {
        let fixture = try makeFixture()
        let video = fixture.video
        video.duration = 100

        video.playbackPosition = 0
        #expect(video.watchStatusSymbol == "circle")

        video.playbackPosition = 40
        #expect(video.watchStatusSymbol == "circle.lefthalf.filled")

        video.playbackPosition = 95
        #expect(video.watchStatusSymbol == "circle.fill")
    }

    @Test("Only files that are not on this device get a badge")
    func cloudBadgeOnlyWhenNotLocal() throws {
        let fixture = try makeFixture()
        let video = fixture.video

        video.fileAvailabilityState = VideoFileStatus.local.rawValue
        #expect(video.cloudBadge == nil)
        #expect(video.availabilityLabel == "On device")

        video.fileAvailabilityState = VideoFileStatus.cloudOnly.rawValue
        #expect(video.cloudBadge?.label == "Available in iCloud")

        video.fileAvailabilityState = VideoFileStatus.missing.rawValue
        #expect(video.cloudBadge?.label == "File not found")
    }

    @Test("A video with a cloud path and no recorded state counts as cloud only")
    func cloudPathImpliesCloudOnly() throws {
        let fixture = try makeFixture()
        let video = fixture.video
        video.fileAvailabilityState = nil
        video.cloudRelativePath = "Media/Videos/example.mp4"

        #expect(video.availability == .cloudOnly)
    }
}
