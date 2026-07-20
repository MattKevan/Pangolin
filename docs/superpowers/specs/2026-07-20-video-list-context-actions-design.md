# Video List Context Actions Design

## Scope

Add video actions to the All Videos table and project-detail video list. macOS exposes actions through a right-click context menu; iOS exposes the same actions through the native long-press context menu.

## Interaction

For exactly one selected video, the menu offers:

- **Edit Video** opens a reusable adaptive sheet. The sheet lets the user edit the video title and favourite state, then save or cancel. Imported technical file metadata remains read-only and is not changed by this feature.
- **Delete Video** opens a destructive confirmation. Confirming permanently removes the video from the library and disk through the existing `FolderNavigationStore.deleteItems(_:)` operation.

The existing Open Video action in the macOS project list remains available. Multi-selection does not expose the edit or delete menu actions.

## Architecture

A focused `VideoMetadataEditor` view owns its draft title and favourite state and saves through the supplied `Video` managed object and library manager. The All Videos table and project detail each own presentation/deletion state because they already own selection state; both present the same editor and call the same deletion API.

## Safety and Error Handling

Saving rejects blank titles and leaves the sheet open. Cancelling discards unsaved drafts. Deletion always requires confirmation. Store failures use the existing store error-reporting path and leave the list usable.

## Testing

Add a pure metadata-save policy test for title trimming and empty-title rejection. Build the macOS app and run the focused project tests after implementing the cross-platform view code.
