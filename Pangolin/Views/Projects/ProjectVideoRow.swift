//
//  ProjectVideoRow.swift
//  Pangolin
//

import SwiftUI

/// One video in a project: its number, watch status, title, favourite, duration and menu.
struct ProjectVideoRow: View {
    @ObservedObject var video: Video
    let number: Int
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(number, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
                .accessibilityHidden(true)

            Image(systemName: video.watchStatusSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(video.watchStatus.displayName)

            Text(video.listTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let badge = video.cloudBadge {
                Image(systemName: badge.systemImage)
                    .font(.caption)
                    .foregroundStyle(badge.color)
                    .accessibilityLabel(badge.label)
            }

            Button(action: onToggleFavorite) {
                Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(video.isFavorite ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(video.isFavorite ? "Remove from favourites" : "Add to favourites")

            Text(video.formattedDuration)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(video.listTitle)")
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open Video", action: onOpen)
        Button(
            video.isFavorite ? "Remove from Favourites" : "Add to Favourites",
            systemImage: video.isFavorite ? "heart.slash" : "heart",
            action: onToggleFavorite
        )
        Button("Edit Video", action: onEdit)
        Divider()
        Button("Delete Video", role: .destructive, action: onDelete)
    }
}
