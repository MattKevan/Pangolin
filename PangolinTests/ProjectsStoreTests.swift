import Foundation
import CoreData
import Testing
@testable import Pangolin

struct ProjectsStoreTests {
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

    @Test("Project metadata falls back to folder name and descendant thumbnail")
    @MainActor
    func projectMetadataFallsBackToExistingData() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Watercolour", in: context, parent: nil, library: library)
        let section = try makeFolder(named: "Basics", in: context, parent: project, library: library)
        _ = try makeVideo(
            title: "Lesson 1",
            thumbnailPath: "watercolour-thumb.jpg",
            in: context,
            folder: section,
            library: library
        )
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let fetchedProject = try #require(store.projects().first)

        #expect(fetchedProject.resolvedProjectTitle == "Watercolour")
        #expect(fetchedProject.resolvedProjectProvider.isEmpty)
        #expect(fetchedProject.resolvedProjectThumbnailPath == "watercolour-thumb.jpg")
        #expect(fetchedProject.projectThumbnailPath == "watercolour-thumb.jpg")

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
            thumbnailPath: nil,
            in: context,
            folder: section,
            library: library,
            duration: 300,
            playbackPosition: 120,
            lastPlayed: Date()
        )
        _ = try makeVideo(
            title: "Setup",
            thumbnailPath: nil,
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
        _ = try makeVideo(title: "Nested Lesson", thumbnailPath: nil, in: context, folder: nested, library: library)
        _ = try makeVideo(title: "Loose Video", thumbnailPath: nil, in: context, folder: project, library: library)
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
        _ = try makeVideo(title: "Alpha Lesson", thumbnailPath: nil, in: context, folder: activeSection, library: library)

        let otherProject = try makeFolder(named: "Other", in: context, parent: nil, library: library)
        let otherSection = try makeFolder(named: "Section", in: context, parent: otherProject, library: library)
        _ = try makeVideo(title: "Alpha Elsewhere", thumbnailPath: nil, in: context, folder: otherSection, library: library)
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
        _ = try makeVideo(title: "Ten", thumbnailPath: nil, in: context, folder: section, library: library, fileName: "10 - Lesson.mp4")
        _ = try makeVideo(title: "Two", thumbnailPath: nil, in: context, folder: section, library: library, fileName: "2 - Lesson.mp4")
        _ = try makeVideo(title: "Nine", thumbnailPath: nil, in: context, folder: section, library: library, fileName: "9 - Lesson.mp4")
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
        thumbnailPath: String?,
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
        video.thumbnailPath = thumbnailPath
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

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
