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
        #expect(data.isOptional == true)
        #expect(data.allowsExternalBinaryDataStorage)
        #expect((video.attributesByName["thumbnailGenerationVersion"]?.defaultValue as? NSNumber)?.int16Value == 0)
        #expect(video.attributesByName["thumbnailGenerationVersion"]?.isOptional == false)
        #expect(video.attributesByName["thumbnailGenerationVersion"]?.attributeType == .integer16AttributeType)
        #expect(video.attributesByName["thumbnailGeneratedAt"]?.attributeType == .dateAttributeType)
        #expect(video.attributesByName["thumbnailGeneratedAt"]?.isOptional == true)
        #expect(folder.attributesByName["projectThumbnailVideoID"]?.attributeType == .UUIDAttributeType)
        #expect(folder.attributesByName["projectThumbnailVideoID"]?.isOptional == true)
        #expect(video.attributesByName["thumbnailPath"] == nil)
        #expect(folder.attributesByName["projectThumbnailPath"] == nil)
    }
}
