import SwiftUI
import UniformTypeIdentifiers

struct AllVideosImportDropModifier: ViewModifier {
    let isEnabled: Bool
    let libraryManager: LibraryManager

    @State private var isExternalDropTargeted = false
    private let processingQueueManager = ProcessingQueueManager.shared

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isExternalDropTargeted) { providers in
                handleExternalFileDrop(providers: providers)
            }
            .overlay(alignment: .top) {
                if isEnabled && isExternalDropTargeted {
                    Text("Drop videos or folders to import")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
    }

    private func handleExternalFileDrop(providers: [NSItemProvider]) -> Bool {
        guard isEnabled,
              let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else {
            return false
        }

        let matchingProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !matchingProviders.isEmpty else { return false }

        let lock = NSLock()
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in matchingProviders {
            group.enter()
            let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier
                : UTType.url.identifier

            let _ = provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = droppedURL(from: item) else {
                    return
                }

                lock.lock()
                droppedURLs.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !droppedURLs.isEmpty else { return }
            Task {
                await processingQueueManager.enqueueImport(urls: droppedURLs, library: library, context: context)
            }
        }

        return true
    }

    private func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let nsURL = item as? NSURL {
            return nsURL as URL
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }

            if let string = String(data: data, encoding: .utf8),
               let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }

        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let nsString = item as? NSString {
            return URL(string: (nsString as String).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}

extension View {
    func allVideosImportDrop(
        isEnabled: Bool,
        libraryManager: LibraryManager
    ) -> some View {
        modifier(
            AllVideosImportDropModifier(
                isEnabled: isEnabled,
                libraryManager: libraryManager
            )
        )
    }
}
