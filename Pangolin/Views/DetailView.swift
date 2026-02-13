//
//  DetailView.swift
//  Pangolin
//

import SwiftUI

enum DetailContentTab: CaseIterable, Hashable {
    case transcript
    case translation
    case summary
    case info

    var title: String {
        switch self {
        case .transcript: return "Transcript"
        case .translation: return "Translation"
        case .summary: return "Summary"
        case .info: return "Info"
        }
    }

    var toolbarTitle: String {
        switch self {
        case .transcript: return "Transcript"
        case .translation: return "Translate"
        case .summary: return "Summary"
        case .info: return "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: return "doc.text"
        case .translation: return "globe.badge.chevron.backward"
        case .summary: return "doc.text.below.ecg"
        case .info: return "info.circle"
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    let video: Video?
    @Binding var selectedTab: DetailContentTab

    private var effectiveSelectedVideo: Video? {
        store.selectedVideo ?? video
    }

    var body: some View {
        Group {
            if let selected = effectiveSelectedVideo {
                switch selectedTab {
                case .transcript:
                    TranscriptionView(video: selected)
                case .translation:
                    TranslationView(video: selected)
                case .summary:
                    SummaryView(video: selected)
                case .info:
                    VideoInfoView(video: selected)
                }
            } else {
                ContentUnavailableView(
                    "No Video Selected",
                    systemImage: "video",
                    description: Text("Select a video in the sidebar.")
                )
            }
        }
        .onAppear {
            if let initial = video, store.selectedVideo == nil {
                store.selectVideo(initial)
            }
        }
        .environmentObject(libraryManager)
        .environmentObject(transcriptionService)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
