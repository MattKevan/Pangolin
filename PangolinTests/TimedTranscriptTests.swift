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

    @Test("Migration to 1.1.0 wipes text fields and artifacts")
    @MainActor
    func migrationWipesLegacyTextData() async throws {
        let manager = LibraryManager.shared
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinMigrationTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let library = try await manager.createLibrary(at: tempRoot, name: "MigrationTest")
        guard let context = manager.viewContext else {
            #expect(false)
            return
        }

        guard let videoEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            #expect(false)
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
            #expect(false)
            return
        }

        await manager.closeCurrentLibrary()
        _ = try await manager.openLibrary(at: libraryURL)

        guard let reopenedContext = manager.viewContext else {
            #expect(false)
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
}
