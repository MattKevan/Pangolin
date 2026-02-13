//
//  InspectorContentView.swift
//  Pangolin
//
//  Inline inspector for the detail area
//

import SwiftUI

enum InspectorTab: CaseIterable, Hashable {
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
    
    var systemImage: String {
        switch self {
        case .transcript: return "doc.text"
        case .translation: return "globe.badge.chevron.backward"
        case .summary: return "doc.text.below.ecg"
        case .info: return "info.circle"
        }
    }
}

struct InspectorContentView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService
    let video: Video?
    
    @State private var selectedTab: InspectorTab = .transcript
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector Section", selection: $selectedTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .labelsHidden()
            
            content
                .padding(.horizontal, 8)
                .padding(.top, 8)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(.regularMaterial)
        #else
        .background(Color(.tertiarySystemBackground))
        #endif
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
        }
    }
    
    @ViewBuilder
    private var content: some View {
        if let selected = video {
            switch selectedTab {
            case .transcript:
                TranscriptionView(video: selected)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
                    .background(.clear)
            case .translation:
                TranslationView(video: selected)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
                    .background(.clear)
            case .summary:
                SummaryView(video: selected)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
                    .background(.clear)
            case .info:
                VideoInfoView(video: selected)
                    .environmentObject(libraryManager)
                    .background(.clear)
            }
        } else {
            ContentUnavailableView(
                "No Video Selected",
                systemImage: "sidebar.right",
                description: Text("Select a video to view transcript, summary and info")
            )
            .background(.clear)
        }
    }
}

