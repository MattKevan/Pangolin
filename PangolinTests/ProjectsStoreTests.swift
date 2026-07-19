import Foundation
import CoreData
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pangolin

struct ProjectsStoreTests {
    @Test("Project selection drops IDs hidden by filtering")
    func projectSelectionReconcilesVisibleIDs() {
        let visible = UUID()
        let hidden = UUID()

        #expect(ProjectVideoSelectionPolicy.reconciledSelection(
            [visible, hidden],
            visibleIDs: [visible]
        ) == [visible])
    }

    @Test("Project Return activation requires exactly one selected visible video")
    func projectReturnActivationRequiresSingleVisibleSelection() {
        let first = UUID()
        let second = UUID()

        #expect(ProjectVideoSelectionPolicy.activationID(
            selection: [first],
            visibleIDs: [first, second]
        ) == first)
        #expect(ProjectVideoSelectionPolicy.activationID(
            selection: [first, second],
            visibleIDs: [first, second]
        ) == nil)
        #expect(ProjectVideoSelectionPolicy.activationID(
            selection: [first],
            visibleIDs: [second]
        ) == nil)
    }

    @Test("Project list primary action activates exactly one selected visible video")
    func projectListPrimaryActionRequiresSingleVisibleSelection() {
        let first = UUID()
        let second = UUID()

        #expect(ProjectVideoSelectionPolicy.primaryActionID(
            selection: [first],
            visibleIDs: [first, second]
        ) == first)
        #expect(ProjectVideoSelectionPolicy.primaryActionID(
            selection: [first, second],
            visibleIDs: [first, second]
        ) == nil)
    }

    @Test("Projects becomes the default destination on startup")
    @MainActor
    func projectsIsDefaultStartupDestination() async throws {
        let (manager, _, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = FolderNavigationStore(libraryManager: manager)

        #expect(store.selectedSidebarItem == .projects)
        #expect(store.currentDetailSurface == .projectsGrid)

        await manager.closeCurrentLibrary()
    }

    @Test("Projects query only returns top-level non-smart folders")
    @MainActor
    func projectsQueryFiltersToTopLevelFolders() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let project = try makeFolder(named: "Project One", in: context, parent: nil, library: try requireLibrary(from: manager))
        _ = try makeFolder(named: "Section One", in: context, parent: project, library: try requireLibrary(from: manager))
        let smartFolder = try makeFolder(named: "Recent", in: context, parent: nil, library: try requireLibrary(from: manager))
        smartFolder.isSmartFolder = true
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let projects = store.projects()

        #expect(projects.count == 1)
        #expect(projects.first?.name == "Project One")

        await manager.closeCurrentLibrary()
    }

    @Test("Only complete current-version JPEG data is a current thumbnail")
    @MainActor
    func currentThumbnailRequiresValidJPEGData() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Thumbnails", in: context, parent: nil, library: library)
        let invalidVideo = try makeVideo(
            title: "Invalid",
            thumbnailData: Data("not a jpeg".utf8),
            in: context,
            folder: project,
            library: library
        )
        let validVideo = try makeVideo(
            title: "Valid",
            thumbnailData: try makeValidJPEG(),
            in: context,
            folder: project,
            library: library
        )

        ThumbnailValidityCache.shared.removeAllObjects()
        #expect(!invalidVideo.hasCurrentThumbnail)
        #expect(!invalidVideo.hasCurrentThumbnail)
        #expect(validVideo.hasCurrentThumbnail)
        #expect(validVideo.hasCurrentThumbnail)
        #expect(ThumbnailValidityCache.shared.validationCount == 2)

        invalidVideo.thumbnailData = Data("different invalid bytes".utf8)
        #expect(!invalidVideo.hasCurrentThumbnail)
        #expect(ThumbnailValidityCache.shared.validationCount == 3)

        await manager.closeCurrentLibrary()
    }

    @Test("Project metadata replaces invalid stored artwork with valid descendant data")
    @MainActor
    func projectMetadataFallsBackToExistingData() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Watercolour", in: context, parent: nil, library: library)
        let section = try makeFolder(named: "Basics", in: context, parent: project, library: library)
        let invalidVideo = try makeVideo(
            title: "Invalid Root Artwork",
            thumbnailData: Data("not a jpeg".utf8),
            in: context,
            folder: project,
            library: library
        )
        let validVideo = try makeVideo(
            title: "Valid Descendant Artwork",
            thumbnailData: try makeValidJPEG(),
            in: context,
            folder: section,
            library: library
        )
        project.projectThumbnailVideoID = invalidVideo.id
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let fetchedProject = try #require(store.projects().first)

        #expect(fetchedProject.resolvedProjectTitle == "Watercolour")
        #expect(fetchedProject.resolvedProjectProvider.isEmpty)
        #expect(fetchedProject.resolvedProjectThumbnailVideo?.id == validVideo.id)
        #expect(fetchedProject.projectThumbnailVideoID == validVideo.id)

        await manager.closeCurrentLibrary()
    }

    @Test("Project refresh replaces artwork moved out of the project")
    @MainActor
    func projectRefreshReplacesMovedArtwork() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Editing", in: context, parent: nil, library: library)
        let otherProject = try makeFolder(named: "Archive", in: context, parent: nil, library: library)
        let selectedVideo = try makeVideo(
            title: "Selected Artwork",
            thumbnailData: try makeValidJPEG(),
            in: context,
            folder: project,
            library: library
        )
        let replacementData = try makeValidJPEG()
        let replacementVideo = try makeVideo(
            title: "Replacement Artwork",
            thumbnailData: replacementData,
            in: context,
            folder: project,
            library: library
        )
        project.projectThumbnailVideoID = selectedVideo.id
        try context.save()

        selectedVideo.folder = otherProject
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let refreshedProject = try #require(
            store.projects().first(where: { $0.objectID == project.objectID })
        )

        #expect(refreshedProject.projectThumbnailVideoID == replacementVideo.id)
        #expect(refreshedProject.resolvedProjectThumbnailVideo?.id == replacementVideo.id)
        #expect(refreshedProject.resolvedProjectThumbnailVideo?.thumbnailData == replacementData)

        await manager.closeCurrentLibrary()
    }

    @Test("Duplicate descendant names resolve artwork in stable UUID order")
    @MainActor
    func duplicateDescendantNamesResolveInStableUUIDOrder() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Duplicates", in: context, parent: nil, library: library)
        let higherFolder = try makeFolder(named: "Section", in: context, parent: project, library: library)
        higherFolder.id = try makeUUID("00000000-0000-0000-0000-000000000020")
        let lowerFolder = try makeFolder(named: "Section", in: context, parent: project, library: library)
        lowerFolder.id = try makeUUID("00000000-0000-0000-0000-000000000010")

        let jpeg = try makeValidJPEG()
        let higherVideoInLowerFolder = try makeVideo(
            title: "Lesson",
            thumbnailData: jpeg,
            in: context,
            folder: lowerFolder,
            library: library
        )
        higherVideoInLowerFolder.id = try makeUUID("00000000-0000-0000-0000-000000000012")
        let lowerVideoInLowerFolder = try makeVideo(
            title: "Lesson",
            thumbnailData: jpeg,
            in: context,
            folder: lowerFolder,
            library: library
        )
        lowerVideoInLowerFolder.id = try makeUUID("00000000-0000-0000-0000-000000000011")
        let higherVideoInHigherFolder = try makeVideo(
            title: "Lesson",
            thumbnailData: jpeg,
            in: context,
            folder: higherFolder,
            library: library
        )
        higherVideoInHigherFolder.id = try makeUUID("00000000-0000-0000-0000-000000000022")
        let lowerVideoInHigherFolder = try makeVideo(
            title: "Lesson",
            thumbnailData: jpeg,
            in: context,
            folder: higherFolder,
            library: library
        )
        lowerVideoInHigherFolder.id = try makeUUID("00000000-0000-0000-0000-000000000021")
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let fetchedProject = try #require(store.projects().first)

        #expect(fetchedProject.childFoldersArray.map(\.id) == [lowerFolder.id, higherFolder.id])
        #expect(fetchedProject.descendantVideos.map(\.id) == [
            lowerVideoInLowerFolder.id,
            higherVideoInLowerFolder.id,
            lowerVideoInHigherFolder.id,
            higherVideoInHigherFolder.id,
        ])
        #expect(fetchedProject.resolvedProjectThumbnailVideo?.id == lowerVideoInLowerFolder.id)
        #expect(fetchedProject.projectThumbnailVideoID == lowerVideoInLowerFolder.id)

        await manager.closeCurrentLibrary()
    }

    @Test("Project metadata backfill defers while unrelated edits are pending")
    @MainActor
    func projectMetadataBackfillDefersForPendingEdits() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Deferred", in: context, parent: nil, library: library)
        project.projectTitle = nil
        let video = try makeVideo(
            title: "Artwork",
            thumbnailData: try makeValidJPEG(),
            in: context,
            folder: project,
            library: library
        )
        try context.save()

        library.name = "Pending Unsaved Name"
        let store = FolderNavigationStore(libraryManager: manager)
        _ = store.projects()

        #expect(context.hasChanges)
        #expect(library.name == "Pending Unsaved Name")
        #expect(project.projectTitle == nil)
        #expect(project.projectThumbnailVideoID == nil)
        #expect(project.resolvedProjectThumbnailVideo?.id == video.id)

        context.rollback()
        await manager.closeCurrentLibrary()
    }

    @Test("Legacy project thumbnail path still backfills temporarily")
    @MainActor
    func legacyProjectThumbnailPathStillBackfills() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Legacy", in: context, parent: nil, library: library)
        let video = try makeVideo(
            title: "Legacy Artwork",
            thumbnailData: nil,
            in: context,
            folder: project,
            library: library
        )
        video.thumbnailPath = "legacy-thumbnail.jpg"
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let fetchedProject = try #require(store.projects().first)

        #expect(fetchedProject.resolvedProjectThumbnailPath == "legacy-thumbnail.jpg")
        #expect(fetchedProject.projectThumbnailPath == "legacy-thumbnail.jpg")

        await manager.closeCurrentLibrary()
    }

    @Test("Project selection routes between grid and placeholder detail")
    @MainActor
    func projectSelectionRoutesToPlaceholderDetail() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let project = try makeFolder(named: "Typography", in: context, parent: nil, library: try requireLibrary(from: manager))
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)

        store.selectProjects()
        #expect(store.currentDetailSurface == .projectsGrid)

        store.openProject(project)
        #expect(store.selectedSidebarItem == .projects)
        #expect(store.selectedProject?.objectID == project.objectID)
        #expect(store.currentDetailSurface == .projectDetail)

        await manager.closeCurrentLibrary()
    }

    @Test("Project detail aggregates and continue watching resolve from project content")
    @MainActor
    func projectDetailAggregatesAndContinueWatching() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Commerce", in: context, parent: nil, library: library)
        let section = try makeFolder(named: "Module 1", in: context, parent: project, library: library)
        _ = try makeVideo(
            title: "Intro",
            thumbnailData: nil,
            in: context,
            folder: section,
            library: library,
            duration: 300,
            playbackPosition: 120,
            lastPlayed: Date()
        )
        _ = try makeVideo(
            title: "Setup",
            thumbnailData: nil,
            in: context,
            folder: section,
            library: library,
            duration: 600,
            playbackPosition: 0,
            lastPlayed: nil
        )
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)

        #expect(store.projectVideos(in: project).count == 2)
        #expect(store.totalDuration(for: project) == 900)
        #expect(store.continueWatchingVideo(in: project)?.title == "Intro")

        await manager.closeCurrentLibrary()
    }

    @Test("Project sections flatten nested folders and expose root videos as fallback section")
    @MainActor
    func projectSectionsFlattenNestedFoldersAndRootVideos() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let module = try makeFolder(named: "Module 1", in: context, parent: project, library: library)
        let nested = try makeFolder(named: "Deep Folder", in: context, parent: module, library: library)
        _ = try makeVideo(title: "Nested Lesson", thumbnailData: nil, in: context, folder: nested, library: library)
        _ = try makeVideo(title: "Loose Video", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let sections = store.projectSections(for: project)

        #expect(sections.count == 2)
        #expect(sections.first?.title == "Module 1")
        #expect(sections.first?.videos.first?.title == "Nested Lesson")
        #expect(sections.last?.title == "Videos")
        #expect(sections.last?.videos.first?.title == "Loose Video")

        await manager.closeCurrentLibrary()
    }

    @Test("Project search filters only inside the active project")
    @MainActor
    func projectSearchFiltersOnlyActiveProject() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let activeProject = try makeFolder(named: "Active", in: context, parent: nil, library: library)
        let activeSection = try makeFolder(named: "Section", in: context, parent: activeProject, library: library)
        _ = try makeVideo(title: "Alpha Lesson", thumbnailData: nil, in: context, folder: activeSection, library: library)

        let otherProject = try makeFolder(named: "Other", in: context, parent: nil, library: library)
        let otherSection = try makeFolder(named: "Section", in: context, parent: otherProject, library: library)
        _ = try makeVideo(title: "Alpha Elsewhere", thumbnailData: nil, in: context, folder: otherSection, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let results = store.projectSections(for: activeProject, matching: "alpha")

        #expect(results.count == 1)
        #expect(results.first?.videos.count == 1)
        #expect(results.first?.videos.first?.folder?.parentFolder?.objectID == activeProject.objectID)

        await manager.closeCurrentLibrary()
    }

    @Test("Project videos sort by filename using natural numeric order")
    @MainActor
    func projectVideosSortByFilenameUsingNaturalNumericOrder() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Numbered", in: context, parent: nil, library: library)
        let section = try makeFolder(named: "Module", in: context, parent: project, library: library)
        _ = try makeVideo(title: "Ten", thumbnailData: nil, in: context, folder: section, library: library, fileName: "10 - Lesson.mp4")
        _ = try makeVideo(title: "Two", thumbnailData: nil, in: context, folder: section, library: library, fileName: "2 - Lesson.mp4")
        _ = try makeVideo(title: "Nine", thumbnailData: nil, in: context, folder: section, library: library, fileName: "9 - Lesson.mp4")
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let videos = try #require(store.projectSections(for: project).first?.videos)

        #expect(videos.map(\.fileName) == ["2 - Lesson.mp4", "9 - Lesson.mp4", "10 - Lesson.mp4"])

        await manager.closeCurrentLibrary()
    }

    @MainActor
    private func makeLibraryContext() async throws -> (LibraryManager, NSManagedObjectContext, URL) {
        let manager = LibraryManager.shared
        await manager.closeCurrentLibrary()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinProjects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let libraryURL = tempRoot.appendingPathComponent("Library", isDirectory: true)
        _ = try await manager.createLibrary(at: libraryURL, name: "Projects Test Library")

        guard let context = manager.viewContext else {
            throw TestFailure("Expected view context")
        }

        return (manager, context, tempRoot)
    }

    @MainActor
    private func requireLibrary(from manager: LibraryManager) throws -> Library {
        guard let library = manager.currentLibrary else {
            throw TestFailure("Expected current library")
        }
        return library
    }

    @MainActor
    private func makeFolder(
        named name: String,
        in context: NSManagedObjectContext,
        parent: Folder?,
        library: Library
    ) throws -> Folder {
        guard let folderEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            throw TestFailure("Missing Folder entity")
        }

        let folder = Folder(entity: folderEntity, insertInto: context)
        folder.id = UUID()
        folder.name = name
        folder.projectTitle = parent == nil ? name : nil
        folder.projectProvider = nil
        folder.projectThumbnailPath = nil
        folder.isTopLevel = (parent == nil)
        folder.isSmartFolder = false
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.parentFolder = parent
        folder.library = library
        return folder
    }

    @MainActor
    private func makeVideo(
        title: String,
        thumbnailData: Data?,
        in context: NSManagedObjectContext,
        folder: Folder,
        library: Library,
        duration: TimeInterval = 120,
        playbackPosition: Double = 0,
        lastPlayed: Date? = nil,
        fileName: String? = nil
    ) throws -> Video {
        guard let videoEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            throw TestFailure("Missing Video entity")
        }

        let video = Video(entity: videoEntity, insertInto: context)
        video.id = UUID()
        video.title = title
        video.fileName = fileName ?? "\(title).mp4"
        if let thumbnailData {
            video.thumbnailData = thumbnailData
            video.thumbnailGenerationVersion = ThumbnailGenerator.currentVersion
            video.thumbnailGeneratedAt = Date()
        }
        video.dateAdded = Date()
        video.duration = duration
        video.playbackPosition = playbackPosition
        video.lastPlayed = lastPlayed
        video.fileSize = 1_024
        video.folder = folder
        video.library = library
        return video
    }
}

private func makeValidJPEG() throws -> Data {
    let pixelData = Data([0x33, 0x66, 0x99, 0xFF])
    guard let provider = CGDataProvider(data: pixelData as CFData),
          let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw TestFailure("Could not create test image")
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw TestFailure("Could not create JPEG destination")
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TestFailure("Could not encode test JPEG")
    }
    return data as Data
}

private func makeUUID(_ string: String) throws -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        throw TestFailure("Invalid test UUID: \(string)")
    }
    return uuid
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
