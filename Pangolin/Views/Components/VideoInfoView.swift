//
//  VideoInfoView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

enum VideoMetadataEditPolicy {
    static func savedTitle(from draft: String) -> String? {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

struct VideoMetadataEditor: View {
    @ObservedObject var video: Video
    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var isFavorite: Bool
    @State private var showsTitleError = false

    init(video: Video) {
        self.video = video
        _title = State(initialValue: video.title ?? video.fileName ?? "")
        _isFavorite = State(initialValue: video.isFavorite)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)

                Toggle("Favourite", isOn: $isFavorite)

                Section("File Information") {
                    LabeledContent("Filename", value: video.fileName ?? "Unknown")
                    LabeledContent("Format", value: video.videoFormat ?? "Unknown")
                    LabeledContent("Duration", value: video.formattedDuration)
                }
            }
            .navigationTitle("Edit Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Title Required", isPresented: $showsTitleError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Enter a title before saving this video.")
            }
        }
        .frame(minWidth: 360, minHeight: 260)
    }

    private func save() {
        guard let savedTitle = VideoMetadataEditPolicy.savedTitle(from: title) else {
            showsTitleError = true
            return
        }

        video.title = savedTitle
        video.isFavorite = isFavorite
        Task {
            await libraryManager.save()
            dismiss()
        }
    }
}
