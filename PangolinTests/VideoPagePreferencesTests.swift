import Foundation
import Testing
@testable import Pangolin

struct VideoPagePreferencesTests {
    @Test("Video page preferences default auto-translate to enabled")
    func autoTranslateDefaultsToEnabled() {
        let suiteName = "VideoPagePreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = VideoPagePreferences(userDefaults: defaults)

        #expect(preferences.isAutoTranslateEnabled == true)
    }

    @Test("Video page preferences keep a stored supported language")
    func preferencesKeepStoredSupportedLanguage() {
        let resolved = VideoPagePreferences.resolvedPreferredTranslationLocaleIdentifier(
            storedIdentifier: "fr-FR",
            supportedLocaleIdentifiers: ["en-US", "fr-FR"],
            systemLocaleIdentifier: "en-GB"
        )

        #expect(resolved == "fr-FR")
    }

    @Test("Video page preferences fall back to supported system language")
    func preferencesFallBackToSupportedSystemLanguage() {
        let resolved = VideoPagePreferences.resolvedPreferredTranslationLocaleIdentifier(
            storedIdentifier: nil,
            supportedLocaleIdentifiers: ["en-US", "fr-FR"],
            systemLocaleIdentifier: "en-GB"
        )

        #expect(resolved == "en-US")
    }

    @Test("Video page preferences fall back to first supported language when system is unsupported")
    func preferencesFallBackToFirstSupportedLanguage() {
        let resolved = VideoPagePreferences.resolvedPreferredTranslationLocaleIdentifier(
            storedIdentifier: "de-DE",
            supportedLocaleIdentifiers: ["fr-FR", "es-ES"],
            systemLocaleIdentifier: "en-GB"
        )

        #expect(resolved == "fr-FR")
    }
}
