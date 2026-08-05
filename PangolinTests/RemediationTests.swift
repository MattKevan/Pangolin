import Foundation
import Testing
@testable import Pangolin

struct RemediationTests {
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
