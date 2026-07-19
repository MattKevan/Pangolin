# CloudKit-Synchronised Video Thumbnails

## Summary

Pangolin will store each video's thumbnail JPEG directly on its CloudKit-mirrored Core Data `Video` record. Thumbnails remain available locally on every device, independently of whether the corresponding video is local or cloud-only.

This is a hard break from filesystem thumbnails. Pangolin will not migrate, read, write, or preserve the old `thumbnailPath` and `projectThumbnailPath` behaviour. Videos without valid binary thumbnail data are regenerated. If such a video is cloud-only, Pangolin temporarily downloads it, generates the thumbnail, saves it, and restores its cloud-only state when storage optimisation applies.

## Goals

- Keep thumbnails visible when their videos are offloaded to iCloud.
- Synchronise thumbnail bytes and metadata through the existing `NSPersistentCloudKitContainer`.
- Retain thumbnails locally for immediate and offline browsing on every device.
- Generate missing or obsolete thumbnails without user intervention.
- Temporarily download cloud-only source videos only when generation is required.
- Resolve project artwork from the binary thumbnail of a descendant video.
- Make generation and transfer failures explicit and retryable.
- Remove the old path-based thumbnail implementation after the new path works.

## Non-goals

- Migrating or reading existing thumbnail JPEGs.
- Preserving an existing path-selected project cover.
- Embedding Pangolin metadata inside media files.
- Replacing the video-file iCloud Drive storage system.
- Introducing manually managed `CKAsset` or `CKSyncEngine` thumbnail storage.
- Automatically deleting orphaned legacy JPEG files from existing libraries; they are ignored and may be removed separately.
- Adding user-selectable project cover artwork.

## Selected approach

Add the thumbnail payload to the existing `Video` entity as externally stored Binary Data. Core Data remains the local source of truth, and `NSPersistentCloudKitContainer` synchronises the attribute through CloudKit. Core Data may represent larger values as CloudKit assets without Pangolin managing `CKAsset` records directly.

This is preferred over a separate `ThumbnailAsset` entity because thumbnails have a one-to-one lifecycle with videos and do not need independent sharing, permissions, or querying. It is preferred over direct CloudKit APIs because Pangolin already relies on Core Data mirroring and does not need a second sync engine.

## Data model

Add these attributes to `Video`:

- `thumbnailData: Binary Data?`
  - Enable **Allows External Storage**.
  - Contains a complete, decodable JPEG.
- `thumbnailGenerationVersion: Integer 16`
  - Default `0` means missing.
  - The first binary-thumbnail algorithm uses version `1`.
- `thumbnailGeneratedAt: Date?`
  - Distinguishes force-regenerated images and supports diagnostics.

Add this optional attribute to `Folder`:

- `projectThumbnailVideoID: UUID?`
  - Identifies the descendant video supplying project artwork without another binary payload or filesystem path.

Remove `Video.thumbnailPath` and `Folder.projectThumbnailPath` from the active Core Data model and runtime code. Existing CloudKit fields may remain in the deployed server schema but Pangolin no longer reads or writes them.

## Components and responsibilities

### `ThumbnailGenerator`

`ThumbnailGenerator` accepts an accessible local video URL and returns JPEG `Data`.

- Extract a frame at 10% of duration, capped at 5 seconds.
- Apply the preferred track transform.
- Fit within 640×360 without upscaling.
- Preserve aspect ratio; do not stretch to 16:9.
- Encode as JPEG at 0.78 quality.
- Validate that the result is non-empty and decodable.
- Throw typed errors for asset loading, frame extraction, encoding, and validation failures.
- Perform extraction and encoding away from the main actor.

The generator does not save Core Data, enqueue tasks, manage iCloud downloads, or evict files.

### `ThumbnailCoordinator`

`ThumbnailCoordinator` owns lifecycle decisions.

- Determine whether existing binary data is valid and current.
- Remember source video availability before generation.
- Request temporary local video availability only when required.
- Invoke `ThumbnailGenerator`.
- Save data, generation version, and generation date in one context transaction.
- Restore cloud-only state when appropriate.
- Schedule bounded retries through the existing processing queue.
- Reconcile thumbnails after CloudKit imports and library startup.
- Coalesce duplicate work for the same video.

Repair work is serial by default so several large cloud-only videos are not downloaded at once. The coordinator supports cancellation between download, generation, save, and eviction stages.

### `ThumbnailImageCache`

The image cache is a display-layer service.

- Decode JPEG data off the main thread.
- Cache platform images using video ID, generation version, and generation date.
- Coalesce simultaneous decode requests for the same key.
- Invalidate when data, version, or date changes.
- Purge decoded images under memory pressure without altering persisted data.

Views request images from the shared binary-data provider and show the existing placeholder while data is unavailable.

## New import flow

1. Import or download the video to a locally accessible staging URL.
2. Extract video metadata.
3. Generate version-1 thumbnail JPEG data.
4. Create or update the `Video` object with `thumbnailData`, `thumbnailGenerationVersion`, and `thumbnailGeneratedAt`.
5. Save the Core Data context.
6. Allow `NSPersistentCloudKitContainer` to export the record and binary payload.
7. Apply the selected video storage policy. The video may upload or become cloud-only independently of the thumbnail.

If thumbnail generation fails, video import may complete, but it must enqueue a visibly failed/retryable thumbnail task rather than silently treating thumbnail work as successful.

## Receiving-device flow

1. Core Data/CloudKit imports the `Video` record and binary thumbnail payload into the local replica.
2. The view context merges the imported change.
3. Thumbnail views observe the data/version/date change and refresh through `ThumbnailImageCache`.
4. The device retains externally stored thumbnail data locally even if the video remains cloud-only.
5. Displaying a thumbnail never requests the video file.

Reconciliation waits until the initial CloudKit import event completes before treating absent binary data as a generation candidate. This avoids downloading videos while their thumbnail records may still be arriving.

## Missing-thumbnail generation flow

For each video whose thumbnail data is missing, corrupt, or older than the current generation version:

1. Inspect and remember the video's current availability state.
2. Request local availability through `VideoFileManager`. This may temporarily download a cloud-only video.
3. Generate and validate the JPEG.
4. Save thumbnail data, version, and generation date.
5. If the video was cloud-only before generation and the library uses storage optimisation, evict the temporary local copy after the save succeeds.
6. If cancellation or failure occurs before a valid save, preserve the source video and enqueue or retry the thumbnail operation. Do not evict during failure cleanup unless upload safety and the original cloud-only state are both confirmed.

Reconciliation runs serially after library startup and after successful CloudKit import events. A video with valid current-version data requires no work.

## Project artwork

Project artwork resolves in this order:

1. The descendant video identified by `projectThumbnailVideoID`, while it remains in the project and has valid thumbnail data.
2. The first descendant video with valid thumbnail data; persist its ID for stable future resolution.
3. The existing project placeholder.

No legacy project thumbnail path is consulted.

## Failure handling and task semantics

- Thumbnail generation errors propagate to the processing task.
- A thumbnail task succeeds only after non-empty, decodable, current-version data is saved.
- Missing, invalid, or old-version data means work is incomplete.
- Transient iCloud download failures use bounded retries with backoff.
- Permanent media decoding errors remain visible in the processing UI and may be retried manually.
- Stage-specific status reports waiting for CloudKit import, downloading video, generating, saving, restoring storage state, or failure.
- Simultaneous generation requests for the same video are coalesced.

## Display behaviour

All thumbnail consumers use the shared binary-data provider:

- Project grid cards and project hero artwork
- Search results
- Video result tables
- Folder rows
- Player poster views
- Cloud/file status views

Views show a placeholder only while no valid local thumbnail data exists. They never resolve a thumbnail file URL or call iCloud Drive APIs for thumbnails.

## Old-code removal audit

After binary generation and display are working, remove the old implementation completely:

- Remove path-based thumbnail generation and JPEG writing from `FileSystemManager`.
- Remove `Video.thumbnailURL`, `Folder.projectThumbnailURL`, and path-based project cover resolution.
- Remove queue and startup checks based on `thumbnailPath`.
- Remove the unconditional `generateThumbnail -> ensureLocalAvailability` task dependency; the coordinator decides when source video access is needed.
- Remove path-based thumbnail deletion and stop creating `Thumbnails` for new libraries.
- Remove obsolete path helpers and their tests.
- Replace every thumbnail `AsyncImage` URL consumer with the binary-data provider.
- Remove `thumbnailPath` and `projectThumbnailPath` from test factories and active model assertions.

A final repository-wide search must show no operational references to either legacy path field, the `Thumbnails` directory, or thumbnail URL properties.

## Testing

### Unit tests

- Frame selection is 10% of duration capped at 5 seconds.
- Generated output is a valid JPEG no larger than 640×360 and is not upscaled.
- Current valid data requires no work.
- Invalid, empty, and old-version data require generation.
- A cloud-only video becomes temporarily local for generation.
- Successful generation restores an originally cloud-only video when optimisation is enabled.
- A locally retained video is not evicted after generation.
- Failure before save does not evict the source video.
- Cancellation preserves safe source availability.
- Duplicate generation requests coalesce.
- Task completion requires valid current-version binary data.
- Project artwork uses the persisted video ID and falls back predictably.
- Image cache keys include generation version and generation date.
- The active model has binary thumbnail fields and no legacy thumbnail path fields.

### Integration and manual verification

- macOS and iOS builds and focused thumbnail tests pass.
- Import a new video, wait for CloudKit export, offload it, and confirm its thumbnail remains visible.
- On a second device, confirm the thumbnail appears and remains offline without downloading the video.
- For an existing cloud-only video with no binary data, confirm temporary download, generation, CloudKit export, and re-eviction.
- Disable networking during each generation stage and verify retry/status behaviour.
- Confirm project, search, folder, result-table, status, and player-poster consumers update after CloudKit import.
- Confirm repository searches find no old operational thumbnail path code.

## Completion criteria

- New thumbnails synchronise through the mirrored Core Data record, not an iCloud Drive `Thumbnails` directory.
- A cloud-only video displays its locally retained thumbnail without accessing the video file.
- A second device obtains the thumbnail through CloudKit without downloading the video.
- Missing cloud-only thumbnails regenerate automatically using a temporary video download.
- Generation tasks are serial, retryable, cancellable, and accurately reported.
- Project artwork resolves from descendant video data.
- Old path-based generation, display, queue, deletion, directory, model, and test code is removed.
