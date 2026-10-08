//
//  ProjectSummary.swift
//  Pangolin
//

import Foundation

/// The "21 videos • 23 hours" line shown under a project's title and in its list row.
enum ProjectSummary {
    static func duration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "0 min" }

        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
        }
        return "\(max(minutes, 1)) min"
    }

    static func stats(videoCount: Int, duration totalDuration: TimeInterval) -> String {
        "\(videoCount) \(videoCount == 1 ? "video" : "videos") • \(duration(totalDuration))"
    }
}
