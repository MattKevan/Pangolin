#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoFileExportDescriptor: Identifiable {
    let id: UUID
    let fileName: String
    let fileTypeIdentifier: String

    init(id: UUID, fileName: String, fileTypeIdentifier: String) {
        self.id = id
        self.fileName = fileName
        self.fileTypeIdentifier = fileTypeIdentifier
    }

    init?(video: Video) {
        guard let id = video.id else { return nil }
        self.id = id
        self.fileName = VideoFileExportPolicy.fileName(for: video)
        self.fileTypeIdentifier = VideoFileExportPolicy.contentType(for: video).identifier
    }

    var fileType: UTType {
        UTType(fileTypeIdentifier) ?? .mpeg4Movie
    }
}

enum VideoTablePresentationPolicy {
    static func descriptorMap(
        _ descriptors: [VideoFileExportDescriptor]
    ) -> [UUID: VideoFileExportDescriptor] {
        Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// A narrow AppKit bridge for native multi-file table drags. SwiftUI's
/// `draggable` supplies one transferable per view; Finder needs one file
/// promise for each selected video.
struct VideoTableFileDragSource: NSViewRepresentable {
    let video: Video
    let videoDescriptors: [UUID: VideoFileExportDescriptor]
    @Binding var selectedVideoIDs: Set<UUID>
    let onOpenVideo: (Video) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VideoTableFileDragSourceView {
        let view = VideoTableFileDragSourceView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: VideoTableFileDragSourceView, context: Context) {
        let title = video.title ?? video.fileName ?? "Untitled"
        view.updateContent(VideoResultTitleCell(video: video))
        context.coordinator.configure(
            video: video,
            title: title,
            videoDescriptors: videoDescriptors,
            selection: $selectedVideoIDs,
            onOpenVideo: onOpenVideo
        )
    }

    final class Coordinator: NSObject, NSDraggingSource {
        private var videoID: UUID?
        private var videoTitle = "Untitled"
        private var fileName = "Untitled.mp4"
        private var fileType = UTType.mpeg4Movie
        private var descriptors: [UUID: VideoFileExportDescriptor] = [:]
        private var selection: Binding<Set<UUID>>?
        private var onOpenVideo: ((Video) -> Void)?
        private weak var video: Video?

        func configure(
            video: Video,
            title: String,
            videoDescriptors: [UUID: VideoFileExportDescriptor],
            selection: Binding<Set<UUID>>,
            onOpenVideo: @escaping (Video) -> Void
        ) {
            videoID = video.id
            videoTitle = title
            fileName = VideoFileExportPolicy.fileName(for: video)
            fileType = VideoFileExportPolicy.contentType(for: video)
            descriptors = videoDescriptors
            self.selection = selection
            self.onOpenVideo = onOpenVideo
            self.video = video
        }

        fileprivate func prepareForDrag(modifiers: NSEvent.ModifierFlags) -> [VideoFilePromiseWriter] {
            guard let videoID, let selection else { return [] }

            selectForPress(modifiers: modifiers)

            let selectedIDs = VideoTableDragPolicy.videoIDs(
                for: videoID,
                selection: selection.wrappedValue
            )
            let transfer = VideoTableDragTransfer(videoIDs: Array(selectedIDs))

            return selectedIDs.map { selectedID in
                VideoFilePromiseWriter(
                    videoID: selectedID,
                    fileName: descriptors[selectedID]?.fileName ?? fileName,
                    fileType: descriptors[selectedID]?.fileType ?? fileType,
                    transfer: transfer
                )
            }
        }

        func selectForPress(modifiers: NSEvent.ModifierFlags) {
            guard let videoID, let selection else { return }

            var nextSelection = selection.wrappedValue
            if modifiers.contains(.command) {
                nextSelection.formSymmetricDifference([videoID])
            } else if modifiers.contains(.shift) {
                nextSelection.insert(videoID)
            } else if !nextSelection.contains(videoID) {
                nextSelection = [videoID]
            }
            selection.wrappedValue = nextSelection
        }

        func openVideo() {
            guard let video else { return }
            onOpenVideo?(video)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }
    }
}

final class VideoTableFileDragSourceView: NSView {
    weak var coordinator: VideoTableFileDragSource.Coordinator?
    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private var hostingView: NSHostingView<VideoResultTitleCell>?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func updateContent(_ content: VideoResultTitleCell) {
        if let hostingView {
            hostingView.rootView = content
            return
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.hostingView = hostingView
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        mouseDownEvent = event

        if event.clickCount == 2 {
            coordinator?.openVideo()
            return
        }

        coordinator?.selectForPress(modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging,
              let coordinator,
              let mouseDownEvent else {
            return
        }

        let writers = coordinator.prepareForDrag(modifiers: [])
        guard !writers.isEmpty else { return }

        let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 24, height: 24))
        let draggingItems = writers.map { writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(
                NSRect(origin: .zero, size: image.size),
                contents: image
            )
            return item
        }

        isDragging = true
        let session = beginDraggingSession(
            with: draggingItems,
            event: mouseDownEvent,
            source: coordinator
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

private enum VideoFileExportPolicy {
    static func fileName(for video: Video) -> String {
        let candidate = video.fileName ?? video.fileURL?.lastPathComponent ?? "Pangolin Video.mp4"
        return candidate.isEmpty ? "Pangolin Video.mp4" : candidate
    }

    static func contentType(for video: Video) -> UTType {
        let pathExtension = video.fileURL?.pathExtension ?? (video.fileName as NSString?)?.pathExtension ?? ""
        return UTType(filenameExtension: pathExtension) ?? .mpeg4Movie
    }
}

private final class VideoFilePromiseWriter: NSObject, NSPasteboardWriting, NSFilePromiseProviderDelegate {
    private let videoID: UUID
    private let fileName: String
    private let fileType: UTType
    private let transferData: Data
    private lazy var filePromise = NSFilePromiseProvider(
        fileType: fileType.identifier,
        delegate: self
    )

    init(videoID: UUID, fileName: String, fileType: UTType, transfer: VideoTableDragTransfer) {
        self.videoID = videoID
        self.fileName = fileName
        self.fileType = fileType
        self.transferData = (try? JSONEncoder().encode(transfer)) ?? Data()
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = filePromise.writableTypes(for: pasteboard)
        types.append(NSPasteboard.PasteboardType(UTType.pangolinVideoTableDrag.identifier))
        return types
    }

    func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type.rawValue == UTType.pangolinVideoTableDrag.identifier {
            return []
        }
        return filePromise.writingOptions(forType: type, pasteboard: pasteboard)
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == UTType.pangolinVideoTableDrag.identifier {
            return transferData
        }
        return filePromise.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        fileName
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let sourceURL = try await VideoFileManager.shared.getVideoFileURL(forID: videoID)
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: sourceURL, to: url)
                }.value
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        return queue
    }
}
#endif
