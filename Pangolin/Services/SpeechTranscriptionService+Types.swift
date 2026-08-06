import Foundation

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case languageNotSupported(Locale)
    case audioExtractionFailed
    case videoFileNotFound
    case noSpeechDetected
    case assetInstallationFailed
    case analysisFailed(String)
    case translationNotSupported(String, String)
    case translationFailed(String)
    case translationModelsNotInstalled(String, String)
    case summarizationFailed(String)
    case flashcardsGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission was denied."
        case .languageNotSupported(let locale):
            let localized = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            return "Detected language '\(localized)' (\(locale.identifier)) is not supported for transcription on this device."
        case .audioExtractionFailed:
            return "Failed to extract a usable audio track from the video file."
        case .videoFileNotFound:
            return "The video file could not be found. It may have been moved or deleted."
        case .noSpeechDetected:
            return "No recognizable speech could be detected in the video's audio track."
        case .assetInstallationFailed:
            return "Failed to download required language models. Please check your internet connection."
        case .analysisFailed(let reason):
            return "The transcription analysis failed: \(reason)"
        case .translationNotSupported(let from, let to):
            return "Translation from \(from) to \(to) is not supported on this device."
        case .translationFailed(let reason):
            return "Translation failed: \(reason)"
        case .translationModelsNotInstalled(let from, let to):
            return "Translation models for \(from) to \(to) are not installed on this system."
        case .summarizationFailed(let reason):
            return "Summarization failed: \(reason)"
        case .flashcardsGenerationFailed(let reason):
            return "Flashcards generation failed: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Please go to System Settings > Privacy & Security > Speech Recognition and grant access to Pangolin."
        case .languageNotSupported:
            return "Try selecting a supported language manually in Transcript Controls, or connect to the internet so additional language assets can be installed."
        case .audioExtractionFailed:
            return "Try converting the video to a standard format like MP4 and re-importing it."
        case .videoFileNotFound:
            return "Please re-import the video into your Pangolin library."
        case .noSpeechDetected:
            return "The audio may be silent/noisy. Verify audio playback, then retry or select the language manually in Transcript Controls."
        case .assetInstallationFailed:
            return "Ensure you have a stable internet connection and sufficient disk space, then try again."
        case .analysisFailed:
            return "This may be a temporary issue with the Speech framework. Please try again later."
        case .translationNotSupported:
            return "Enable translation languages in System Settings > General > Language & Region."
        case .translationFailed:
            return "Check your internet connection and try again. Translation requires network access and may need to download translation models."
        case .translationModelsNotInstalled:
            return "Go to System Settings → General → Language & Region → Translation Languages to download the required translation models, then try again."
        case .summarizationFailed:
            return "Ensure Apple Intelligence is enabled in System Settings and try again. Summarisation requires Apple Intelligence to be active."
        case .flashcardsGenerationFailed:
            return "Ensure transcript data is available and Apple Intelligence is enabled, then retry."
        }
    }
}

struct TranscriptionOutput: Sendable {
    let plainText: String
    let timedTranscript: TimedTranscript
}

struct TranslationOutput: Sendable {
    let plainText: String
    let timedTranslation: TimedTranslation
}

/// The AI-powered flows a video page can run. Only one may be active at a time.
enum TranscriptionFlowKind: Equatable, Sendable {
    case transcription
    case translation
    case summarization
    case flashcards
}

/// Pure decision logic enforcing the single-active-flow guarantee.
enum TranscriptionFlowClaimPolicy {
    static func canClaim(activeFlow: TranscriptionFlowKind?) -> Bool {
        activeFlow == nil
    }

    static func release(activeFlow: TranscriptionFlowKind?, for kind: TranscriptionFlowKind) -> TranscriptionFlowKind? {
        activeFlow == kind ? nil : activeFlow
    }
}
