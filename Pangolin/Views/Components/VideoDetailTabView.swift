import SwiftUI

enum InspectorTab: Hashable, CaseIterable {
    case transcript
    case summary
    case info
    
    var title: String {
        switch self {
        case .transcript: return "Transcript"
        case .summary: return "Summary"
        case .info: return "Info"
        }
    }
    
    var systemImage: String {
        switch self {
        case .transcript: return "doc.text"
        case .summary: return "doc.text.below.ecg"
        case .info: return "info.circle"
        }
    }
}

struct VideoDetailTabView: View {
    @ObservedObject var video: Video
    @EnvironmentObject var libraryManager: LibraryManager
    
    @State private var selection: InspectorTab = .transcript
    
    var body: some View {
        VStack(spacing: 10) {
            // Compact segmented control for inspector
            Picker("Section", selection: $selection) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            
            // Selected content
            Group {
                switch selection {
                case .transcript:
                    TranscriptionView(video: video)
                        .environmentObject(libraryManager)
                case .summary:
                    SummaryView(video: video)
                        .environmentObject(libraryManager)
                case .info:
                    VideoInfoView(video: video)
                        .environmentObject(libraryManager)
                }
            }
            // Make the inspector scrollable and compact
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 8)
    }
}
