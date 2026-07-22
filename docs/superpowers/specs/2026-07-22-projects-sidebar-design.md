# Projects sidebar design

## Goal

Make existing top-level projects directly navigable in the macOS sidebar, while preserving the project grid as an alternate presentation. Make the background-activity popover able to show every active task and file transfer.

## Sidebar

- Add a `Projects` `Section` beneath the existing sidebar collections.
- Use SwiftUI `List` selection and `NavigationLink`-style row semantics so projects behave like native Music playlists or Books collections.
- Source the rows from the same top-level project query the grid uses; do not duplicate project state.
- Selecting a row opens the existing project-detail route through `FolderNavigationStore`.
- Make the full Projects section a drop target. Dropping a folder uses the existing project-creation path used by the project grid, including security-scoped access and its folder/video import behavior.
- Give each row the existing project actions: Open, Rename, and Delete. Delete uses the grid's existing confirmation and destructive behavior, including removal of project contents and files.

## Activity popover

- Preserve active processing tasks, file-transfer rows, CloudKit status, and failure controls.
- Place the list of activity rows in a vertical `ScrollView` with a bounded height so all items are available instead of truncating to a fixed prefix.
- Keep actions pinned below the scrolling content.

## Data flow and safety

- Keep selection/navigation in `FolderNavigationStore`.
- Reuse existing project mutation methods rather than issuing a second Core Data implementation from the sidebar.
- Preserve stable project identifiers in `ForEach` and use native context menus and alerts for accessibility.

## Validation

- Verify selecting a sidebar project opens its existing detail view.
- Verify a folder drop creates and selects a project.
- Verify Rename and Delete match grid behavior, including delete confirmation.
- Verify a large import exposes all processing and transfer rows in the activity popover.
