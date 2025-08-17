//
//  SubtitleMatcher.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Import/SubtitleMatcher.swift
import Foundation

class SubtitleMatcher {
    private let languagePatterns: [(pattern: String, code: String, name: String)] = [
        (".en.", "en", "English"),
        (".eng.", "en", "English"),
        ("_en.", "en", "English"),
        ("_eng.", "en", "English"),
        ("[English]", "en", "English"),
        (".fr.", "fr", "French"),
        (".fra.", "fr", "French"),
        ("_fr.", "fr", "French"),
        ("[French]", "fr", "French"),
        (".es.", "es", "Spanish"),
        (".spa.", "es", "Spanish"),
        ("_es.", "es", "Spanish"),
        ("[Spanish]", "es", "Spanish"),
        (".de.", "de", "German"),
        (".deu.", "de", "German"),
        ("_de.", "de", "German"),
        ("[German]", "de", "German"),
        (".it.", "it", "Italian"),
        (".ita.", "it", "Italian"),
        ("_it.", "it", "Italian"),
        ("[Italian]", "it", "Italian"),
        (".ja.", "ja", "Japanese"),
        (".jpn.", "ja", "Japanese"),
        ("_ja.", "ja", "Japanese"),
        ("[Japanese]", "ja", "Japanese"),
        (".zh.", "zh", "Chinese"),
        (".chi.", "zh", "Chinese"),
        ("_zh.", "zh", "Chinese"),
        ("[Chinese]", "zh", "Chinese"),
    ]
    
    func findMatchingSubtitles(for videoURL: URL, in directory: URL) -> [URL] {
        let videoName = videoURL.deletingPathExtension().lastPathComponent
        var subtitles: [URL] = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            
            for file in files {
                if isSubtitleFile(file) {
                    let subtitleName = file.deletingPathExtension().lastPathComponent
                    
                    // Check various matching patterns
                    if matchesVideo(subtitleName: subtitleName, videoName: videoName) {
                        subtitles.append(file)
                    }
                }
            }
        } catch {
            print("Error finding subtitles: \(error)")
        }
        
        return subtitles
    }
    
    func detectLanguage(from filename: String) -> (code: String?, name: String?) {
        let lowercased = filename.lowercased()
        
        for (pattern, code, name) in languagePatterns {
            if lowercased.contains(pattern.lowercased()) {
                return (code, name)
            }
        }
        
        // Try to extract ISO 639-1 codes (2 letters)
        let components = filename.components(separatedBy: CharacterSet(charactersIn: "._-[]"))
        for component in components {
            if component.count == 2 {
                if let languageName = Locale.current.localizedString(forLanguageCode: component) {
                    return (component, languageName)
                }
            }
        }
        
        return (nil, nil)
    }
    
    private func isSubtitleFile(_ url: URL) -> Bool {
        let subtitleExtensions = ["srt", "vtt", "ssa", "ass", "sub"]
        return subtitleExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func matchesVideo(subtitleName: String, videoName: String) -> Bool {
        // Exact match
        if subtitleName == videoName {
            return true
        }
        
        // Prefix match (allows for language codes)
        if subtitleName.hasPrefix(videoName) {
            return true
        }
        
        // Fuzzy matching with similarity threshold
        let similarity = calculateSimilarity(subtitleName, videoName)
        if similarity > 0.8 {
            return true
        }
        
        return false
    }
    
    private func calculateSimilarity(_ str1: String, _ str2: String) -> Double {
        // Simple Jaccard similarity
        let set1 = Set(str1.lowercased())
        let set2 = Set(str2.lowercased())
        
        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count
        
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}