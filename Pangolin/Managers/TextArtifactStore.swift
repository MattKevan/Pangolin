//
//  TextArtifactStore.swift
//  Pangolin
//

import Foundation
import os

/// Where a library's generated text (transcripts, translations, summaries, flashcards)
/// lives on disk, plus the atomic read/write helpers for those files.
///
/// Files live in the iCloud container when it is available so they sync between
/// devices, and fall back to the library folder otherwise.
@MainActor
final class TextArtifactStore {
    struct Directories {
        let transcripts: URL
        let translations: URL
        let summaries: URL
        let flashcards: URL

        init(root: URL) {
            transcripts = root.appendingPathComponent("Transcripts", isDirectory: true)
            translations = root.appendingPathComponent("Translations", isDirectory: true)
            summaries = root.appendingPathComponent("Summaries", isDirectory: true)
            flashcards = root.appendingPathComponent("Flashcards", isDirectory: true)
        }

        var all: [URL] { [transcripts, translations, summaries, flashcards] }
    }

    enum Artifact {
        case transcript
        case timedTranscript
        case translation(language: String)
        case timedTranslation(language: String)
        case summary
        case flashcards

        var directory: KeyPath<Directories, URL> {
            switch self {
            case .transcript, .timedTranscript: \.transcripts
            case .translation, .timedTranslation: \.translations
            case .summary: \.summaries
            case .flashcards: \.flashcards
            }
        }

        func fileName(for id: UUID) -> String {
            switch self {
            case .transcript: "\(id.uuidString).txt"
            case .timedTranscript: "\(id.uuidString).timed.json"
            case .translation(let language): "\(id.uuidString)_\(Self.safe(language)).txt"
            case .timedTranslation(let language): "\(id.uuidString)_\(Self.safe(language)).timed.json"
            case .summary: "\(id.uuidString).md"
            case .flashcards: "\(id.uuidString).json"
            }
        }

        private static func safe(_ language: String) -> String {
            language.replacingOccurrences(of: "/", with: "-")
        }
    }

    /// Folder of the open library on this device.
    var libraryRoot: URL? { LibraryLocation.url }

    var cloudRootProvider: () -> URL? = {
        let fileManager = FileManager.default
        return fileManager.url(forUbiquityContainerIdentifier: VideoFileManager.shared.cloudContainerIdentifier)
            ?? fileManager.url(forUbiquityContainerIdentifier: nil)
    }

    private let fileManager = FileManager.default

    // MARK: - Locations

    private func localDirectories(root: URL?) -> Directories? {
        root.map(Directories.init(root:))
    }

    private func cloudDirectories() -> Directories? {
        cloudRootProvider().map(Directories.init(root:))
    }

    /// Cloud when available, otherwise the library folder.
    private func preferredDirectories(root: URL?) -> Directories? {
        cloudDirectories() ?? localDirectories(root: root)
    }

    private func localRoot(for video: Video) -> URL? {
        video.library?.url ?? libraryRoot
    }

    func ensureDirectories(libraryRoot root: URL? = nil) throws {
        guard let directories = preferredDirectories(root: root ?? libraryRoot) else { return }
        for directory in directories.all {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Per-video URLs

    /// Where the artifact should be written.
    func url(for artifact: Artifact, video: Video) -> URL? {
        guard let id = video.id,
              let directories = preferredDirectories(root: localRoot(for: video)) else { return nil }
        return directories[keyPath: artifact.directory].appendingPathComponent(artifact.fileName(for: id))
    }

    /// Where the artifact exists now. Falls back to the library folder and copies it
    /// to the preferred location when it is only found there.
    func existingURL(for artifact: Artifact, video: Video) -> URL? {
        guard let id = video.id else { return nil }
        let root = localRoot(for: video)
        let fileName = artifact.fileName(for: id)
        let preferred = preferredDirectories(root: root)?[keyPath: artifact.directory].appendingPathComponent(fileName)
        let local = localDirectories(root: root)?[keyPath: artifact.directory].appendingPathComponent(fileName)
        return resolveExisting(preferred: preferred, fallback: local)
    }

    func transcriptURL(for video: Video) -> URL? { url(for: .transcript, video: video) }
    func existingTranscriptURL(for video: Video) -> URL? { existingURL(for: .transcript, video: video) }

    func timedTranscriptURL(for video: Video) -> URL? { url(for: .timedTranscript, video: video) }
    func existingTimedTranscriptURL(for video: Video) -> URL? { existingURL(for: .timedTranscript, video: video) }

    func translationURL(for video: Video, languageCode: String) -> URL? {
        url(for: .translation(language: languageCode), video: video)
    }

    func existingTranslationURL(for video: Video, languageCode: String) -> URL? {
        existingURL(for: .translation(language: languageCode), video: video)
    }

    func timedTranslationURL(for video: Video, languageCode: String) -> URL? {
        url(for: .timedTranslation(language: languageCode), video: video)
    }

    func existingTimedTranslationURL(for video: Video, languageCode: String) -> URL? {
        existingURL(for: .timedTranslation(language: languageCode), video: video)
    }

    func summaryURL(for video: Video) -> URL? { url(for: .summary, video: video) }
    func existingSummaryURL(for video: Video) -> URL? { existingURL(for: .summary, video: video) }

    func flashcardsURL(for video: Video) -> URL? { url(for: .flashcards, video: video) }
    func existingFlashcardsURL(for video: Video) -> URL? { existingURL(for: .flashcards, video: video) }

    /// Every translation file for the video, whatever the language or format.
    func translationURLs(for video: Video) -> [URL] {
        guard let id = video.id,
              let directories = preferredDirectories(root: localRoot(for: video)) else { return [] }
        let prefix = id.uuidString + "_"
        let urls = (try? fileManager.contentsOfDirectory(at: directories.translations, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    // MARK: - Migration

    /// Copies artifacts from the library folder into the iCloud container.
    /// Does nothing when iCloud is unavailable.
    func migrateToPreferredLocation(libraryRoot root: URL?) throws {
        guard let destination = cloudDirectories(), let root else { return }
        try migrate(from: Directories(root: root), to: destination)
    }

    /// Deletes every artifact directory, local and cloud, then recreates the preferred ones.
    func removeAllDirectories(libraryRoot root: URL?) throws {
        let directories = (localDirectories(root: root)?.all ?? []) + (cloudDirectories()?.all ?? [])
        var removed = Set<String>()
        for directory in directories where removed.insert(directory.standardizedFileURL.path).inserted {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        try ensureDirectories(libraryRoot: root)
    }

    private func migrate(from source: Directories, to destination: Directories) throws {
        for (sourceDirectory, destinationDirectory) in zip(source.all, destination.all) {
            guard sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL,
                  fileManager.fileExists(atPath: sourceDirectory.path) else { continue }

            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files {
                copyIfMissing(from: file, to: destinationDirectory.appendingPathComponent(file.lastPathComponent))
            }
        }
    }

    private func copyIfMissing(from source: URL, to destination: URL) {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            Logger.library.warning("LIBRARY: Failed to migrate artifact \(source.lastPathComponent) to shared storage: \(error)")
        }
    }

    private func resolveExisting(preferred: URL?, fallback: URL?) -> URL? {
        if let preferred, fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        guard let fallback, fileManager.fileExists(atPath: fallback.path) else { return nil }
        if let preferred {
            copyIfMissing(from: fallback, to: preferred)
            if fileManager.fileExists(atPath: preferred.path) {
                return preferred
            }
        }
        return fallback
    }

    // MARK: - Reading and writing

    nonisolated func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    nonisolated func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try writeAtomically(encoder.encode(value), to: url)
    }

    nonisolated func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    nonisolated func writeTextAtomically(_ text: String, to url: URL) throws {
        try writeAtomically(Data(text.utf8), to: url)
    }

    nonisolated func writeTimedTranscriptAtomically(_ transcript: TimedTranscript, to url: URL) throws {
        try writeJSON(transcript, to: url)
    }

    nonisolated func readTimedTranscript(from url: URL) throws -> TimedTranscript {
        try readJSON(TimedTranscript.self, from: url)
    }

    nonisolated func readTimedTranscriptIfAvailable(from url: URL) throws -> TimedTranscript? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readTimedTranscript(from: url)
    }

    nonisolated func writeTimedTranslationAtomically(_ translation: TimedTranslation, to url: URL) throws {
        try writeJSON(translation, to: url)
    }

    nonisolated func readTimedTranslation(from url: URL) throws -> TimedTranslation {
        try readJSON(TimedTranslation.self, from: url)
    }

    nonisolated func writeFlashcardDeckAtomically(_ deck: FlashcardDeck, to url: URL) throws {
        try writeJSON(deck, to: url)
    }

    nonisolated func readFlashcardDeck(from url: URL) throws -> FlashcardDeck {
        try readJSON(FlashcardDeck.self, from: url)
    }
}
