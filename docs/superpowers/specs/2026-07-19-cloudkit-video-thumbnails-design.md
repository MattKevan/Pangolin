# CloudKit-Synchronised Video Thumbnails

## Summary

Pangolin will store each video's thumbnail JPEG directly on its CloudKit-mirrored Core Data `Video` record. Thumbnails will remain available locally on every device, independently of whether the corresponding video is local or cloud-only.

New imports generate their thumbnail before video storage optimisation runs. Existing videos migrate from path-based JPEGs where possible. If a legacy cloud-only video has no usable thumbnail, Pangolin may temporarily download it, generate the thumbnail, save the result, and restore the video's previous cloud-only state.

## Goals

- Keep thumbnails visible when their videos are offloaded to iCloud.
- Synchronise thumbnail bytes and thumbnail metadata through the existing `NSPersistentCloudKitContainer`.
- Retain thumbnails locally for immediate and offline browsing on every device.
- Repair legacy and damaged thumbnail records without requiring user intervention.
- Avoid downloading cloud-only videos when a usable thumbnail can be received from CloudKit or migrated from an existing JPEG.
- Preserve the existing project artwork behaviour during migration.
- Make generation and transfer failures explicit and retryable.

## Non-goals

- Embedding Pangolin metadata inside `.mp4`, `.mov`, or other media files.
- Replacing the existing video-file iCloud Drive storage system.
- Introducing a manually managed CloudKit or `CKSyncEngine` thumbnail store.
- Removing legacy thumbnail files in the first migration release.
- Adding user-selectable project cover artwork in this change.

## Selected approach

Add the thumbnail payload to the existing `Video` entity as externally stored Binary Data. Core Data remains the local source of truth, and `NSPersistentCloudKitContainer` synchronises the attribute through CloudKit. Core Data may represent larger values as CloudKit assets without Pangolin managing `CKAsset` records directly.

This is preferred over a separate `ThumbnailAsset` entity because thumbnails have a one-to-one lifecycle with videos and do not currently need independent sharing, permissions, or querying. It is preferred over direct CloudKit APIs because the application already relies on Core Data mirroring and does not need a second sync engine.

## Data model

Add these optional/defaulted attributes to `Video`:

- `thumbnailData: Binary Data?`
  - Enable **Allows External Storage**.
  - Contains a complete, decodable JPEG.
- `thumbnailGenerationVersion: Integer 16`
  - Default `0` means missing or legacy.
  - The first binary-thumbnail algorithm uses version `1`.
- `thumbnailGeneratedAt: Date?`
  - Used for diagnostics and repair decisions, not as the sole validity check.

Keep `thumbnailPath` during the migration release. It becomes legacy-only: new generation does not write it, but migration may read it to locate an existing JPEG.

Add one optional attribute to `Folder`:

- `projectThumbnailVideoID: UUID?`
  - Identifies the descendant video supplying project artwork without introducing another binary payload or a filesystem path.
  - During migration, populate it from the descendant whose legacy `thumbnailPath` matches `projectThumbnailPath`.

Project artwork reads the selected video's `thumbnailData`. If the identifier is absent or no longer points to a descendant with valid data, the project falls back to its first descendant video with valid thumbnail data and persists that video's ID. Keep `projectThumbnailPath` as legacy-only during the migration release.

## Components and responsibilities

### `ThumbnailGenerator`

`ThumbnailGenerator` accepts an accessible local video URL and returns JPEG `Data`.

- Extract a frame at 10% of duration, capped at 5 seconds.
- Apply the preferred track transform.
- Fit within 640×360 without upscaling.
- Preserve aspect ratio; do not stretch the frame to 16:9.
- Encode as JPEG at 0.78 quality.
- Validate that the result is non-empty and decodable.
- Throw typed errors for asset loading, frame extraction, encoding, and validation failures.
- Perform expensive extraction and encoding work away from the main actor.

The generator does not save Core Data, enqueue tasks, manage iCloud downloads, or evict files.

### `ThumbnailCoordinator`

`ThumbnailCoordinator` owns lifecycle decisions.

- Determine whether existing data is valid and current.
- Import a legacy JPEG when available.
- Request temporary local video availability only when required.
- Remember the video's availability state before repair.
- Invoke `ThumbnailGenerator`.
- Save data, generation version, and generation date in one context transaction.
- Restore cloud-only state when appropriate.
- Schedule bounded retries through the existing processing queue.
- Reconcile thumbnails after CloudKit imports and library startup.

Repair work is serial by default. This prevents several large cloud-only videos from downloading at once. The coordinator supports cancellation between download, generation, save, and eviction stages.

### `ThumbnailImageCache`

The image cache is a display-layer service.

- Decode JPEG data off the main thread.
- Cache platform images using video ID plus generation version.
- Coalesce simultaneous decode requests for the same key.
- Invalidate a cached value when thumbnail data or generation version changes.
- Purge decoded images under memory pressure without altering persisted data.

Views do not resolve thumbnail file URLs directly after migration. They request an image from this cache/provider and show the existing placeholder while data is unavailable.

## New import flow

1. Import or download the video to a locally accessible staging URL.
2. Extract video metadata.
3. Generate version-1 thumbnail JPEG data.
4. Create or update the `Video` object with `thumbnailData`, `thumbnailGenerationVersion`, and `thumbnailGeneratedAt`.
5. Save the Core Data context.
6. Allow `NSPersistentCloudKitContainer` to export the record and binary payload.
7. Apply the selected video storage policy. The video may upload or become cloud-only independently of the persisted thumbnail.

If thumbnail generation fails, the video import may still complete, but it must enqueue a visibly failed/retryable thumbnail task rather than silently treating thumbnail work as successful.

## Receiving-device flow

1. Core Data/CloudKit imports the `Video` record and its binary thumbnail payload into the local replica.
2. The view context merges the imported change.
3. Thumbnail views observe the data/version change and refresh through `ThumbnailImageCache`.
4. The device retains the externally stored thumbnail data locally even if video storage optimisation leaves the video cloud-only.
5. Displaying a thumbnail never requests the video file.

Reconciliation waits until the initial CloudKit import event completes before treating absent binary data as a repair candidate. This prevents unnecessary video downloads while the thumbnail asset may still be arriving.

## Legacy migration and repair flow

For each video whose thumbnail data is missing, corrupt, or older than the current generation version:

1. If a readable legacy JPEG exists at `thumbnailPath`, validate it and import its bytes into `thumbnailData` without downloading the video.
2. Otherwise, inspect and remember the video's current availability state.
3. Request local availability through `VideoFileManager`. This may temporarily download a cloud-only video.
4. Generate and validate the new JPEG.
5. Save thumbnail data, version, and generation date.
6. If the video was cloud-only before repair and the library uses storage optimisation, evict the temporary local copy after the save succeeds.
7. If cancellation or failure occurs before a valid save, preserve the source video and enqueue/retry the thumbnail operation. Do not evict as part of failure cleanup unless the coordinator can prove the video was originally cloud-only and remains safely uploaded.

Migration runs in small serial batches after library startup and after a successful CloudKit import event. A video with valid current-version data requires no work. Existing JPEG files and path fields remain untouched during the first migration release as a rollback mechanism.

## Legacy-code cleanup boundary

Once binary thumbnail generation, migration, and display are working, remove the old operational implementation rather than leaving two thumbnail systems active:

- Remove path-based generation and JPEG writing from `FileSystemManager`.
- Remove `Video.thumbnailURL`, `Folder.projectThumbnailURL`, and path-based descendant cover resolution from runtime display code.
- Remove startup and queue completion checks based on `thumbnailPath`.
- Remove the unconditional `generateThumbnail -> ensureLocalAvailability` task dependency; `ThumbnailCoordinator` decides whether video access is required after checking binary and legacy JPEG data.
- Remove path-based thumbnail deletion and stop creating `Thumbnails` for new libraries.
- Remove obsolete path helper functions and their tests.
- Replace all `AsyncImage` thumbnail-file consumers with the shared binary-data provider.

Retain only the legacy Core Data fields, existing JPEG files, and a narrowly scoped migration reader during this release. Legacy code must not write new thumbnail paths or serve thumbnails to normal runtime views. A repository-wide final audit must prove there are no remaining operational references outside migration code and migration tests.

## Project artwork

Project artwork resolves in this order:

1. The descendant video identified by `projectThumbnailVideoID`, while it remains in the project and has valid thumbnail data.
2. During migration, a descendant video whose legacy `thumbnailPath` matches the project's `projectThumbnailPath`; persist its ID.
3. The first descendant video with valid thumbnail data.
4. The existing project placeholder.

When fallback selects the first valid descendant, persist that video's ID so cover selection remains stable as titles and folder contents change. The implementation must not persist a new filesystem thumbnail path.

## Failure handling and task semantics

- Thumbnail generation errors propagate to the processing task.
- A thumbnail task succeeds only after non-empty, decodable, current-version data is saved.
- `thumbnailData == nil`, invalid data, or an old generation version all mean work is incomplete.
- Existing task completion checks must stop relying on `thumbnailPath != nil`.
- Transient iCloud download and CloudKit availability failures use bounded retries with backoff.
- Permanent media decoding errors remain visible in the processing UI and may be retried manually.
- The coordinator records stage-specific status: waiting for CloudKit import, downloading video, generating, saving, restoring storage state, or failed.
- Simultaneous repair requests for the same video are coalesced.

## Display behaviour

All thumbnail consumers use the shared binary-data provider:

- Project grid cards and project hero artwork
- Search results
- Video result tables
- Folder rows
- Player poster views
- Any cloud/file status views that currently load the thumbnail URL

Views show a placeholder only while no valid local thumbnail data exists. They do not call `startDownloadingUbiquitousItem` for thumbnails and do not test legacy thumbnail file existence once a video has migrated.

## Testing

### Unit tests

- Frame selection is 10% of duration capped at 5 seconds.
- Generated output is a valid JPEG no larger than 640×360 and is not upscaled.
- Current valid data requires no work.
- Invalid, empty, and old-version data require repair.
- A valid legacy JPEG migrates without requesting the video.
- Missing legacy data causes a cloud-only video to become temporarily local.
- A successful repair restores an originally cloud-only video when optimisation is enabled.
- A locally retained video is not evicted after repair.
- Failure before save does not evict the source video.
- Cancellation preserves safe source availability.
- Duplicate repair requests coalesce.
- Task completion requires valid current-version binary data.
- Project artwork preserves a legacy path match and otherwise falls back predictably.
- Image cache keys and invalidation include generation version.

### Migration tests

- The existing store migrates with optional/defaulted fields.
- Existing videos and project metadata remain intact.
- Existing project thumbnail paths resolve to and persist the matching descendant video ID.
- Legacy files remain on disk after migration.
- Reopening an already migrated library is idempotent.

### Integration and manual verification

- macOS and iOS builds and focused thumbnail tests pass.
- Import a new video, wait for CloudKit export, offload the video, and confirm its thumbnail remains visible.
- On a second device, confirm the thumbnail appears and remains offline without downloading the video.
- For a legacy cloud-only video with no JPEG, confirm temporary download, generation, CloudKit export, and re-eviction.
- Disable networking during each repair stage and verify retry/status behaviour.
- Confirm project, search, folder, result-table, and player-poster consumers update after CloudKit import.

## Completion criteria

- New thumbnails synchronise through the mirrored Core Data record, not the `Thumbnails` ubiquity directory.
- A cloud-only video can display its locally retained thumbnail without accessing the video file.
- A second device obtains the thumbnail through CloudKit without downloading the video.
- Legacy cloud-only videos repair automatically using a temporary video download only when no usable thumbnail is otherwise available.
- Repair tasks are serial, retryable, cancellable, and accurately reported.
- Project artwork continues to resolve from descendant videos.
- Legacy thumbnail fields and files remain available for rollback in the migration release.
- Old path-based runtime generation, display, queue, deletion, and new-library directory code has been removed; only the migration reader and legacy schema fields remain.
