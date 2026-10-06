//
//  ProjectVideoGrid.swift
//  Pangolin
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

#if os(iOS)
struct IOSProjectVideoCollectionView: UIViewRepresentable {
    let sections: [ProjectSectionSnapshot]
    @Binding var selection: Set<UUID>
    let isEditing: Bool
    let isCompact: Bool
    /// Scrollable header (the album hero) rendered as the first section's
    /// supplementary header so it scrolls with the collection.
    let header: AnyView?
    /// Scrollable footer rendered as the last section's supplementary footer.
    let footer: AnyView?
    let onEditingChanged: (Bool) -> Void
    let onOpen: (Video) -> Void
    let onEdit: (Video) -> Void
    let onDelete: (Video) -> Void
    let onToggleFavorite: (Video) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = ProjectVideoGridLayout.spacing
        layout.minimumLineSpacing = ProjectVideoGridLayout.spacing
        layout.sectionInset = UIEdgeInsets(top: 4, left: 24, bottom: 28, right: 24)
        layout.headerReferenceSize = CGSize(width: 1, height: 36)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsSelectionDuringEditing = true
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.register(
            IOSProjectVideoCollectionCell.self,
            forCellWithReuseIdentifier: IOSProjectVideoCollectionCell.reuseIdentifier
        )
        collectionView.register(
            IOSProjectVideoSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: IOSProjectVideoSectionHeader.reuseIdentifier
        )
        collectionView.register(
            IOSProjectVideoHeroHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: IOSProjectVideoHeroHeader.reuseIdentifier
        )
        collectionView.register(
            IOSProjectVideoFooter.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: IOSProjectVideoFooter.reuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        context.coordinator.collectionView = collectionView
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.updateParent(self)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: IOSProjectVideoCollectionView
        weak var collectionView: UICollectionView?
        private var isSynchronizingSelection = false
        private var contentSignature = [String]()
        private var presentationSignature = [String]()

        init(_ parent: IOSProjectVideoCollectionView) {
            self.parent = parent
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int {
            parent.sections.count
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.sections[section].videos.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: IOSProjectVideoCollectionCell.reuseIdentifier,
                for: indexPath
            ) as! IOSProjectVideoCollectionCell
            cell.configure(video: video(at: indexPath))
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            if kind == UICollectionView.elementKindSectionFooter {
                let footer = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: IOSProjectVideoFooter.reuseIdentifier,
                    for: indexPath
                ) as! IOSProjectVideoFooter
                footer.configure(rootView: parent.footer)
                return footer
            }
            if kind == UICollectionView.elementKindSectionHeader, indexPath.section == 0, parent.header != nil {
                let hero = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: IOSProjectVideoHeroHeader.reuseIdentifier,
                    for: indexPath
                ) as! IOSProjectVideoHeroHeader
                hero.configure(rootView: parent.header)
                return hero
            }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: IOSProjectVideoSectionHeader.reuseIdentifier,
                for: indexPath
            ) as! IOSProjectVideoSectionHeader
            header.title = parent.sections[indexPath.section].title
            return header
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            let insets: CGFloat = 48
            let availableWidth = max(0, collectionView.bounds.width - insets)
            let columnCount = ProjectVideoGridLayout.columnCount(
                availableWidth: availableWidth,
                isCompact: parent.isCompact
            )
            let totalSpacing = CGFloat(max(0, columnCount - 1)) * ProjectVideoGridLayout.spacing
            let width = max(1, floor((availableWidth - totalSpacing) / CGFloat(columnCount)))
            return CGSize(width: width, height: width * 9 / 16 + 76)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> CGSize {
            if section == 0, parent.header != nil {
                return heroHeaderSize(for: collectionView.bounds.width)
            }
            return CGSize(width: 1, height: 36)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            referenceSizeForFooterInSection section: Int
        ) -> CGSize {
            guard section == parent.sections.count - 1, parent.footer != nil else { return .zero }
            return footerSize(for: collectionView.bounds.width)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            let video = video(at: indexPath)
            guard video.id != nil else {
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }

            if collectionView.isEditing {
                publishSelection()
            } else {
                parent.onOpen(video)
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard collectionView.isEditing else { return }
            publishSelection()
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) -> Bool {
            video(at: indexPath).id != nil
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) {
            collectionView.isEditing = true
            collectionView.allowsMultipleSelection = true
            parent.onEditingChanged(true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            let video = video(at: indexPath)
            guard video.id != nil else { return nil }

            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let favorite = UIAction(
                    title: video.isFavorite ? "Remove from favourites" : "Add to favourites",
                    image: UIImage(systemName: video.isFavorite ? "heart.slash" : "heart")
                ) { [weak self] _ in
                    self?.parent.onToggleFavorite(video)
                }
                let edit = UIAction(
                    title: "Edit Video",
                    image: UIImage(systemName: "pencil")
                ) { [weak self] _ in
                    self?.parent.onEdit(video)
                }
                let delete = UIAction(
                    title: "Delete Video",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.parent.onDelete(video)
                }
                return UIMenu(children: [favorite, edit, delete])
            }
        }

        func updateParent(_ parent: IOSProjectVideoCollectionView) {
            self.parent = parent
            guard let collectionView else { return }

            collectionView.isEditing = parent.isEditing
            collectionView.allowsMultipleSelection = parent.isEditing

            let nextSignature = parent.sections.map { section in
                let videos = section.videos
                    .map { $0.objectID.uriRepresentation().absoluteString }
                    .joined(separator: ",")
                return "\(section.title)|\(videos)"
            }
            let nextPresentationSignature = parent.sections.flatMap(\.videos).map(cardPresentationSignature)

            if contentSignature != nextSignature {
                contentSignature = nextSignature
                presentationSignature = nextPresentationSignature
                heroSizedWidth = 0
                footerSizedWidth = 0
                isSynchronizingSelection = true
                collectionView.reloadData()
                isSynchronizingSelection = false
            } else if presentationSignature != nextPresentationSignature {
                presentationSignature = nextPresentationSignature
                refreshVisibleCells()
            }

            synchronizeSelection()
        }

        private func synchronizeSelection() {
            guard let collectionView else { return }
            isSynchronizingSelection = true

            let desired = parent.isEditing ? selectedIndexPaths : []
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] where !desired.contains(indexPath) {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
            for indexPath in desired where collectionView.indexPathsForSelectedItems?.contains(indexPath) != true {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            }

            isSynchronizingSelection = false
        }

        private func refreshVisibleCells() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? IOSProjectVideoCollectionCell else {
                    continue
                }
                cell.configure(video: video(at: indexPath))
            }
        }

        private func publishSelection() {
            guard !isSynchronizingSelection, let collectionView else { return }
            parent.selection = Set(
                (collectionView.indexPathsForSelectedItems ?? [])
                    .compactMap { video(at: $0).id }
            )
        }

        // MARK: - Hero / footer sizing (measured via hosting controllers, cached by width)

        private var heroSizingController: UIHostingController<AnyView>?
        private var heroSizedWidth: CGFloat = 0
        private var heroSizedHeight: CGFloat = 0

        private func heroHeaderSize(for width: CGFloat) -> CGSize {
            guard let hero = parent.header else { return CGSize(width: 1, height: 36) }
            let controller: UIHostingController<AnyView>
            if let heroSizingController {
                controller = heroSizingController
                controller.rootView = hero
            } else {
                let created = UIHostingController(rootView: hero)
                created.view.backgroundColor = .clear
                controller = created
                heroSizingController = created
            }
            if heroSizedWidth != width {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 0)
                let size = controller.view.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
                heroSizedWidth = width
                heroSizedHeight = size.height
            }
            return CGSize(width: width, height: heroSizedHeight)
        }

        private var footerSizingController: UIHostingController<AnyView>?
        private var footerSizedWidth: CGFloat = 0
        private var footerSizedHeight: CGFloat = 0

        private func footerSize(for width: CGFloat) -> CGSize {
            guard let footer = parent.footer else { return .zero }
            let controller: UIHostingController<AnyView>
            if let footerSizingController {
                controller = footerSizingController
                controller.rootView = footer
            } else {
                let created = UIHostingController(rootView: footer)
                created.view.backgroundColor = .clear
                controller = created
                footerSizingController = created
            }
            if footerSizedWidth != width {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 0)
                let size = controller.view.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
                footerSizedWidth = width
                footerSizedHeight = size.height
            }
            return CGSize(width: width, height: footerSizedHeight)
        }

        private var selectedIndexPaths: Set<IndexPath> {
            Set(parent.sections.enumerated().flatMap { section, snapshot in
                snapshot.videos.enumerated().compactMap { item, video in
                    video.id.map(parent.selection.contains) == true
                        ? IndexPath(item: item, section: section)
                        : nil
                }
            })
        }

        private func video(at indexPath: IndexPath) -> Video {
            parent.sections[indexPath.section].videos[indexPath.item]
        }

        private func cardPresentationSignature(for video: Video) -> String {
            [
                video.objectID.uriRepresentation().absoluteString,
                video.title ?? "",
                video.fileName ?? "",
                String(video.duration),
                String(video.playbackPosition),
                String(video.isFavorite),
                video.fileAvailabilityState ?? "",
                video.cloudRelativePath ?? "",
                String(video.thumbnailGenerationVersion)
            ].joined(separator: "|")
        }
    }
}

private final class IOSProjectVideoCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "ProjectVideoCell"
    private var video: Video?

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            render()
        }
    }

    func configure(video: Video) {
        self.video = video
        render()
    }

    private func render() {
        guard let video else { return }
        let card = ProjectVideoCardContent(video: video, isSelected: isSelected)
        contentConfiguration = UIHostingConfiguration {
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.accessibilityLabel)
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityAddTraits(.isButton)
        }
        .margins(.all, 0)
    }
}

private final class IOSProjectVideoSectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "ProjectVideoSectionHeader"
    private let label = UILabel()

    var title: String = "" {
        didSet {
            label.text = title
            accessibilityLabel = title
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { nil }
}

/// Hosts the album hero so it scrolls with the collection (first section header).
private final class IOSProjectVideoHeroHeader: UICollectionReusableView {
    static let reuseIdentifier = "ProjectVideoHeroHeader"
    private var hostingController: UIHostingController<AnyView>?

    func configure(rootView: AnyView?) {
        guard let rootView else { return }
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = UIHostingController(rootView: rootView)
            controller.view.backgroundColor = .clear
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingController = controller
        }
    }
}

/// Hosts the album footer so it scrolls with the collection (last section footer).
private final class IOSProjectVideoFooter: UICollectionReusableView {
    static let reuseIdentifier = "ProjectVideoFooter"
    private var hostingController: UIHostingController<AnyView>?

    func configure(rootView: AnyView?) {
        guard let rootView else { return }
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = UIHostingController(rootView: rootView)
            controller.view.backgroundColor = .clear
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingController = controller
        }
    }
}
#endif

/// Shared visual treatment for project video cards. Platform-specific containers own selection and activation.
struct ProjectVideoCardContent: View {
    let video: Video
    let isSelected: Bool

    @State private var isHovering = false

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
            .shadow(
                color: .black.opacity(isHovering ? 0.32 : 0.18),
                radius: isHovering ? 14 : 6,
                y: isHovering ? 6 : 2
            )
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
            #if os(macOS)
            // Selection border + hover zoom on the thumbnail only, matching the
            // projects grid card rules.
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            #endif

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
        .onHover { hovering in
            isHovering = hovering
        }
        .overlay(alignment: .topTrailing) {
            #if os(iOS)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor, .background)
                    .font(.title3)
                    .padding(6)
            }
            #endif
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
