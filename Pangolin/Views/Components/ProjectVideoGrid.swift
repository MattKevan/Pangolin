//
//  ProjectVideoGrid.swift
//  Pangolin
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

struct ProjectVideoGrid: View {
    let sections: [ProjectSectionSnapshot]
    let searchQuery: String
    let availableWidth: CGFloat
    let isCompact: Bool
    let selection: Set<UUID>
    let isSelecting: Bool
    let onInteraction: (ProjectVideoTouchInteraction) -> Void
    let onEdit: (Video) -> Void
    let onDelete: (Video) -> Void
    let onToggleFavorite: (Video) -> Void

    private var columns: [GridItem] {
        if isCompact {
            return Array(
                repeating: GridItem(.flexible(), spacing: ProjectVideoGridLayout.spacing),
                count: 2
            )
        }

        return ProjectVideoGridLayout.regularColumns(availableWidth: availableWidth)
    }

    var body: some View {
        if sections.isEmpty {
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No videos in this project",
                    systemImage: "video.slash",
                    description: Text("Import videos or add sections to populate the project.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ContentUnavailableView.search(text: searchQuery)
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        ProjectSectionHeader(title: section.title)
                            .accessibilityAddTraits(.isHeader)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: ProjectVideoGridLayout.spacing) {
                            ForEach(section.videos, id: \.objectID) { video in
                                ProjectVideoGridCard(
                                    video: video,
                                    isSelected: video.id.map(selection.contains) ?? false,
                                    selection: selection,
                                    isSelecting: isSelecting,
                                    isInteractive: video.id != nil,
                                    interaction: onInteraction,
                                    onToggleFavorite: { onToggleFavorite(video) },
                                    onEdit: { onEdit(video) },
                                    onDelete: { onDelete(video) }
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectVideoGridCard: View {
    let video: Video
    let isSelected: Bool
    let selection: Set<UUID>
    let isSelecting: Bool
    let isInteractive: Bool
    let interaction: (ProjectVideoTouchInteraction) -> Void
    let onToggleFavorite: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if isInteractive {
            interactiveCard
        } else {
            staticCard
        }
    }

    private var interactiveCard: some View {
        interactiveCardContent
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isSelected ? "Selected" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { performTap() }
            .accessibilityAction(named: Text("Open")) { performOpen() }
            .accessibilityAction(named: Text("Select video")) { performLongPress() }
            .accessibilityAction(named: Text(video.isFavorite ? "Remove from favourites" : "Add to favourites")) { onToggleFavorite() }
            .accessibilityAction(named: Text("Edit Video")) { onEdit() }
            .accessibilityAction(named: Text("Delete Video")) { onDelete() }
    }

    @ViewBuilder
    private var interactiveCardContent: some View {
        #if os(macOS)
        cardContent
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button(video.isFavorite ? "Remove from favourites" : "Add to favourites", systemImage: video.isFavorite ? "heart.slash" : "heart") {
                    onToggleFavorite()
                }
                Button("Edit Video") { onEdit() }
                Button("Delete Video", role: .destructive) { onDelete() }
            }
            .gesture(macInteractionGesture)
        #else
        if isSelecting {
            cardContent
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    Button(video.isFavorite ? "Remove from favourites" : "Add to favourites", systemImage: video.isFavorite ? "heart.slash" : "heart") {
                        onToggleFavorite()
                    }
                    Button("Edit Video") { onEdit() }
                    Button("Delete Video", role: .destructive) { onDelete() }
                }
                .gesture(TapGesture().onEnded(performTap))
        } else {
            cardContent
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .gesture(interactionGesture)
        }
        #endif
    }

    private var staticCard: some View {
        cardContent
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(0.55)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isStaticText)
    }

    private var cardContent: some View {
        ProjectVideoCardContent(
            video: video,
            isSelected: isSelected
        )
    }

    private var interactionGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in performLongPress() }
            .exclusively(before: TapGesture().onEnded(performTap))
    }

    #if os(macOS)
    private var macInteractionGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded(performMacOpen)
            .exclusively(before: TapGesture().onEnded(performMacClick))
    }

    private func performMacClick() {
        guard isInteractive, let id = video.id else { return }
        let modifiers = NSEvent.modifierFlags
        interaction(
            .macOSSelection(
                id,
                extendingSelection: modifiers.contains(.command),
                rangeSelecting: modifiers.contains(.shift)
            )
        )
    }

    private func performMacOpen() {
        guard isInteractive, let id = video.id else { return }
        interaction(.macOSOpen(id))
    }
    #endif

    private var resolvedTitle: String {
        let title = video.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (video.fileName ?? "Untitled Video") : title
    }

    @ViewBuilder
    private var watchStatus: some View {
        switch video.watchStatus {
        case .unwatched:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .inProgress:
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .watched:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        ProjectVideoCardContent(
            video: video,
            isSelected: isSelected
        ).accessibilityLabel
    }

    private func performTap() {
        guard isInteractive, let id = video.id else { return }
        interaction(ProjectVideoTouchInteractionPolicy.tap(
            id,
            selection: selection,
            isSelecting: isSelecting
        ))
    }

    private func performLongPress() {
        guard isInteractive, let id = video.id else { return }
        interaction(ProjectVideoTouchInteractionPolicy.longPress(id, selection: selection))
    }

    private func performOpen() {
        guard isInteractive, let id = video.id else { return }
        interaction(.open(id))
    }
}

/// Shared visual treatment for project video cards. Platform-specific containers own selection and activation.
struct ProjectVideoCardContent: View {
    let video: Video
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SyncedThumbnailImage(video: video, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 6))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .overlay(alignment: .bottomTrailing) {
                Text(video.formattedDuration)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(6)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                if let cloudStatusPresentation {
                    Image(systemName: cloudStatusPresentation.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(cloudStatusPresentation.color, in: Circle())
                        .accessibilityHidden(true)
                        .padding(6)
                }
            }

            Text(resolvedTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

            HStack(spacing: 6) {
                Image(systemName: watchStatusImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(video.watchStatus.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(video.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(availabilityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor, .background)
                    .font(.title3)
                    .padding(6)
            }
        }
    }

    var accessibilityLabel: String {
        "\(resolvedTitle), \(video.formattedDuration), \(video.watchStatus.displayName), \(availabilityLabel)"
    }

    private var resolvedTitle: String {
        let title = video.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (video.fileName ?? "Untitled Video") : title
    }

    private var watchStatusImage: String {
        switch video.watchStatus {
        case .unwatched: "circle"
        case .inProgress: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .watched: "checkmark.circle.fill"
        }
    }

    private var fileStatus: VideoFileStatus {
        if let rawState = video.fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            return status
        }
        return video.cloudRelativePath?.isEmpty == false ? .cloudOnly : .local
    }

    private var cloudStatusPresentation: (systemImage: String, label: String, color: Color)? {
        switch fileStatus {
        case .cloudOnly: ("icloud", "Available in iCloud", .blue)
        case .downloading: ("icloud.and.arrow.down", "Downloading from iCloud", .blue)
        case .missing: ("exclamationmark.icloud", "File not found", .red)
        case .error: ("questionmark.diamond", "File unavailable", .gray)
        case .local: nil
        }
    }

    private var availabilityLabel: String {
        switch fileStatus {
        case .local: "On device"
        case .cloudOnly: "Available in iCloud"
        case .downloading: "Downloading from iCloud"
        case .missing: "File not found"
        case .error: "File unavailable"
        }
    }
}
