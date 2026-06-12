import Foundation
import Testing
@testable import Pangolin

struct RemediationTests {
    @Test("ThreadSafeURLCollector captures every concurrently appended URL")
    func threadSafeURLCollectorCapturesAllURLs() async {
        let collector = ThreadSafeURLCollector()
        let expectedURLs = (0..<200).map {
            URL(fileURLWithPath: "/tmp/video-\($0).mp4")
        }

        await withTaskGroup(of: Void.self) { group in
            for url in expectedURLs {
                group.addTask {
                    collector.append(url)
                }
            }
        }

        #expect(Set(collector.allURLs()) == Set(expectedURLs))
    }

    @Test("Notification constants use stable typed names")
    func notificationConstantsAreStable() {
        #expect(Notification.Name.triggerSearch.rawValue == "com.pangolin.triggerSearch")
        #expect(Notification.Name.triggerRename.rawValue == "com.pangolin.triggerRename")
        #expect(Notification.Name.triggerImportVideos.rawValue == "com.pangolin.triggerImportVideos")
    }

    @Test("Deletion messaging for single video remains explicit")
    func deletionMessagingForSingleVideo() {
        let item = DeletionItem(id: UUID(), name: "Clip", isFolder: false)
        let content = [item].deletionAlertContent

        #expect(content.title == "Delete Video?")
        #expect(content.message.contains("This action cannot be undone."))
    }
}
