//
//  URL+Extensions.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

// Extensions/URL+Extensions.swift

import Foundation

extension URL {
    var isVideo: Bool {
        let videoExtensions = VideoFormat.supportedExtensions
        return videoExtensions.contains(self.pathExtension.lowercased())
    }
    
    var isSubtitle: Bool {
        let subtitleExtensions = ["srt", "vtt", "ssa", "ass", "sub"]
        return subtitleExtensions.contains(self.pathExtension.lowercased())
    }
    
    var parentDirectory: URL {
        return self.deletingLastPathComponent()
    }
}
