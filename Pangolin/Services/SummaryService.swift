import Foundation
import NaturalLanguage

@MainActor
class SummaryService: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    
    func generateSummary(for video: Video, libraryManager: LibraryManager) async {
        guard !isGenerating else { return }
        guard let transcriptText = video.transcriptText, !transcriptText.isEmpty else {
            errorMessage = "No transcript available to summarize"
            return
        }
        
        isGenerating = true
        errorMessage = nil
        
        let summary = await generateTextSummary(from: transcriptText)
        
        // Save the summary
        video.transcriptSummary = summary
        await libraryManager.save()
        
        isGenerating = false
    }
    
    private func generateTextSummary(from text: String) async -> String {
        // Split text into sentences
        let sentences = extractSentences(from: text)
        
        guard !sentences.isEmpty else {
            return "No content available to summarize."
        }
        
        // If the text is short, return it as-is with basic formatting
        if sentences.count <= 5 {
            return formatShortSummary(sentences)
        }
        
        // For longer texts, extract key sentences
        let keyPoints = extractKeyPoints(from: sentences)
        let summary = formatSummary(keyPoints)
        
        return summary
    }
    
    private func extractSentences(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let sentence = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty && sentence.count > 10 { // Filter out very short fragments
                sentences.append(sentence)
            }
            return true
        }
        
        return sentences
    }
    
    private func extractKeyPoints(from sentences: [String]) -> [String] {
        // Simple extraction algorithm:
        // 1. Score sentences based on word frequency and position
        // 2. Select top sentences up to a reasonable limit
        
        let wordFrequency = calculateWordFrequency(from: sentences)
        let scoredSentences = sentences.enumerated().map { (index, sentence) in
            let score = scoreSentence(sentence, wordFrequency: wordFrequency, position: index, totalSentences: sentences.count)
            return (sentence: sentence, score: score)
        }
        
        // Sort by score and take top sentences (up to 30% of original, minimum 3, maximum 10)
        let targetCount = max(3, min(10, sentences.count / 3))
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(targetCount)
            .sorted { sentences.firstIndex(of: $0.sentence) ?? 0 < sentences.firstIndex(of: $1.sentence) ?? 0 }
            .map { $0.sentence }
        
        return topSentences
    }
    
    private func calculateWordFrequency(from sentences: [String]) -> [String: Int] {
        var frequency: [String: Int] = [:]
        let text = sentences.joined(separator: " ")
        
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        
        // Common stop words to filter out
        let stopWords = Set(["the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "is", "are", "was", "were", "be", "been", "have", "has", "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "can", "this", "that", "these", "those", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them"])
        
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let word = String(text[tokenRange]).lowercased()
            if word.count > 2 && !stopWords.contains(word) && word.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil {
                frequency[word, default: 0] += 1
            }
            return true
        }
        
        return frequency
    }
    
    private func scoreSentence(_ sentence: String, wordFrequency: [String: Int], position: Int, totalSentences: Int) -> Double {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        
        var totalScore = 0.0
        var wordCount = 0
        
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { tokenRange, _ in
            let word = String(sentence[tokenRange]).lowercased()
            if let freq = wordFrequency[word] {
                totalScore += Double(freq)
                wordCount += 1
            }
            return true
        }
        
        let averageScore = wordCount > 0 ? totalScore / Double(wordCount) : 0
        
        // Boost score for sentences at the beginning (introduction) and end (conclusion)
        let positionBoost: Double
        let relativePosition = Double(position) / Double(totalSentences)
        if relativePosition < 0.2 || relativePosition > 0.8 {
            positionBoost = 1.2
        } else {
            positionBoost = 1.0
        }
        
        // Boost score for sentences of moderate length (not too short or too long)
        let lengthBoost: Double
        let sentenceLength = sentence.count
        if sentenceLength > 50 && sentenceLength < 200 {
            lengthBoost = 1.1
        } else {
            lengthBoost = 0.9
        }
        
        return averageScore * positionBoost * lengthBoost
    }
    
    private func formatShortSummary(_ sentences: [String]) -> String {
        // Use proper Markdown: heading, blank lines, and bullet list
        var out = "## Key Points\n\n"
        for sentence in sentences {
            out += "- \(sentence)\n"
        }
        // Ensure trailing newline
        if !out.hasSuffix("\n") { out.append("\n") }
        return out
    }
    
    private func formatSummary(_ keyPoints: [String]) -> String {
        // Proper Markdown with heading and a list, with blank lines
        var formatted = "## Summary\n\n"
        for point in keyPoints {
            formatted += "- \(point)\n"
        }
        if !formatted.hasSuffix("\n") { formatted.append("\n") }
        return formatted
    }
}
