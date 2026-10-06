//
//  Video+Presentation.swift
//  Pangolin
//

import SwiftUI

/// How a video is described in lists: its title, where its file is, and whether it has been watched.
extension Video {
    /// The title to show, falling back to the file name when no title was set.
    var listTitle: String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (fileName ?? "Untitled Video") : title
    }

    var availability: VideoFileStatus {
        if let rawState = fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            return status
        }
        return cloudRelativePath?.isEmpty == false ? .cloudOnly : .local
    }

    /// A badge for files that are not on this device, or nil when the video is local.
    var cloudBadge: (systemImage: String, label: String, color: Color)? {
        switch availability {
        case .cloudOnly: ("icloud", "Available in iCloud", .blue)
        case .downloading: ("icloud.and.arrow.down", "Downloading from iCloud", .blue)
        case .missing: ("exclamationmark.icloud", "File not found", .red)
        case .error: ("questionmark.diamond", "File unavailable", .gray)
        case .local: nil
        }
    }

    var availabilityLabel: String {
        switch availability {
        case .local: "On device"
        case .cloudOnly: "Available in iCloud"
        case .downloading: "Downloading from iCloud"
        case .missing: "File not found"
        case .error: "File unavailable"
        }
    }

    /// Hollow when unwatched, half filled when in progress, filled when watched.
    var watchStatusSymbol: String {
        switch watchStatus {
        case .unwatched: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .watched: "circle.fill"
        }
    }
}
