//
//  Video+GeneratedText.swift
//  Pangolin
//

import Foundation

extension Video {
    /// Clears the generated transcript, translation and summary fields. Does not save.
    func clearGeneratedText() {
        transcriptText = nil
        transcriptLanguage = nil
        transcriptDateGenerated = nil
        translatedText = nil
        translatedLanguage = nil
        translationDateGenerated = nil
        transcriptSummary = nil
        summaryDateGenerated = nil
    }
}
