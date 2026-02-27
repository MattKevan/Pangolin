import Foundation

enum SearchMatchSource: String, CaseIterable, Hashable {
    case title
    case transcript
    case translation
    case summary

    var displayName: String {
        switch self {
        case .title: return "Title"
        case .transcript: return "Transcript"
        case .translation: return "Translation"
        case .summary: return "Summary"
        }
    }

    var shortLabel: String {
        switch self {
        case .title: return "Title"
        case .transcript: return "Transcript"
        case .translation: return "Translation"
        case .summary: return "Summary"
        }
    }

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .transcript: return "doc.text"
        case .translation: return "globe"
        case .summary: return "doc.text.below.ecg"
        }
    }
}

enum SearchMatchType: String, Hashable {
    case exactPhrase
    case tokenOverlap
    case substring
}

struct SearchSourceBadge: Identifiable, Hashable {
    let source: SearchMatchSource
    let count: Int
    let languageCode: String?

    var id: String {
        "\(source.rawValue)|\(languageCode ?? "")|\(count)"
    }

    var label: String {
        if let languageCode, source == .translation {
            return "\(count) \(source.shortLabel) (\(languageCode.uppercased()))"
        }
        return "\(count) \(source.shortLabel)"
    }
}

struct SearchEvidence: Identifiable, Hashable {
    let id: UUID
    let videoID: UUID
    let videoTitle: String
    let source: SearchMatchSource
    let snippet: String
    let timestampStart: TimeInterval?
    let timestampEnd: TimeInterval?
    let languageCode: String?
    let score: Double
    let matchType: SearchMatchType
}

struct SearchCitation: Identifiable, Hashable {
    let id: UUID
    let videoID: UUID
    let videoTitle: String
    let source: SearchMatchSource
    let snippet: String
    let timestampStart: TimeInterval?
    let timestampEnd: TimeInterval?
    let languageCode: String?
    let score: Double
}

struct SearchResultRowModel: Identifiable {
    let id: UUID
    let video: Video
    let title: String
    let snippet: String
    let bestSource: SearchMatchSource
    let bestTimestampStart: TimeInterval?
    let bestTimestampEnd: TimeInterval?
    let bestScore: Double
    let citations: [SearchCitation]
    let sourceBadges: [SearchSourceBadge]

    var sourceSortKey: String { bestSource.rawValue }
    var timeSortKey: Double { bestTimestampStart ?? .greatestFiniteMagnitude }
    var scoreSortKey: Double { bestScore }
    var titleSortKey: String { title }
}

struct SearchAnswerPanelModel {
    let summaryText: String
    let citations: [SearchCitation]
    let sourceBadges: [SearchSourceBadge]
    let scopeLabel: String
}

struct SearchPresentationOutput {
    let rows: [SearchResultRowModel]
    let answerPanel: SearchAnswerPanelModel?
}

struct SearchSeekRequest: Equatable {
    let videoID: UUID
    let seconds: TimeInterval?
    let source: SearchMatchSource?
}
