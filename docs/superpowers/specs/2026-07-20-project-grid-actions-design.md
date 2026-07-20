# Project Grid Rename and Delete Design

## Scope

Add project-specific actions to cards in the project grid. Projects support inline title editing and confirmed deletion. Project metadata editing is explicitly out of scope; metadata editing is reserved for videos.

## Interaction

Each project card has a native context menu with two actions:

- **Rename** replaces the card title with a focused inline text field. Return or loss of focus saves a non-empty changed title. Escape cancels. Empty or unchanged input restores the displayed title without saving.
- **Delete** opens the existing destructive confirmation alert. Confirming deletion uses the store's existing project/folder deletion operation; cancelling leaves the project unchanged.

The grid owns the active project ID and draft title so only one project can be renamed at a time. The card receives bindings and action closures, keeping persistence in the existing `FolderNavigationStore`.

## Data Flow

Renaming calls `FolderNavigationStore.renameItem(id:to:)`, which already keeps a project's folder name and project title synchronized. Deletion calls `FolderNavigationStore.deleteItems(_:)` with the project's ID. A successful deletion clears transient rename or deletion state for that project.

## Error and Safety Behavior

Deletion always requires confirmation and uses the established messaging that explains the project's contents are permanently removed. Store failures continue to use the store's existing error reporting and leave the grid usable. A project without a stable UUID does not expose persistence actions.

## Testing

Add focused tests for any extracted rename-state policy, including trimming, empty input, unchanged input, save, and cancel behavior. Reuse existing store tests for rename and deletion persistence, then compile the app and run the relevant project test target.
