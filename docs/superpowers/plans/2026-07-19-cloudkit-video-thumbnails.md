# CloudKit Video Thumbnails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace filesystem thumbnail paths with locally retained, CloudKit-synchronised JPEG data on each `Video`, including safe generation for cloud-only videos and complete removal of the old runtime path.

**Architecture:** Core Data stores externally backed JPEG data and mirrors it through `NSPersistentCloudKitContainer`. A focused generator produces validated 640×360 JPEGs, a main-actor coordinator serialises download/generate/save/re-evict work, and a shared decoded-image cache feeds every SwiftUI consumer without thumbnail files.

**Tech Stack:** Swift 5, SwiftUI, Core Data, CloudKit mirroring, AVFoundation, ImageIO, UniformTypeIdentifiers, Swift Testing, XcodeGen.

---

## File map

**Create**

- `Pangolin/Services/ThumbnailGenerator.swift` — frame extraction, JPEG encoding, and validation.
- `Pangolin/Managers/ThumbnailCoordinator.swift` — serial generation, temporary downloads, saving, cancellation, coalescing, and re-eviction.
- `Pangolin/Views/Components/SyncedThumbnailImage.swift` — decoded-image cache and reusable SwiftUI image view.
- `PangolinTests/ThumbnailModelTests.swift`
- `PangolinTests/ThumbnailGeneratorTests.swift`
- `PangolinTests/ThumbnailCoordinatorTests.swift`
- `PangolinTests/ThumbnailImageCacheTests.swift`

**Modify**

- `Pangolin/Pangolin.xcdatamodeld/Pangolin.xcdatamodel/contents`
- `Pangolin/Models/VideoModel.swift`
- `Pangolin/Models/ProcessingTask.swift`
- `Pangolin/Managers/FileSystemManager.swift`
- `Pangolin/Import/VideoImporter.swift`
- `Pangolin/Managers/ProcessingQueueManager.swift`
- `Pangolin/Managers/LibraryManager.swift`
- `Pangolin/Stores/FolderNavigationStore.swift`
- `Pangolin/PangolinApp.swift`
- `Pangolin/Views/Components/VideoThumbnailView.swift`
- `Pangolin/Views/Components/ContentRowView.swift`
- `Pangolin/Views/Components/VideoFileStatusView.swift`
- `Pangolin/Views/Components/VideoPlayerWithPosterView.swift`
- `Pangolin/Views/ProjectsView.swift`
- `PangolinTests/ProjectsStoreTests.swift`
- `PangolinTests/VideoNavigationSequenceTests.swift`
- `PangolinTests/FileSystemManagerTests.swift`
- `Pangolin.xcodeproj/project.pbxproj` — regenerate with XcodeGen as new files are added.

## Task 1: Add the CloudKit thumbnail fields

**Files:**
- Modify: `Pangolin/Pangolin.xcdatamodeld/Pangolin.xcdatamodel/contents`
- Create: `PangolinTests/ThumbnailModelTests.swift`
- Modify: `Pangolin.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing schema test**

```swift
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
```

- [ ] **Step 2: Regenerate and verify RED**

```bash
xcodegen generate
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailModel -only-testing:PangolinTests/ThumbnailModelTests test
```

Expected: FAIL because the binary fields do not exist.

- [ ] **Step 3: Change the model**

Add to `Folder` alongside the temporary legacy field:

```xml
<attribute name="projectThumbnailVideoID" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
```

Add to `Video` alongside the temporary legacy field:

```xml
<attribute name="thumbnailData" optional="YES" attributeType="Binary" allowsExternalBinaryDataStorage="YES"/>
<attribute name="thumbnailGeneratedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
<attribute name="thumbnailGenerationVersion" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
```

The two legacy attributes remain temporarily so each intermediate commit compiles. They are not read or written by the new implementation and are removed in Task 8 before final verification.

- [ ] **Step 4: Run the focused test**

Run the Step 2 command again. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Pangolin.xcdatamodeld/Pangolin.xcdatamodel/contents PangolinTests/ThumbnailModelTests.swift Pangolin.xcodeproj/project.pbxproj
git commit -m "feat: store video thumbnails in Core Data"
```

## Task 2: Implement bounded JPEG generation

**Files:**
- Create: `Pangolin/Services/ThumbnailGenerator.swift`
- Create: `PangolinTests/ThumbnailGeneratorTests.swift`
- Modify: `Pangolin.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing generator tests**

```swift
import Foundation
import Testing
@testable import Pangolin

struct ThumbnailGeneratorTests {
    @Test("Frame time is ten percent capped at five seconds", arguments: [
        (20.0, 2.0), (120.0, 5.0), (0.0, 0.0)
    ])
    func frameTime(duration: Double, expected: Double) {
        #expect(ThumbnailGenerator.frameTime(forDuration: duration) == expected)
    }

    @Test("Invalid image data is rejected")
    func validation() {
        #expect(!ThumbnailGenerator.isValidJPEG(Data()))
        #expect(!ThumbnailGenerator.isValidJPEG(Data("bad".utf8)))
    }

    @Test("Generated JPEG is valid, bounded, and not upscaled")
    func generatedJPEG() async throws {
        let fixture = try await TestVideoFactory.makeMovie(width: 320, height: 180, duration: 1)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let data = try await ThumbnailGenerator().generate(from: fixture)
        let size = try #require(ThumbnailGenerator.pixelSize(ofJPEG: data))
        #expect(ThumbnailGenerator.isValidJPEG(data))
        #expect(size.width <= 640 && size.height <= 360)
        #expect(size.width == 320 && size.height == 180)
    }
}
```

Implement the fixture in the same test file:

```swift
import AVFoundation
import CoreVideo

private enum TestVideoFactory {
    static func makeMovie(width: Int, height: Int, duration: TimeInterval) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frameCount = max(1, Int(duration * 30))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x66,
                   CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            #expect(adaptor.append(pixelBuffer,
                                   withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestVideoError.writeFailed }
        return url
    }
}

private enum TestVideoError: Error { case writeFailed }
```

- [ ] **Step 2: Regenerate and verify RED**

```bash
xcodegen generate
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailGenerator -only-testing:PangolinTests/ThumbnailGeneratorTests test
```

Expected: FAIL because `ThumbnailGenerator` does not exist.

- [ ] **Step 3: Implement the generator contract**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ThumbnailGenerating: Sendable {
    func generate(from videoURL: URL) async throws -> Data
}

actor ThumbnailGenerator: ThumbnailGenerating {
    static let currentVersion: Int16 = 1
    static let maximumSize = CGSize(width: 640, height: 360)
    static let jpegQuality = 0.78

    static func frameTime(forDuration duration: TimeInterval) -> TimeInterval {
        min(max(duration, 0) * 0.1, 5)
    }

    func generate(from videoURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = Self.maximumSize
        let time = CMTime(seconds: Self.frameTime(forDuration: duration), preferredTimescale: 600)
        let image = try await generator.image(at: time).image
        return try Self.encodeJPEG(image)
    }

    static func isValidJPEG(_ data: Data) -> Bool { pixelSize(ofJPEG: data) != nil }

    static func pixelSize(ofJPEG data: Data) -> CGSize? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = values[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ThumbnailGenerationError.encodingFailed }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), isValidJPEG(output as Data) else {
            throw ThumbnailGenerationError.encodingFailed
        }
        return output as Data
    }
}

enum ThumbnailGenerationError: LocalizedError {
    case encodingFailed
    var errorDescription: String? { "The thumbnail could not be encoded as JPEG." }
}
```

- [ ] **Step 4: Run tests and both-platform builds**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailGenerator -only-testing:PangolinTests/ThumbnailGeneratorTests test
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ThumbnailGenerator-iOS CODE_SIGNING_ALLOWED=NO build
```

Expected: tests PASS and both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Services/ThumbnailGenerator.swift PangolinTests/ThumbnailGeneratorTests.swift Pangolin.xcodeproj/project.pbxproj
git commit -m "feat: generate bounded JPEG thumbnails"
```

## Task 3: Add binary validity and project artwork resolution

**Files:**
- Modify: `Pangolin/Models/VideoModel.swift`
- Modify: `Pangolin/Stores/FolderNavigationStore.swift`
- Modify: `PangolinTests/ProjectsStoreTests.swift`
- Modify: `PangolinTests/VideoNavigationSequenceTests.swift`

- [ ] **Step 1: Convert test factories and write failing behaviour tests**

Replace `thumbnailPath: String?` fixture parameters with `thumbnailData: Data?`. When data is supplied, also set current version and a generated date. Add assertions that invalid bytes are not current and that a project persists the ID of its first descendant with valid current data.

```swift
#expect(!invalidVideo.hasCurrentThumbnail)
#expect(validVideo.hasCurrentThumbnail)
#expect(project.resolvedProjectThumbnailVideo?.id == validVideo.id)
#expect(project.projectThumbnailVideoID == validVideo.id)
```

- [ ] **Step 2: Verify RED**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailModelLogic -only-testing:PangolinTests/ProjectsStoreTests test
```

Expected: FAIL because binary validity and project video resolution do not exist.

- [ ] **Step 3: Replace URL/path helpers**

```swift
extension Video {
    var hasCurrentThumbnail: Bool {
        guard thumbnailGenerationVersion == ThumbnailGenerator.currentVersion,
              let thumbnailData else { return false }
        return ThumbnailGenerator.isValidJPEG(thumbnailData)
    }
}

extension Folder {
    var descendantVideos: [Video] {
        videosArray + childFoldersArray.flatMap(\.descendantVideos)
    }

    var resolvedProjectThumbnailVideo: Video? {
        if let projectThumbnailVideoID,
           let selected = descendantVideos.first(where: {
               $0.id == projectThumbnailVideoID && $0.hasCurrentThumbnail
           }) { return selected }
        return descendantVideos.first(where: \.hasCurrentThumbnail)
    }
}
```

Remove `thumbnailURL`, `resolvedProjectThumbnailPath`, `projectThumbnailURL`, and path recursion. Update `backfillProjectMetadataIfNeeded` to persist `resolvedProjectThumbnailVideo?.id` whenever the stored ID is absent or stale.

- [ ] **Step 4: Run project and navigation tests**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailModelLogic -only-testing:PangolinTests/ProjectsStoreTests -only-testing:PangolinTests/VideoNavigationSequenceTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Models/VideoModel.swift Pangolin/Stores/FolderNavigationStore.swift PangolinTests/ProjectsStoreTests.swift PangolinTests/VideoNavigationSequenceTests.swift
git commit -m "feat: resolve artwork from thumbnail data"
```

## Task 4: Coordinate cloud-only generation safely

**Files:**
- Create: `Pangolin/Managers/ThumbnailCoordinator.swift`
- Create: `PangolinTests/ThumbnailCoordinatorTests.swift`
- Modify: `Pangolin.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing coordinator tests**

Use fake generator and video-access implementations. Test each behaviour independently:

```swift
@Test("Cloud-only source is downloaded, saved, and re-evicted under optimize storage")
@MainActor
func restoresCloudOnlyState() async throws {
    let harness = try await Harness.make(status: .cloudOnly, preference: .optimizeStorage)
    try await harness.coordinator.generateThumbnail(for: harness.video, force: false)
    #expect(harness.access.localURLRequests == 1)
    #expect(harness.access.evictions == 1)
    #expect(harness.video.thumbnailData == harness.generator.output)
}

@Test("Failure before save keeps the downloaded source local")
@MainActor
func failureDoesNotEvict() async throws {
    let harness = try await Harness.make(status: .cloudOnly, preference: .optimizeStorage,
                                         generatorError: TestError.failed)
    await #expect(throws: TestError.self) {
        try await harness.coordinator.generateThumbnail(for: harness.video, force: false)
    }
    #expect(harness.access.evictions == 0)
    #expect(harness.video.thumbnailData == nil)
}
```

Also test: current data skips; force regenerates; keep-all-downloaded never evicts; invalid generator data fails; cancellation does not evict; two simultaneous calls coalesce to one generator call; transient download errors retry after delays `[5, 15, 45]`; decoding errors do not retry automatically.

- [ ] **Step 2: Regenerate and verify RED**

```bash
xcodegen generate
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailCoordinator -only-testing:PangolinTests/ThumbnailCoordinatorTests test
```

Expected: FAIL because coordinator APIs do not exist.

- [ ] **Step 3: Implement injectable boundaries and coordinator**

```swift
@MainActor
protocol ThumbnailVideoAccessing: AnyObject {
    func thumbnailStatus(for video: Video) async -> VideoFileStatus
    func thumbnailLocalURL(for video: Video) async throws -> URL
    func evictThumbnailSource(for video: Video) async throws
}

extension VideoFileManager: ThumbnailVideoAccessing {
    func thumbnailStatus(for video: Video) async -> VideoFileStatus {
        await isVideoFileAccessible(video)
    }
    func thumbnailLocalURL(for video: Video) async throws -> URL {
        try await getVideoFileURL(for: video, downloadIfNeeded: true)
    }
    func evictThumbnailSource(for video: Video) async throws {
        try await evictLocalCopy(for: video)
    }
}
```

Create a `@MainActor ThumbnailCoordinator` with injected `ThumbnailGenerating` and `ThumbnailVideoAccessing`, an `[UUID: Task<Void, Error>]` in-flight map, and these methods:

```swift
enum ThumbnailStage { case preparing, downloadingVideo, generating, saving, restoringStorage }

func generateThumbnail(
    for video: Video,
    force: Bool,
    onStage: @MainActor (ThumbnailStage) -> Void = { _ in }
) async throws
func generateNewImportThumbnail(for video: Video, sourceURL: URL) async throws
func reconcile(videos: [Video]) async
func cancel(videoID: UUID)
```

The internal sequence must emit the matching stage and then: capture original status → request local URL → check cancellation → generate → validate → check cancellation → assign data/version/date → save context → re-evict only when original status was `.cloudOnly` and preference is `.optimizeStorage`. `cancel(videoID:)` cancels the corresponding in-flight task. On any pre-save error, do not evict.

Add `ThumbnailRetryPolicy.delays = [5, 15, 45]`. Retry only `VideoFileError.cloudContainerUnavailable` and download failures; propagate decoding, encoding, cancellation, missing-ID, and invalid-data errors immediately. Inject a `sleep` closure in tests so retry tests do not wait in real time.

- [ ] **Step 4: Run coordinator tests**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Managers/ThumbnailCoordinator.swift PangolinTests/ThumbnailCoordinatorTests.swift Pangolin.xcodeproj/project.pbxproj
git commit -m "feat: coordinate cloud-only thumbnail generation"
```

## Task 5: Integrate import, queue, startup, and CloudKit events

**Files:**
- Modify: `Pangolin/Managers/FileSystemManager.swift`
- Modify: `Pangolin/Import/VideoImporter.swift`
- Modify: `Pangolin/Managers/ProcessingQueueManager.swift`
- Modify: `Pangolin/Models/ProcessingTask.swift`
- Modify: `Pangolin/Managers/LibraryManager.swift`
- Modify: `Pangolin/PangolinApp.swift`
- Test: `PangolinTests/ThumbnailCoordinatorTests.swift`

- [ ] **Step 1: Write failing integration-policy tests**

```swift
#expect(ProcessingTaskType.generateThumbnail.dependencies.isEmpty)
#expect(ThumbnailWorkPolicy.needsGeneration(data: nil, version: 0, force: false))
#expect(!ThumbnailWorkPolicy.needsGeneration(data: validJPEG,
                                             version: ThumbnailGenerator.currentVersion,
                                             force: false))
#expect(ThumbnailWorkPolicy.needsGeneration(data: validJPEG,
                                            version: ThumbnailGenerator.currentVersion,
                                            force: true))
```

`ThumbnailWorkPolicy` belongs in `ThumbnailCoordinator.swift` and validates actual JPEG bytes.

- [ ] **Step 2: Verify RED**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailIntegration -only-testing:PangolinTests/ThumbnailCoordinatorTests test
```

Expected: FAIL because the task dependency still exists and the policy is absent.

- [ ] **Step 3: Generate before upload**

Remove path thumbnail generation and assignment from `FileSystemManager.importVideo`. In `VideoImporter.importSingleFile`, immediately before `uploadImportedVideoToCloud`, call:

```swift
do {
    try await ThumbnailCoordinator.shared.generateNewImportThumbnail(
        for: video,
        sourceURL: localStagingURL
    )
} catch {
    print("Thumbnail generation deferred for \(video.fileName ?? "Unknown"): \(error)")
}
```

Thumbnail failure must not abort video import; the queue enqueues missing work after upload.

- [ ] **Step 4: Route queue work through the coordinator**

- Change `.generateThumbnail.dependencies` to `[]`.
- Do not call `ensureDependencies` for thumbnail tasks.
- Make `executeThumbnail` call `ThumbnailCoordinator.shared.generateThumbnail(for:force:onStage:)` and map every `ThumbnailStage` to the task messages “Preparing thumbnail…”, “Downloading video for thumbnail…”, “Generating thumbnail…”, “Saving thumbnail…”, and “Restoring cloud-only video…”.
- Make task completion use `video.hasCurrentThumbnail`.
- After import, enqueue when `!video.hasCurrentThumbnail`.
- Preserve the existing serial worker; do not add a competing repair loop.
- In `cancelTask`, when the task type is `.generateThumbnail`, call `ThumbnailCoordinator.shared.cancel(videoID:)` before marking the processing task cancelled.

- [ ] **Step 5: Reconcile after startup and CloudKit imports**

At library open, fetch every library video, wait exactly 10 seconds, then enqueue those failing `hasCurrentThumbnail`; cancel that deferred task if the library closes. In `handleCloudKitEvent`, after a successful completed `.import`, fetch current-library videos and immediately enqueue those failing `hasCurrentThumbnail`. Existing task-key coalescing prevents duplicates, and fetching all videos also detects corrupt current-version bytes.

Keep the “Generate Thumbnails” command but make `force: true` regenerate binary data.

- [ ] **Step 6: Run focused tests and macOS build**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailIntegration -only-testing:PangolinTests/ThumbnailCoordinatorTests test
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailIntegration build
```

Expected: tests PASS and build exits 0.

- [ ] **Step 7: Commit**

```bash
git add Pangolin/Managers/FileSystemManager.swift Pangolin/Import/VideoImporter.swift Pangolin/Managers/ProcessingQueueManager.swift Pangolin/Models/ProcessingTask.swift Pangolin/Managers/LibraryManager.swift Pangolin/PangolinApp.swift PangolinTests/ThumbnailCoordinatorTests.swift
git commit -m "feat: integrate synced thumbnail processing"
```

## Task 6: Add the decoded image cache and shared SwiftUI view

**Files:**
- Create: `Pangolin/Views/Components/SyncedThumbnailImage.swift`
- Create: `PangolinTests/ThumbnailImageCacheTests.swift`
- Modify: `Pangolin/Views/Components/VideoThumbnailView.swift`
- Modify: `Pangolin.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing cache-key test**

```swift
@Test("Force regeneration changes the cache key")
func generatedDateInvalidatesCache() {
    let id = UUID()
    let first = ThumbnailCacheKey(videoID: id, version: 1,
                                  generatedAt: Date(timeIntervalSince1970: 1))
    let second = ThumbnailCacheKey(videoID: id, version: 1,
                                   generatedAt: Date(timeIntervalSince1970: 2))
    #expect(first != second)
}
```

- [ ] **Step 2: Regenerate and verify RED**

```bash
xcodegen generate
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailImage -only-testing:PangolinTests/ThumbnailImageCacheTests test
```

Expected: FAIL because `ThumbnailCacheKey` does not exist.

- [ ] **Step 3: Implement the cache contract**

```swift
struct ThumbnailCacheKey: Hashable, Sendable {
    let videoID: UUID
    let version: Int16
    let generatedAt: Date?
}

actor ThumbnailImageCache {
    static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    func image(for key: ThumbnailCacheKey, data: Data) -> PlatformImage? {
        let token = "\(key.videoID):\(key.version):\(key.generatedAt?.timeIntervalSince1970 ?? 0)" as NSString
        if let image = cache.object(forKey: token) { return image }
        guard ThumbnailGenerator.isValidJPEG(data), let image = PlatformImage(data: data) else { return nil }
        cache.setObject(image, forKey: token)
        return image
    }

    func removeAll() { cache.removeAllObjects() }
}
```

Add generic `SyncedThumbnailImage<Placeholder: View>`. Its inner `ObservedSyncedThumbnailImage` stores `@ObservedObject var video: Video`, builds a key from ID/version/date, loads via `.task(id:)`, renders `Image(platformImage:)`, and shows the caller's placeholder otherwise. On iOS observe `UIApplication.didReceiveMemoryWarningNotification`; on macOS observe `NSApplication.didResignActiveNotification`. Both notifications call `ThumbnailImageCache.shared.removeAll()` and never alter Core Data.

- [ ] **Step 4: Convert `VideoThumbnailView`**

Replace URL `AsyncImage` with `SyncedThumbnailImage(video:contentMode:placeholder:)`; preserve duration and cloud-status overlays.

- [ ] **Step 5: Run cache tests and both-platform builds**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailImage -only-testing:PangolinTests/ThumbnailImageCacheTests test
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ThumbnailImage-iOS CODE_SIGNING_ALLOWED=NO build
```

Expected: test PASS and both builds exit 0.

- [ ] **Step 6: Commit**

```bash
git add Pangolin/Views/Components/SyncedThumbnailImage.swift Pangolin/Views/Components/VideoThumbnailView.swift PangolinTests/ThumbnailImageCacheTests.swift Pangolin.xcodeproj/project.pbxproj
git commit -m "feat: display cached CloudKit thumbnails"
```

## Task 7: Convert every remaining thumbnail consumer

**Files:**
- Modify: `Pangolin/Views/Components/ContentRowView.swift`
- Modify: `Pangolin/Views/Components/VideoFileStatusView.swift`
- Modify: `Pangolin/Views/Components/VideoPlayerWithPosterView.swift`
- Modify: `Pangolin/Views/ProjectsView.swift`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Add the stale-project-cover test**

Create two valid descendant videos, persist the first ID, then move/delete it from the project. Expect project refresh to persist the second ID and resolve its binary data.

- [ ] **Step 2: Verify RED**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailConsumers -only-testing:PangolinTests/ProjectsStoreTests test
```

Expected: FAIL until stale IDs are reconciled.

- [ ] **Step 3: Replace all consumers**

- Replace URL `AsyncImage` in `ContentRowView` with `SyncedThumbnailImage`.
- Replace URL `AsyncImage` in `VideoRowWithStatusView` with `SyncedThumbnailImage`.
- Replace synchronous URL decoding in `VideoPlayerWithPosterView` with `SyncedThumbnailImage` and a black placeholder.
- Pass `project.resolvedProjectThumbnailVideo` to `SyncedThumbnailImage` in both project hero and project card.
- Preserve existing frames, clipping, overlays, and placeholders.
- Clear a stale `projectThumbnailVideoID`, select the first current descendant, and save its ID.

- [ ] **Step 4: Run tests and both builds**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailConsumers -only-testing:PangolinTests/ProjectsStoreTests test
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailConsumers build
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ThumbnailConsumers-iOS CODE_SIGNING_ALLOWED=NO build
```

Expected: tests PASS and builds exit 0.

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Views/Components/ContentRowView.swift Pangolin/Views/Components/VideoFileStatusView.swift Pangolin/Views/Components/VideoPlayerWithPosterView.swift Pangolin/Views/ProjectsView.swift Pangolin/Stores/FolderNavigationStore.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "refactor: use synced thumbnails throughout the UI"
```

## Task 8: Remove and audit the old implementation

**Files:**
- Modify: `Pangolin/Pangolin.xcdatamodeld/Pangolin.xcdatamodel/contents`
- Modify: `Pangolin/Managers/FileSystemManager.swift`
- Modify: `Pangolin/Managers/LibraryManager.swift`
- Modify: `Pangolin/Stores/FolderNavigationStore.swift`
- Modify: `Pangolin/Models/VideoModel.swift`
- Modify: `Pangolin/Utilities/Color+App.swift` if URL image loading becomes unused
- Modify: `PangolinTests/FileSystemManagerTests.swift`
- Modify: `PangolinTests/ThumbnailModelTests.swift`

- [ ] **Step 1: Capture the failing audit**

```bash
rg -n 'thumbnailPath|projectThumbnailPath|thumbnailURL|projectThumbnailURL|"Thumbnails"|mediaRelativePath|generateMissingThumbnails|rebuildAllThumbnails' Pangolin PangolinTests
```

Expected: remaining matches identify old path generation, deletion, directory creation, URL helpers, and obsolete tests.

- [ ] **Step 2: Delete old code**

Remove:

- `FileSystemManager.mediaRelativePath`, path-returning thumbnail generators, `writeJPEG`, `generateMissingThumbnails`, and `rebuildAllThumbnails`.
- `Video.thumbnailURL`, `Folder.projectThumbnailURL`, and path recursion.
- Thumbnail-file deletion from video deletion.
- `Thumbnails` from new-library directory creation and folder-store scaffolding.
- Obsolete `mediaRelativePath` tests.
- `platformImage(from:)` if no non-thumbnail caller remains.
- The `Video.thumbnailPath` and `Folder.projectThumbnailPath` attributes from the active Core Data model.

Extend `ThumbnailModelTests` here to assert that both legacy attributes are absent. Keeping those literal names in this single schema test is intentional evidence of the hard break, not an operational compatibility reference.

Do not add a compatibility accessor, migration reader, fallback URL, or filesystem write.

- [ ] **Step 3: Prove the audit is clean**

```bash
if rg -n 'thumbnailPath|projectThumbnailPath|thumbnailURL|projectThumbnailURL|"Thumbnails"|mediaRelativePath|generateMissingThumbnails|rebuildAllThumbnails' Pangolin PangolinTests --glob '!ThumbnailModelTests.swift'; then exit 1; fi
```

Expected: exit 0 with no matches.

- [ ] **Step 4: Run focused tests and integrity checks**

```bash
git diff --check
plutil -lint Pangolin.xcodeproj/project.pbxproj
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailCleanup -only-testing:PangolinTests/ThumbnailModelTests -only-testing:PangolinTests/ThumbnailGeneratorTests -only-testing:PangolinTests/ThumbnailCoordinatorTests -only-testing:PangolinTests/ThumbnailImageCacheTests -only-testing:PangolinTests/ProjectsStoreTests test
```

Expected: diff clean, plist `OK`, tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Pangolin PangolinTests
git commit -m "refactor: remove filesystem thumbnail code"
```

## Task 9: Full verification and CloudKit handoff

**Files:**
- Modify only if verification exposes a defect.

- [ ] **Step 1: Run the unit bundle**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailFinal -only-testing:PangolinTests test
```

Expected: `** TEST SUCCEEDED **`. If Xcode cannot initialise its runner, preserve the exact infrastructure error and rerun all focused thumbnail tests.

- [ ] **Step 2: Build and launch**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/Pangolin-ThumbnailFinal build
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ThumbnailFinal-iOS CODE_SIGNING_ALLOWED=NO build
./script/build_and_run.sh --verify
```

Expected: both builds succeed and the script reports a successful launch.

- [ ] **Step 3: Repeat the hard-break audit**

```bash
if rg -n 'thumbnailPath|projectThumbnailPath|thumbnailURL|projectThumbnailURL|"Thumbnails"|mediaRelativePath|generateMissingThumbnails|rebuildAllThumbnails' Pangolin PangolinTests --glob '!ThumbnailModelTests.swift'; then exit 1; fi
git diff --check
git status --short
```

Expected: no legacy matches, no whitespace errors, and only intentional changes.

- [ ] **Step 4: Perform the manual CloudKit matrix**

1. Import a video on device A and wait for Core Data CloudKit export completion.
2. Offload the video and verify every thumbnail consumer remains populated.
3. Open the library on device B and verify the thumbnail appears without a video download event.
4. For a controlled video, clear binary thumbnail data while leaving the source cloud-only; verify one task downloads, generates, saves, and re-evicts it.
5. Disable networking during download; verify visible failure and safe source retention.
6. Restore networking, retry, and verify completion.

- [ ] **Step 5: Commit verification corrections only if needed**

Review `git diff --name-only`, stage each corrected file by its literal path, and commit with:

```bash
git commit -m "fix: complete CloudKit thumbnail verification"
```

Do not use `git add .`, and do not create an empty commit when no corrections are required.
