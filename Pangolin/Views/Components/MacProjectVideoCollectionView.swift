import SwiftUI

#if os(macOS)
import AppKit

enum MacProjectVideoCollectionPolicy {
    static func reconciledSelection(_ selection: Set<UUID>, visibleIDs: Set<UUID>) -> Set<UUID> {
        selection.intersection(visibleIDs)
    }

    static func returnActivationID(selection: Set<UUID>, visibleIDs: Set<UUID>) -> UUID? {
        ProjectVideoSelectionPolicy.activationID(selection: selection, visibleIDs: visibleIDs)
    }

    static func doubleClickActivationID(
        clickedID: UUID,
        selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> UUID? {
        guard selection == [clickedID], visibleIDs.contains(clickedID) else { return nil }
        return clickedID
    }

    static func contextSelection(
        clickedID: UUID,
        selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> Set<UUID> {
        let visibleSelection = selection.intersection(visibleIDs)
        return visibleSelection.contains(clickedID) ? visibleSelection : [clickedID]
    }

    static func contextOpenID(
        clickedID: UUID,
        selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> UUID? {
        returnActivationID(
            selection: contextSelection(clickedID: clickedID, selection: selection, visibleIDs: visibleIDs),
            visibleIDs: visibleIDs
        )
    }
}

enum MacProjectVideoCollectionLayout {
    static let horizontalInsets: CGFloat = 48

    static func itemSize(containerWidth: CGFloat) -> NSSize {
        let minimumCardWidth = ProjectVideoGridLayout.minimumRegularCardWidth
        let minimumContentWidth = (minimumCardWidth * 2) + ProjectVideoGridLayout.spacing
        let available = max(minimumContentWidth, containerWidth - horizontalInsets)
        let columns = max(2, Int((available + ProjectVideoGridLayout.spacing) / (minimumCardWidth + ProjectVideoGridLayout.spacing)))
        let width = floor((available - CGFloat(columns - 1) * ProjectVideoGridLayout.spacing) / CGFloat(columns))
        return NSSize(width: width, height: width * 0.82 + 96)
    }
}

struct MacProjectVideoCollectionView: NSViewRepresentable {
    let sections: [ProjectSectionSnapshot]
    @Binding var selection: Set<UUID>
    let onOpen: (Video) -> Void
    let onEdit: (Video) -> Void
    let onDelete: (Video) -> Void
    let onToggleFavorite: (Video) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = ProjectVideoGridLayout.spacing
        layout.minimumLineSpacing = ProjectVideoGridLayout.spacing
        layout.sectionInset = NSEdgeInsets(top: 4, left: 24, bottom: 28, right: 24)
        layout.headerReferenceSize = NSSize(width: 1, height: 36)

        let collectionView = ActivatingCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(MacProjectVideoCollectionItem.self, forItemWithIdentifier: .item)
        collectionView.register(MacProjectVideoSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: .header)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activateSelectionFromReturn() }
        collectionView.onDoubleClick = { [weak coordinator = context.coordinator] indexPath in coordinator?.activateDoubleClick(at: indexPath) }

        let scrollView = ProjectVideoCollectionScrollView(collectionView: collectionView)
        context.coordinator.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.updateParent(self)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var parent: MacProjectVideoCollectionView
        weak var collectionView: NSCollectionView?
        private var isSynchronizingSelection = false
        private var contentSignature = [String]()
        private var presentationSignature = [String]()

        init(_ parent: MacProjectVideoCollectionView) { self.parent = parent }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { parent.sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.sections[section].videos.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .item, for: indexPath) as! MacProjectVideoCollectionItem
            let video = parent.sections[indexPath.section].videos[indexPath.item]
            item.configure(
                video: video,
                onOpen: parent.onOpen,
                onSelect: { [weak self] in self?.toggleAccessibilitySelection(for: video) }
            )
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .header, for: indexPath) as! MacProjectVideoSectionHeader
            header.title = parent.sections[indexPath.section].title
            return header
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { publishSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { publishSelection() }

        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            indexPaths.filter { video(at: $0).id != nil }
        }

        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            MacProjectVideoCollectionLayout.itemSize(containerWidth: collectionView.bounds.width)
        }

        func collectionView(_ collectionView: NSCollectionView, menuForItemsAt indexPaths: Set<IndexPath>) -> NSMenu? {
            guard let clickedID = indexPaths.compactMap({ video(at: $0).id }).first else { return nil }
            parent.selection = MacProjectVideoCollectionPolicy.contextSelection(
                clickedID: clickedID,
                selection: nativeSelection,
                visibleIDs: visibleIDs
            )
            synchronizeSelection()
            let menu = NSMenu()
            if selectedVideo == nil {
                let summary = menu.addItem(withTitle: "\(parent.selection.count) Videos Selected", action: nil, keyEquivalent: "")
                summary.isEnabled = false
            } else if let selectedVideo {
                menu.addItem(withTitle: "Open Video", action: #selector(openFromMenu), keyEquivalent: "")
                menu.addItem(withTitle: selectedVideo.isFavorite ? "Remove from favourites" : "Add to favourites", action: #selector(toggleFavoriteFromMenu), keyEquivalent: "")
                menu.addItem(withTitle: "Edit Video", action: #selector(editFromMenu), keyEquivalent: "")
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "Delete Video", action: #selector(deleteFromMenu), keyEquivalent: "")
            }
            menu.items.forEach { $0.target = self }
            return menu
        }

        @objc private func openFromMenu() { activateSelectionFromReturn() }
        @objc private func toggleFavoriteFromMenu() { if let video = selectedVideo { parent.onToggleFavorite(video) } }
        @objc private func editFromMenu() { if let video = selectedVideo { parent.onEdit(video) } }
        @objc private func deleteFromMenu() { if let video = selectedVideo { parent.onDelete(video) } }

        func activateSelectionFromReturn() {
            guard let id = MacProjectVideoCollectionPolicy.returnActivationID(
                selection: nativeSelection,
                visibleIDs: visibleIDs
            ), let video = video(id: id) else { return }
            parent.onOpen(video)
        }

        func activateDoubleClick(at indexPath: IndexPath) {
            guard indexPath.section < parent.sections.count, indexPath.item < parent.sections[indexPath.section].videos.count else { return }
            let video = self.video(at: indexPath)
            guard let id = video.id,
                  MacProjectVideoCollectionPolicy.doubleClickActivationID(
                    clickedID: id,
                    selection: nativeSelection,
                    visibleIDs: visibleIDs
                  ) != nil else { return }
            parent.onOpen(video)
        }

        func updateParent(_ parent: MacProjectVideoCollectionView) {
            self.parent = parent
            guard let collectionView else { return }

            let nextSignature = parent.sections.map { section in
                let videoSignature = section.videos
                    .map { $0.objectID.uriRepresentation().absoluteString }
                    .joined(separator: ",")
                return "\(section.title)|\(videoSignature)"
            }
            let nextPresentationSignature = parent.sections.flatMap(\.videos).map(cardPresentationSignature)

            if contentSignature != nextSignature {
                contentSignature = nextSignature
                presentationSignature = nextPresentationSignature
                isSynchronizingSelection = true
                collectionView.reloadData()
                isSynchronizingSelection = false
            } else if presentationSignature != nextPresentationSignature {
                presentationSignature = nextPresentationSignature
                refreshVisibleItems()
            }

            synchronizeSelection()
        }

        private func synchronizeSelection() {
            guard let collectionView else { return }
            isSynchronizingSelection = true
            let desiredSelection = selectedIndexPaths
            collectionView.deselectItems(at: collectionView.selectionIndexPaths.subtracting(desiredSelection))
            collectionView.selectItems(at: desiredSelection, scrollPosition: [])
            isSynchronizingSelection = false
        }

        private func refreshVisibleItems() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let item = collectionView.item(at: indexPath) as? MacProjectVideoCollectionItem else {
                    continue
                }
                let video = video(at: indexPath)
                item.configure(
                    video: video,
                    onOpen: parent.onOpen,
                    onSelect: { [weak self] in self?.toggleAccessibilitySelection(for: video) }
                )
            }
        }

        private func publishSelection() {
            guard !isSynchronizingSelection, let collectionView else { return }
            parent.selection = MacProjectVideoCollectionPolicy.reconciledSelection(
                Set(collectionView.selectionIndexPaths.compactMap { video(at: $0).id }),
                visibleIDs: visibleIDs
            )
        }

        private func toggleAccessibilitySelection(for video: Video) {
            guard let id = video.id else { return }
            if parent.selection.contains(id) {
                parent.selection.remove(id)
            } else {
                parent.selection.insert(id)
            }
        }

        private var visibleIDs: Set<UUID> { Set(parent.sections.flatMap(\.videos).compactMap(\.id)) }
        private var nativeSelection: Set<UUID> {
            guard let collectionView else { return [] }
            return Set(collectionView.selectionIndexPaths.compactMap { video(at: $0).id })
        }
        private var selectedIndexPaths: Set<IndexPath> {
            Set(parent.sections.enumerated().flatMap { section, snapshot in
                snapshot.videos.enumerated().compactMap { item, video in
                    video.id.map(parent.selection.contains) == true ? IndexPath(item: item, section: section) : nil
                }
            })
        }
        private var selectedVideo: Video? {
            guard let id = MacProjectVideoCollectionPolicy.returnActivationID(
                selection: nativeSelection,
                visibleIDs: visibleIDs
            ) else { return nil }
            return video(id: id)
        }
        private func video(at indexPath: IndexPath) -> Video { parent.sections[indexPath.section].videos[indexPath.item] }
        private func video(id: UUID) -> Video? { parent.sections.flatMap(\.videos).first { $0.id == id } }
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

private final class ActivatingCollectionView: NSCollectionView {
    var onReturn: (() -> Void)?
    var onDoubleClick: ((IndexPath) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath { onDoubleClick?(indexPath) }
    }
}

private final class ProjectVideoCollectionScrollView: NSScrollView {
    private let collectionView: NSCollectionView

    init(collectionView: NSCollectionView) {
        self.collectionView = collectionView
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        documentView = collectionView
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = contentView.bounds.size
        guard size.width > 0 else { return }

        if collectionView.frame.width != size.width {
            collectionView.frame = NSRect(origin: .zero, size: size)
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }
}

private final class MacProjectVideoCollectionItem: NSCollectionViewItem {
    private var video: Video?
    private var onOpen: ((Video) -> Void)?
    private var onSelect: (() -> Void)?

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            render()
        }
    }

    func configure(
        video: Video,
        onOpen: @escaping (Video) -> Void,
        onSelect: @escaping () -> Void
    ) {
        self.video = video
        self.onOpen = onOpen
        self.onSelect = onSelect
        render()
    }

    private func render() {
        guard let video, let onOpen, let onSelect else { return }
        let card = ProjectVideoCardContent(
            video: video,
            isSelected: isSelected
        )
        let accessibleCard: AnyView
        if video.id != nil {
            accessibleCard = AnyView(
                card
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(card.accessibilityLabel)
                    .accessibilityValue(isSelected ? "Selected" : "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onOpen(video) }
                    .accessibilityAction(named: Text("Open")) { onOpen(video) }
                    .accessibilityAction(named: Text("Select video")) { onSelect() }
            )
        } else {
            accessibleCard = AnyView(
                card
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(card.accessibilityLabel)
                    .accessibilityAddTraits(.isStaticText)
            )
        }

        view = NSHostingView(rootView: accessibleCard)
        view.setAccessibilityIdentifier(video.id.map { "project-video-card-\($0.uuidString)" })
    }
}

private final class MacProjectVideoSectionHeader: NSView {
    private let label = NSTextField(labelWithString: "")
    var title: String {
        didSet {
            label.stringValue = title
            setAccessibilityLabel(title)
        }
    }

    override init(frame frameRect: NSRect) {
        title = ""
        super.init(frame: frameRect)
        label.font = .preferredFont(forTextStyle: .headline)
        label.setAccessibilityElement(false)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 24, dy: 6) }
}

private extension NSUserInterfaceItemIdentifier {
    static let item = NSUserInterfaceItemIdentifier("MacProjectVideoCollectionItem")
    static let header = NSUserInterfaceItemIdentifier("MacProjectVideoCollectionHeader")
}
#endif
