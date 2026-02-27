import Foundation

@MainActor
enum SearchEvidenceBuilder {
    private static let maxCitationsPerRow = 3
    private static let maxAnswerCitations = 6

    static func build(
        videos: [Video],
        query: String,
        scope: SearchManager.SearchScope
    ) -> SearchPresentationOutput {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return SearchPresentationOutput(rows: [], answerPanel: nil)
        }

        let queryTerms = normalizedTerms(from: trimmedQuery)
        var evidenceByVideoID: [UUID: [SearchEvidence]] = [:]
        var videoLookup: [UUID: Video] = [:]

        for video in videos {
            guard let videoID = video.id else { continue }
            videoLookup[videoID] = video

            let evidence = collectEvidence(
                for: video,
                query: trimmedQuery,
                queryTerms: queryTerms,
                scope: scope
            )

            if !evidence.isEmpty {
                evidenceByVideoID[videoID] = dedupeEvidence(evidence)
            }
        }

        let rows = buildRows(evidenceByVideoID: evidenceByVideoID, videoLookup: videoLookup)
        let answerPanel = buildAnswerPanel(from: rows, scope: scope)
        return SearchPresentationOutput(rows: rows, answerPanel: answerPanel)
    }

    private static func collectEvidence(
        for video: Video,
        query: String,
        queryTerms: [String],
        scope: SearchManager.SearchScope
    ) -> [SearchEvidence] {
        guard let videoID = video.id else { return [] }
        let title = (video.title ?? video.fileName ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = title.isEmpty ? "Untitled" : title

        var evidence: [SearchEvidence] = []
        let allowedSources = sources(for: scope)

        if allowedSources.contains(.title) {
            if let titleMatch = makeEvidence(
                text: effectiveTitle,
                videoID: videoID,
                videoTitle: effectiveTitle,
                source: .title,
                query: query,
                queryTerms: queryTerms,
                timestampStart: nil,
                timestampEnd: nil,
                languageCode: nil
            ) {
                evidence.append(titleMatch)
            }
        }

        if allowedSources.contains(.summary),
           let summary = video.transcriptSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty,
           let summaryMatch = makeEvidence(
                text: summary,
                videoID: videoID,
                videoTitle: effectiveTitle,
                source: .summary,
                query: query,
                queryTerms: queryTerms,
                timestampStart: nil,
                timestampEnd: nil,
                languageCode: nil
           ) {
            evidence.append(summaryMatch)
        }

        if allowedSources.contains(.transcript) {
            evidence.append(contentsOf: transcriptEvidence(for: video, videoID: videoID, videoTitle: effectiveTitle, query: query, queryTerms: queryTerms))
        }

        if allowedSources.contains(.translation) {
            evidence.append(contentsOf: translationEvidence(for: video, videoID: videoID, videoTitle: effectiveTitle, query: query, queryTerms: queryTerms))
        }

        return evidence
    }

    private static func transcriptEvidence(
        for video: Video,
        videoID: UUID,
        videoTitle: String,
        query: String,
        queryTerms: [String]
    ) -> [SearchEvidence] {
        let libraryManager = LibraryManager.shared
        var evidence: [SearchEvidence] = []

        if let timedURL = libraryManager.timedTranscriptURL(for: video),
           FileManager.default.fileExists(atPath: timedURL.path),
           let transcript = try? libraryManager.readTimedTranscript(from: timedURL) {
            let entries = transcript.makeChunkIndex(maxWordsPerChunk: 18).allEntries
            for entry in entries {
                if let match = makeEvidence(
                    text: entry.text,
                    videoID: videoID,
                    videoTitle: videoTitle,
                    source: .transcript,
                    query: query,
                    queryTerms: queryTerms,
                    timestampStart: entry.startSeconds,
                    timestampEnd: entry.endSeconds,
                    languageCode: transcript.localeIdentifier.isEmpty ? nil : transcript.localeIdentifier
                ) {
                    evidence.append(match)
                }
            }
            return evidence
        }

        if let transcriptText = video.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcriptText.isEmpty,
           let fallbackMatch = makeEvidence(
                text: transcriptText,
                videoID: videoID,
                videoTitle: videoTitle,
                source: .transcript,
                query: query,
                queryTerms: queryTerms,
                timestampStart: nil,
                timestampEnd: nil,
                languageCode: video.transcriptLanguage
           ) {
            evidence.append(fallbackMatch)
        }

        return evidence
    }

    private static func translationEvidence(
        for video: Video,
        videoID: UUID,
        videoTitle: String,
        query: String,
        queryTerms: [String]
    ) -> [SearchEvidence] {
        let libraryManager = LibraryManager.shared
        var evidence: [SearchEvidence] = []
        let languageCode = video.translatedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguageCode = languageCode?.isEmpty == true ? nil : languageCode

        if let normalizedLanguageCode,
           let timedURL = libraryManager.timedTranslationURL(for: video, languageCode: normalizedLanguageCode),
           FileManager.default.fileExists(atPath: timedURL.path),
           let timedTranslation = try? libraryManager.readTimedTranslation(from: timedURL) {
            let entries = timedTranslation.makeChunkIndex().allEntries
            for entry in entries {
                if let match = makeEvidence(
                    text: entry.text,
                    videoID: videoID,
                    videoTitle: videoTitle,
                    source: .translation,
                    query: query,
                    queryTerms: queryTerms,
                    timestampStart: entry.startSeconds,
                    timestampEnd: entry.endSeconds,
                    languageCode: normalizedLanguageCode
                ) {
                    evidence.append(match)
                }
            }
            return evidence
        }

        if let translatedText = video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translatedText.isEmpty,
           let fallbackMatch = makeEvidence(
                text: translatedText,
                videoID: videoID,
                videoTitle: videoTitle,
                source: .translation,
                query: query,
                queryTerms: queryTerms,
                timestampStart: nil,
                timestampEnd: nil,
                languageCode: normalizedLanguageCode
           ) {
            evidence.append(fallbackMatch)
        }

        return evidence
    }

    private static func makeEvidence(
        text: String,
        videoID: UUID,
        videoTitle: String,
        source: SearchMatchSource,
        query: String,
        queryTerms: [String],
        timestampStart: TimeInterval?,
        timestampEnd: TimeInterval?,
        languageCode: String?
    ) -> SearchEvidence? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return nil }

        let lowerText = normalizedText.localizedLowercase
        let lowerQuery = query.localizedLowercase

        let exactRange = lowerText.range(of: lowerQuery)
        let matchedTerms = queryTerms.filter { lowerText.contains($0) }
        guard exactRange != nil || !matchedTerms.isEmpty else { return nil }

        let matchType: SearchMatchType
        if exactRange != nil {
            matchType = .exactPhrase
        } else if matchedTerms.count > 1 {
            matchType = .tokenOverlap
        } else {
            matchType = .substring
        }

        let snippet = contextSnippet(from: normalizedText, query: query, queryTerms: queryTerms)
        let score = scoreMatch(
            text: normalizedText,
            lowerText: lowerText,
            lowerQuery: lowerQuery,
            source: source,
            exactRange: exactRange,
            matchedTerms: matchedTerms
        )

        return SearchEvidence(
            id: UUID(),
            videoID: videoID,
            videoTitle: videoTitle,
            source: source,
            snippet: snippet,
            timestampStart: timestampStart,
            timestampEnd: timestampEnd,
            languageCode: languageCode,
            score: score,
            matchType: matchType
        )
    }

    private static func scoreMatch(
        text: String,
        lowerText: String,
        lowerQuery: String,
        source: SearchMatchSource,
        exactRange: Range<String.Index>?,
        matchedTerms: [String]
    ) -> Double {
        let baseWeight: Double
        switch source {
        case .title: baseWeight = 7.0
        case .transcript: baseWeight = 5.5
        case .translation: baseWeight = 4.8
        case .summary: baseWeight = 4.5
        }

        let exactBoost = exactRange == nil ? 0.0 : 3.0
        let tokenBoost = Double(matchedTerms.count) * 0.6

        let earliestIndex: Int = {
            if let exactRange {
                return lowerText.distance(from: lowerText.startIndex, to: exactRange.lowerBound)
            }
            let termIndexes = matchedTerms.compactMap { term -> Int? in
                guard let range = lowerText.range(of: term) else { return nil }
                return lowerText.distance(from: lowerText.startIndex, to: range.lowerBound)
            }
            return termIndexes.min() ?? text.count
        }()

        let positionPenalty = Double(min(earliestIndex, 500)) / 250.0
        let densityBoost = min(1.4, Double(lowerQuery.count) / Double(max(text.count, 1)) * 20.0)
        return baseWeight + exactBoost + tokenBoost + densityBoost - positionPenalty
    }

    private static func contextSnippet(from text: String, query: String, queryTerms: [String], radius: Int = 70) -> String {
        let lowerText = text.localizedLowercase
        let lowerQuery = query.localizedLowercase

        let anchorRange: Range<String.Index>? = {
            if let range = lowerText.range(of: lowerQuery) {
                return range
            }
            for term in queryTerms {
                if let range = lowerText.range(of: term) {
                    return range
                }
            }
            return nil
        }()

        guard let anchorRange else {
            return String(text.prefix(radius * 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let distanceToStart = text.distance(from: text.startIndex, to: anchorRange.lowerBound)
        let distanceToEnd = text.distance(from: text.startIndex, to: anchorRange.upperBound)

        let startOffset = max(0, distanceToStart - radius)
        let endOffset = min(text.count, distanceToEnd + radius)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if startOffset > 0 { snippet = "..." + snippet }
        if endOffset < text.count { snippet += "..." }
        return snippet
    }

    private static func normalizedTerms(from query: String) -> [String] {
        let parts = query
            .localizedLowercase
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(parts)).sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
    }

    private static func dedupeEvidence(_ evidence: [SearchEvidence]) -> [SearchEvidence] {
        var seenKeys = Set<String>()
        let sorted = evidence.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.snippet.count < rhs.snippet.count
            }
            return lhs.score > rhs.score
        }

        var deduped: [SearchEvidence] = []
        for item in sorted {
            let key = dedupeKey(for: item)
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)
            deduped.append(item)
        }
        return deduped
    }

    private static func dedupeKey(for evidence: SearchEvidence) -> String {
        let normalizedSnippet = evidence.snippet
            .localizedLowercase
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timestampBucket = evidence.timestampStart.map { String(Int(($0 * 10).rounded())) } ?? "no-time"
        return "\(evidence.videoID.uuidString)|\(evidence.source.rawValue)|\(timestampBucket)|\(normalizedSnippet)"
    }

    private static func buildRows(
        evidenceByVideoID: [UUID: [SearchEvidence]],
        videoLookup: [UUID: Video]
    ) -> [SearchResultRowModel] {
        let rows: [SearchResultRowModel] = evidenceByVideoID.compactMap { videoID, evidence in
            guard let video = videoLookup[videoID],
                  let best = evidence.max(by: { $0.score < $1.score }) else { return nil }

            let citations = evidence
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return (lhs.timestampStart ?? .greatestFiniteMagnitude) < (rhs.timestampStart ?? .greatestFiniteMagnitude)
                    }
                    return lhs.score > rhs.score
                }
                .prefix(maxCitationsPerRow)
                .map(toCitation)

            let sourceBadges = makeSourceBadges(from: evidence)

            return SearchResultRowModel(
                id: videoID,
                video: video,
                title: best.videoTitle,
                snippet: best.snippet,
                bestSource: best.source,
                bestTimestampStart: best.timestampStart,
                bestTimestampEnd: best.timestampEnd,
                bestScore: best.score,
                citations: Array(citations),
                sourceBadges: sourceBadges
            )
        }

        return rows.sorted { lhs, rhs in
            if lhs.bestScore == rhs.bestScore {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.bestScore > rhs.bestScore
        }
    }

    private static func buildAnswerPanel(
        from rows: [SearchResultRowModel],
        scope: SearchManager.SearchScope
    ) -> SearchAnswerPanelModel? {
        let citations = rows
            .flatMap(\.citations)
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.videoTitle.localizedCaseInsensitiveCompare(rhs.videoTitle) == .orderedAscending
                }
                return lhs.score > rhs.score
            }
            .prefix(maxAnswerCitations)

        let topCitations = Array(citations)
        guard !topCitations.isEmpty else { return nil }

        let distinctVideoCount = Set(topCitations.map(\.videoID)).count
        let sourceBadges = makeSourceBadges(from: topCitations.map {
            SearchEvidence(
                id: $0.id,
                videoID: $0.videoID,
                videoTitle: $0.videoTitle,
                source: $0.source,
                snippet: $0.snippet,
                timestampStart: $0.timestampStart,
                timestampEnd: $0.timestampEnd,
                languageCode: $0.languageCode,
                score: $0.score,
                matchType: .substring
            )
        })

        let topSource = sourceBadges.max { $0.count < $1.count }?.source
        let timestamped = topCitations.filter { $0.timestampStart != nil }
        let summary: String = {
            let scopeLabel = scope.rawValue.lowercased()
            if let topSource {
                if let firstTimed = timestamped.first,
                   let start = firstTimed.timestampStart {
                    return "Top matches are concentrated in \(distinctVideoCount) video\(distinctVideoCount == 1 ? "" : "s"). Most hits come from \(topSource.displayName.lowercased()) content in the \(scopeLabel) scope, with strong timestamped matches starting around \(formatTime(start))."
                }
                return "Top matches are concentrated in \(distinctVideoCount) video\(distinctVideoCount == 1 ? "" : "s"). Most hits come from \(topSource.displayName.lowercased()) content in the \(scopeLabel) scope."
            }
            return "Top matches are concentrated in \(distinctVideoCount) video\(distinctVideoCount == 1 ? "" : "s") in the \(scopeLabel) scope."
        }()

        return SearchAnswerPanelModel(
            summaryText: summary,
            citations: topCitations,
            sourceBadges: sourceBadges,
            scopeLabel: scope.rawValue
        )
    }

    private static func makeSourceBadges(from evidence: [SearchEvidence]) -> [SearchSourceBadge] {
        let grouped = Dictionary(grouping: evidence) { item in
            "\(item.source.rawValue)|\(item.source == .translation ? (item.languageCode ?? "") : "")"
        }

        return grouped.values.compactMap { items in
            guard let first = items.first else { return nil }
            return SearchSourceBadge(
                source: first.source,
                count: items.count,
                languageCode: first.source == .translation ? first.languageCode : nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.source.displayName < rhs.source.displayName
            }
            return lhs.count > rhs.count
        }
    }

    private static func toCitation(_ evidence: SearchEvidence) -> SearchCitation {
        SearchCitation(
            id: evidence.id,
            videoID: evidence.videoID,
            videoTitle: evidence.videoTitle,
            source: evidence.source,
            snippet: evidence.snippet,
            timestampStart: evidence.timestampStart,
            timestampEnd: evidence.timestampEnd,
            languageCode: evidence.languageCode,
            score: evidence.score
        )
    }

    private static func sources(for scope: SearchManager.SearchScope) -> Set<SearchMatchSource> {
        switch scope {
        case .all:
            return [.title, .transcript, .translation, .summary]
        case .titles:
            return [.title]
        case .transcripts:
            return [.transcript]
        case .translations:
            return [.translation]
        case .summaries:
            return [.summary]
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
