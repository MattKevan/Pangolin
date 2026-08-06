import os
import Foundation
import NaturalLanguage
import FoundationModels
import SwiftUI

extension SpeechTranscriptionService {
    // MARK: - Chunked summarization helpers

    func estimateTokens(for text: String) -> Int {
        let length = text.utf8.count
        return max(1, length / 4)
    }
    
    func splitTextIntoChunksByBudget(_ text: String, targetTokens: Int, hardLimit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        
        // Split by paragraph blocks
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { $0.joined(separator: "\n") }
        
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
            currentTokens = 0
        }
        
        for para in paragraphs {
            let paraTokens = estimateTokens(for: para)
            if paraTokens > targetTokens {
                // Further split by sentences
                let sentences = splitIntoSentences(para)
                var buffer = ""
                var bufferTokens = 0
                for sentence in sentences {
                    let tokens = estimateTokens(for: sentence)
                    if bufferTokens + tokens > targetTokens {
                        if !buffer.isEmpty {
                            chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                            buffer = ""
                            bufferTokens = 0
                        }
                    }
                    if tokens > hardLimit {
                        // Hard split long sentence
                        let mid = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
                        let s1 = String(sentence[..<mid])
                        let s2 = String(sentence[mid...])
                        for part in [s1, s2] {
                            let pt = estimateTokens(for: part)
                            if bufferTokens + pt > targetTokens {
                                if !buffer.isEmpty {
                                    chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                                    buffer = ""
                                    bufferTokens = 0
                                }
                            }
                            buffer += part + " "
                            bufferTokens += pt
                        }
                    } else {
                        buffer += sentence + " "
                        bufferTokens += tokens
                    }
                }
                if !buffer.isEmpty {
                    chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }
            
            if currentTokens + paraTokens > targetTokens {
                flush()
            }
            current += para + "\n\n"
            currentTokens += paraTokens
        }
        
        flush()
        
        // Safety pass: split any chunk above hardLimit
        var safe: [String] = []
        for chunk in chunks {
            if estimateTokens(for: chunk) > hardLimit {
                let mid = chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)
                safe.append(String(chunk[..<mid]))
                safe.append(String(chunk[mid...]))
            } else {
                safe.append(chunk)
            }
        }
        return safe
    }
    
    func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }
    
    func summarizeChunk(_ chunk: String, customPrompt: String?) async throws -> String {
        let instructionsText = summaryInstructions(from: customPrompt)
        let instructions = Instructions("""
        You are an expert summarizer. Follow these rules:
        - Output Markdown only (no plain text outside markdown, no code fences)
        - Use clear headings (##) and lists when useful
        - Keep content faithful and concise
        - Avoid repetition
        - Preserve important names, dates, figures

        Task:
        \(instructionsText)
        """)
        let prompt = """
        Summarize the following transcript chunk:

        \(chunk)
        """
        return try await respondWithFreshLanguageModelSession(
            prompt: prompt,
            instructions: instructions
        )
    }
    
    func reduceSummaries(_ summaries: [String], customPrompt: String?) async throws -> String {
        let instructionsText = summaryInstructions(from: customPrompt)
        let instructions = Instructions("""
        You are an expert at synthesizing multiple summaries into a cohesive, non-redundant final summary.
        - Output Markdown only (no plain text outside markdown, no code fences)
        - Use clear headings (##) and lists when useful
        - Remove duplicates and merge related points
        - Maintain logical flow and highlight key insights

        Final summary style:
        \(instructionsText)
        """)
        let joined = summaries.enumerated().map { "Chunk \($0 + 1):\n\($1)" }.joined(separator: "\n\n---\n\n")
        let prompt = """
        Combine the following chunk summaries into a single, coherent summary:

        \(joined)
        """
        return try await respondWithFreshLanguageModelSession(
            prompt: prompt,
            instructions: instructions
        )
    }

    func summaryInstructions(from customPrompt: String?) -> String {
        let trimmed = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Summarize the content clearly with headings and bullet points."
        }
        return trimmed
    }

    func respondWithFreshLanguageModelSession(
        prompt: String,
        instructions: Instructions,
        maxAttempts: Int = 3
    ) async throws -> String {
        var lastError: Error?

        for attempt in 1...max(1, maxAttempts) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt)
                return response.content
            } catch {
                lastError = error

                if attempt < maxAttempts && isLanguageModelInitializationReuseError(error) {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                throw error
            }
        }

        throw lastError ?? TranscriptionError.summarizationFailed("Language model request failed unexpectedly.")
    }

    func isLanguageModelInitializationReuseError(_ error: Error) -> Bool {
        let lowercasedDescription = error.localizedDescription.lowercased()
        let lowercasedDebugDescription = String(describing: error).lowercased()
        let combined = "\(lowercasedDescription) \(lowercasedDebugDescription)"

        return combined.contains("invalid reuse after initialization failure")
            || combined.contains("invalid reuse")
            || (combined.contains("reuse") && combined.contains("initialization failure"))
    }

    func isLanguageModelContextWindowExceededError(_ error: Error) -> Bool {
        let lowercasedDescription = error.localizedDescription.lowercased()
        let lowercasedDebugDescription = String(describing: error).lowercased()
        let combined = "\(lowercasedDescription) \(lowercasedDebugDescription)"

        return combined.contains("exceededcontextwindowsize")
            || combined.contains("context window size")
            || combined.contains("maximum allowed context size")
            || (combined.contains("provided") && combined.contains("tokens") && combined.contains("maximum"))
    }

    // MARK: - Main-thread UI helpers

    /// Atomically claims the single active flow. Returns false (and leaves state
    /// untouched) when another flow is already running.
    func claimFlow(_ kind: TranscriptionFlowKind) async -> Bool {
        await MainActor.run {
            guard TranscriptionFlowClaimPolicy.canClaim(activeFlow: activeFlow) else { return false }
            activeFlow = kind
            isTranscribing = true
            isSummarizing = kind == .summarization
            return true
        }
    }

    /// Releases the flow claim only if this kind still owns it, so a stale
    /// release can never clear a newer flow's state.
    func releaseFlow(_ kind: TranscriptionFlowKind) async {
        await MainActor.run {
            activeFlow = TranscriptionFlowClaimPolicy.release(activeFlow: activeFlow, for: kind)
            if activeFlow == nil {
                isTranscribing = false
                isSummarizing = false
            }
        }
    }

    func setProgress(_ value: Double) async {
        await MainActor.run {
            self.progress = value
        }
    }

    func setStatus(_ message: String) async {
        await MainActor.run {
            self.statusMessage = message
        }
    }

    func setErrorMessage(_ message: String?) async {
        await MainActor.run {
            self.errorMessage = message
        }
    }

    func userVisibleMessage(for error: Error) -> String {
        if isLanguageModelInitializationReuseError(error) {
            return "Apple Intelligence failed to initialize this request. Please try again."
        }

        if let localized = error as? LocalizedError {
            let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suggestion = localized.recoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !description.isEmpty, !suggestion.isEmpty, description != suggestion {
                return "\(description)\n\n\(suggestion)"
            }
            if !description.isEmpty {
                return description
            }
            if !suggestion.isEmpty {
                return suggestion
            }
        }

        let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "An unknown error occurred." : fallback
    }

    func getProgressOnMain() async -> Double {
        await MainActor.run { progress }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
