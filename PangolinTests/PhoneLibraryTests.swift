import Foundation
import Testing
@testable import Pangolin

struct PhoneLibraryTests {
    @Test("The Library lists All videos, Projects, Favourites and Recents in that order")
    func destinationOrderAndTitles() {
        #expect(PhoneLibraryDestination.allCases.map(\.title) == ["All videos", "Projects", "Favourites", "Recents"])
    }

    @Test("Each destination shows the matching store page")
    func destinationsMapToStorePages() {
        #expect(PhoneLibraryDestination.allVideos.storeDestination == .smartCollection(.allVideos))
        #expect(PhoneLibraryDestination.projects.storeDestination == .projects)
        #expect(PhoneLibraryDestination.favourites.storeDestination == .smartCollection(.favorites))
        #expect(PhoneLibraryDestination.recents.storeDestination == .smartCollection(.recent))
    }

    @Test("Search takes over while the field is focused or holds a query")
    func searchingState() {
        #expect(!PhoneLibraryPolicy.isSearching(isFieldFocused: false, query: ""))
        #expect(!PhoneLibraryPolicy.isSearching(isFieldFocused: false, query: "   "))
        #expect(PhoneLibraryPolicy.isSearching(isFieldFocused: true, query: ""))
        #expect(PhoneLibraryPolicy.isSearching(isFieldFocused: false, query: "typography"))
    }

    @Test("The Library bar is hidden while a video is showing")
    func libraryBarHiddenForVideos() {
        let projectID = UUID()
        let videoID = UUID()

        #expect(PhoneLibraryPolicy.showsLibraryBar(path: []))
        #expect(PhoneLibraryPolicy.showsLibraryBar(path: [.project(projectID)]))
        #expect(!PhoneLibraryPolicy.showsLibraryBar(path: [.video(videoID)]))
        #expect(!PhoneLibraryPolicy.showsLibraryBar(path: [.project(projectID), .video(videoID)]))
    }
}
