import SwiftUI

struct ProcessingControlsInspectorView: View {
    let tab: InspectorTab
    @ObservedObject var video: Video

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch tab {
                case .transcript:
                    TranscriptionControlsInspectorPane(video: video)
                case .translation:
                    TranslationControlsInspectorPane(video: video)
                case .summary:
                    SummaryControlsInspectorPane(video: video)
                case .flashcards:
                    FlashcardsControlsInspectorPane(video: video)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #endif
    }
}
