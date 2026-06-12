import Foundation
import Testing
@testable import Pangolin

struct TimedTranscriptTests {
    @Test("TimedTranscript Codable roundtrip")
    func timedTranscriptCodableRoundtrip() throws {
        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 12345),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 2,
                    text: "hello world",
                    words: [
                        TimedWord(startSeconds: 0, endSeconds: 1, text: "hello"),
                        TimedWord(startSeconds: 1, endSeconds: 2, text: "world"),
                    ]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcript)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TimedTranscript.self, from: data)

        #expect(decoded == transcript)
    }

    @Test("Timed transcript optional read returns nil when file is missing")
    @MainActor
    func timedTranscriptOptionalReadReturnsNilWhenFileIsMissing() throws {
        let manager = LibraryManager.shared
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingTimedTranscript-\(UUID().uuidString)")
            .appendingPathExtension("timed.json")

        let transcript = try manager.readTimedTranscriptIfAvailable(from: missingURL)
        #expect(transcript == nil)
    }

    @Test("Timed transcript optional read returns transcript when file exists")
    @MainActor
    func timedTranscriptOptionalReadReturnsTranscriptWhenFileExists() throws {
        let manager = LibraryManager.shared
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TimedTranscriptOptionalRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 12345),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 2,
                    text: "hello world",
                    words: [
                        TimedWord(startSeconds: 0, endSeconds: 1, text: "hello"),
                        TimedWord(startSeconds: 1, endSeconds: 2, text: "world"),
                    ]
                )
            ]
        )

        let url = tempRoot.appendingPathComponent("\(transcript.videoID.uuidString).timed.json")
        try manager.writeTimedTranscriptAtomically(transcript, to: url)

        let loadedTranscript = try manager.readTimedTranscriptIfAvailable(from: url)
        #expect(loadedTranscript == transcript)
    }

    @Test("Timed transcript URL prefers shared cloud root when available")
    @MainActor
    func timedTranscriptURLPrefersSharedCloudRootWhenAvailable() async throws {
        let manager = LibraryManager.shared
        let originalProvider = manager.textArtifactsCloudRootURLProvider
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("TimedTranscriptSharedRoot-\(UUID().uuidString)", isDirectory: true)
        let cloudRoot = tempRoot.appendingPathComponent("CloudRoot", isDirectory: true)
        let libraryURL = tempRoot.appendingPathComponent("Library", isDirectory: true)

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        manager.textArtifactsCloudRootURLProvider = { cloudRoot }
        defer {
            manager.textArtifactsCloudRootURLProvider = originalProvider
            try? fileManager.removeItem(at: tempRoot)
        }

        let library = try await manager.createLibrary(at: libraryURL, name: "SharedRootTest")
        guard let context = manager.viewContext else {
            #expect(Bool(false))
            return
        }
        guard let videoEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            #expect(Bool(false))
            return
        }

        let video = Video(entity: videoEntity, insertInto: context)
        video.id = UUID()
        video.title = "Clip"
        video.library = library
        try context.save()

        let expectedURL = cloudRoot
            .appendingPathComponent("Transcripts", isDirectory: true)
            .appendingPathComponent("\(try #require(video.id).uuidString).timed.json")

        #expect(manager.timedTranscriptURL(for: video) == expectedURL)

        await manager.closeCurrentLibrary()
    }

    @Test("Existing timed transcript migrates local artifact to shared cloud root")
    @MainActor
    func existingTimedTranscriptMigratesLocalArtifactToSharedCloudRoot() async throws {
        let manager = LibraryManager.shared
        let originalProvider = manager.textArtifactsCloudRootURLProvider
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("TimedTranscriptMigration-\(UUID().uuidString)", isDirectory: true)
        let cloudRoot = tempRoot.appendingPathComponent("CloudRoot", isDirectory: true)
        let libraryURL = tempRoot.appendingPathComponent("Library", isDirectory: true)

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        manager.textArtifactsCloudRootURLProvider = { cloudRoot }
        defer {
            manager.textArtifactsCloudRootURLProvider = originalProvider
            try? fileManager.removeItem(at: tempRoot)
        }

        let library = try await manager.createLibrary(at: libraryURL, name: "MigrationTest")
        guard let context = manager.viewContext else {
            #expect(Bool(false))
            return
        }
        guard let videoEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            #expect(Bool(false))
            return
        }

        let video = Video(entity: videoEntity, insertInto: context)
        video.id = UUID()
        video.title = "Clip"
        video.library = library
        try context.save()

        let transcript = TimedTranscript(
            videoID: try #require(video.id),
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 12345),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 2,
                    text: "hello world",
                    words: [
                        TimedWord(startSeconds: 0, endSeconds: 1, text: "hello"),
                        TimedWord(startSeconds: 1, endSeconds: 2, text: "world"),
                    ]
                )
            ]
        )

        let localURL = libraryURL
            .appendingPathComponent("Transcripts", isDirectory: true)
            .appendingPathComponent("\(transcript.videoID.uuidString).timed.json")
        try manager.writeTimedTranscriptAtomically(transcript, to: localURL)

        let resolvedURL = try #require(manager.existingTimedTranscriptURL(for: video))
        let expectedCloudURL = cloudRoot
            .appendingPathComponent("Transcripts", isDirectory: true)
            .appendingPathComponent("\(transcript.videoID.uuidString).timed.json")

        #expect(resolvedURL == expectedCloudURL)
        #expect(fileManager.fileExists(atPath: expectedCloudURL.path))
        #expect(try manager.readTimedTranscript(from: expectedCloudURL) == transcript)

        await manager.closeCurrentLibrary()
    }

    @Test("Token timing split is proportional by token length")
    func tokenTimingSplitIsProportional() {
        let words = SpeechTranscriptionService.proportionalWordTimingTokens(
            text: "swift a",
            startSeconds: 0,
            endSeconds: 6
        )

        #expect(words.count == 2)
        #expect(words[0].text == "swift")
        #expect(words[1].text == "a")

        let firstDuration = words[0].endSeconds - words[0].startSeconds
        let secondDuration = words[1].endSeconds - words[1].startSeconds
        #expect(firstDuration > secondDuration)
        #expect(abs(words[1].endSeconds - 6) < 0.0001)
    }

    @Test("FlatIndex finds active word at boundaries")
    func flatIndexActiveWordBoundaries() {
        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en-US",
            generatedAt: Date(),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 1,
                    text: "one two",
                    words: [
                        TimedWord(startSeconds: 0.0, endSeconds: 0.5, text: "one"),
                        TimedWord(startSeconds: 0.5, endSeconds: 1.0, text: "two"),
                    ]
                )
            ]
        )
        let index = transcript.makeFlatIndex()

        #expect(index.activeWord(at: 0.0)?.word.text == "one")
        #expect(index.activeWord(at: 0.49)?.word.text == "one")
        #expect(index.activeWord(at: 0.5)?.word.text == "two")
        #expect(index.activeWord(at: 1.1) == nil)
    }

    @Test("Chunk index groups words by punctuation or chunk size")
    func chunkIndexGroupsWordsByPunctuationOrSize() {
        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en-US",
            generatedAt: Date(),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 6,
                    text: "This is a sentence. Another small line",
                    words: [
                        TimedWord(startSeconds: 0.0, endSeconds: 0.5, text: "This"),
                        TimedWord(startSeconds: 0.5, endSeconds: 1.0, text: "is"),
                        TimedWord(startSeconds: 1.0, endSeconds: 1.5, text: "a"),
                        TimedWord(startSeconds: 1.5, endSeconds: 2.0, text: "sentence."),
                        TimedWord(startSeconds: 2.0, endSeconds: 2.5, text: "Another"),
                        TimedWord(startSeconds: 2.5, endSeconds: 3.0, text: "small"),
                        TimedWord(startSeconds: 3.0, endSeconds: 3.5, text: "line"),
                    ]
                )
            ]
        )

        let chunks = transcript.makeChunkIndex(maxWordsPerChunk: 3).allEntries
        #expect(chunks.count == 3)
        #expect(chunks[0].text == "This is a")
        #expect(chunks[1].text == "sentence.")
        #expect(chunks[2].text == "Another small line")
    }

    @Test("Chunk index finds active chunk at boundaries")
    func chunkIndexActiveChunkBoundaries() {
        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en-US",
            generatedAt: Date(),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 4,
                    text: "One. Two.",
                    words: [
                        TimedWord(startSeconds: 0.0, endSeconds: 1.0, text: "One."),
                        TimedWord(startSeconds: 1.2, endSeconds: 2.0, text: "Two."),
                    ]
                )
            ]
        )

        let index = transcript.makeChunkIndex(maxWordsPerChunk: 8)
        #expect(index.activeChunk(at: 0.1)?.text == "One.")
        #expect(index.activeChunk(at: 1.5)?.text == "Two.")
        #expect(index.activeChunk(at: 2.5) == nil)
    }

    @Test("Chunk index does not force boundaries at segment edges")
    func chunkIndexCanBridgeSegments() {
        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en-US",
            generatedAt: Date(),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 1,
                    text: "This is",
                    words: [
                        TimedWord(startSeconds: 0.0, endSeconds: 0.4, text: "This"),
                        TimedWord(startSeconds: 0.4, endSeconds: 0.8, text: "is"),
                    ]
                ),
                TimedSegment(
                    startSeconds: 0.8,
                    endSeconds: 2.0,
                    text: "one sentence.",
                    words: [
                        TimedWord(startSeconds: 0.8, endSeconds: 1.2, text: "one"),
                        TimedWord(startSeconds: 1.2, endSeconds: 1.8, text: "sentence."),
                    ]
                ),
            ]
        )

        let chunks = transcript.makeChunkIndex(maxWordsPerChunk: 12).allEntries
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "This is one sentence.")
    }

    @Test("Migration to 1.1.0 wipes text fields and artifacts")
    @MainActor
    func migrationWipesLegacyTextData() async throws {
        let manager = LibraryManager.shared
        let originalProvider = manager.textArtifactsCloudRootURLProvider
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinMigrationTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        manager.textArtifactsCloudRootURLProvider = { nil }
        defer {
            manager.textArtifactsCloudRootURLProvider = originalProvider
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let library = try await manager.createLibrary(at: tempRoot, name: "MigrationTest")
        guard let context = manager.viewContext else {
            #expect(Bool(false))
            return
        }

        guard let videoEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            #expect(Bool(false))
            return
        }

        let video = Video(entity: videoEntity, insertInto: context)
        video.id = UUID()
        video.title = "Clip"
        video.library = library
        video.transcriptText = "legacy transcript"
        video.transcriptLanguage = "en-US"
        video.transcriptDateGenerated = Date()
        video.translatedText = "legacy translation"
        video.translatedLanguage = "fr"
        video.translationDateGenerated = Date()
        video.transcriptSummary = "legacy summary"
        video.summaryDateGenerated = Date()

        try context.save()
        try manager.ensureTextArtifactDirectories()

        if let transcriptURL = manager.transcriptURL(for: video) {
            try "legacy".write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        if let timedURL = manager.timedTranscriptURL(for: video) {
            try "legacy".write(to: timedURL, atomically: true, encoding: .utf8)
        }
        if let summaryURL = manager.summaryURL(for: video) {
            try "legacy".write(to: summaryURL, atomically: true, encoding: .utf8)
        }
        if let translationURL = manager.translationURL(for: video, languageCode: "fr") {
            try "legacy".write(to: translationURL, atomically: true, encoding: .utf8)
        }

        library.version = "1.0.0"
        try context.save()

        guard let libraryURL = library.url else {
            #expect(Bool(false))
            return
        }

        await manager.closeCurrentLibrary()
        _ = try await manager.openLibrary(at: libraryURL)

        guard let reopenedContext = manager.viewContext else {
            #expect(Bool(false))
            return
        }
        let request = Video.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", video.id! as CVarArg)
        let reopenedVideo = try reopenedContext.fetch(request).first

        #expect(reopenedVideo?.transcriptText == nil)
        #expect(reopenedVideo?.transcriptLanguage == nil)
        #expect(reopenedVideo?.transcriptDateGenerated == nil)
        #expect(reopenedVideo?.translatedText == nil)
        #expect(reopenedVideo?.translatedLanguage == nil)
        #expect(reopenedVideo?.translationDateGenerated == nil)
        #expect(reopenedVideo?.transcriptSummary == nil)
        #expect(reopenedVideo?.summaryDateGenerated == nil)

        let transcriptsDir = libraryURL.appendingPathComponent("Transcripts", isDirectory: true)
        let translationsDir = libraryURL.appendingPathComponent("Translations", isDirectory: true)
        let summariesDir = libraryURL.appendingPathComponent("Summaries", isDirectory: true)

        let transcriptFiles = try FileManager.default.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: nil)
        let translationFiles = try FileManager.default.contentsOfDirectory(at: translationsDir, includingPropertiesForKeys: nil)
        let summaryFiles = try FileManager.default.contentsOfDirectory(at: summariesDir, includingPropertiesForKeys: nil)

        #expect(transcriptFiles.isEmpty)
        #expect(translationFiles.isEmpty)
        #expect(summaryFiles.isEmpty)

        await manager.closeCurrentLibrary()
    }

    @Test("Migration uses opened library URL instead of stale stored path")
    @MainActor
    func migrationUsesOpenedLibraryURLInsteadOfStaleStoredPath() async throws {
        let manager = LibraryManager.shared
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("PangolinStalePathMigration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let staleParent = tempRoot.appendingPathComponent("ReadOnlyParent", isDirectory: true)
        try fileManager.createDirectory(at: staleParent, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staleParent.path)

        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staleParent.path)
            try? fileManager.removeItem(at: tempRoot)
        }

        let libraryURL = tempRoot.appendingPathComponent("ActualLibrary", isDirectory: true)
        let library = try await manager.createLibrary(at: libraryURL, name: "StalePathTest")

        guard let context = manager.viewContext else {
            #expect(Bool(false))
            return
        }

        library.version = "1.0.0"
        library.libraryPath = staleParent.appendingPathComponent("Library.pangolin", isDirectory: true).path
        try context.save()

        await manager.closeCurrentLibrary()

        let reopenedLibrary = try await manager.openLibrary(at: libraryURL)
        #expect(reopenedLibrary.libraryPath == libraryURL.path)
        #expect(fileManager.fileExists(atPath: staleParent.appendingPathComponent("Library.pangolin", isDirectory: true).path) == false)

        await manager.closeCurrentLibrary()
    }

}
