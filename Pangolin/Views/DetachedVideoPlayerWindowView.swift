//
//  DetachedVideoPlayerWindowView.swift
//  Pangolin
//

import SwiftUI
import CoreData

struct DetachedVideoPlayerWindowView: View {
    let videoID: String?

    @EnvironmentObject private var libraryManager: LibraryManager
    @State private var resolvedVideo: Video?

    var body: some View {
        InspectorVideoPanel(video: resolvedVideo, allowOpenInNewWindow: false)
            .frame(minWidth: 540, minHeight: 320)
            .navigationTitle(resolvedVideo?.title ?? "Video")
            .onAppear(perform: resolveVideo)
            .onChange(of: videoID) { _, _ in
                resolveVideo()
            }
    }

    private func resolveVideo() {
        guard let videoID,
              let uuid = UUID(uuidString: videoID),
              let context = libraryManager.viewContext else {
            resolvedVideo = nil
            return
        }

        let request = Video.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)

        resolvedVideo = try? context.fetch(request).first
    }
}
