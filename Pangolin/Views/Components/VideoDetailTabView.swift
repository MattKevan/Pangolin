import SwiftUI

struct VideoDetailTabView: View {
    @ObservedObject var video: Video
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        TabView {
            VideoInfoView(video: video)
                .tabItem {
                    Label("Info", systemImage: "info.circle")
                }
            
            TranscriptionView(video: video)
                .tabItem {
                    Label("Transcript", systemImage: "doc.text")
                }
            
            SummaryView(video: video)
                .tabItem {
                    Label("Summary", systemImage: "doc.text.below.ecg")
                }
        }
    }
}