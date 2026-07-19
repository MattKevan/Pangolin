import CoreData
import Testing
@testable import Pangolin

struct ThumbnailModelTests {
    @Test("Active model provides CloudKit binary thumbnail fields")
    func activeModelUsesBinaryThumbnails() throws {
        let model = try #require(NSManagedObjectModel.mergedModel(from: [Bundle.main]))
        let video = try #require(model.entitiesByName["Video"])
        let folder = try #require(model.entitiesByName["Folder"])
        let data = try #require(video.attributesByName["thumbnailData"])
        #expect(data.attributeType == .binaryDataAttributeType)
        #expect(data.allowsExternalBinaryDataStorage)
        #expect((video.attributesByName["thumbnailGenerationVersion"]?.defaultValue as? NSNumber)?.int16Value == 0)
        #expect(video.attributesByName["thumbnailGeneratedAt"]?.attributeType == .dateAttributeType)
        #expect(folder.attributesByName["projectThumbnailVideoID"]?.attributeType == .UUIDAttributeType)
    }
}
