# Library View Routing

## Summary

Library navigation now uses a single sidebar destination model for:

- `Search`
- `All videos`
- `Recent`
- `Favorites`
- user folders
- videos

`Search` and smart collections are routed as virtual destinations in UI state. Persisted Core Data smart folders remain for backwards compatibility, but the sidebar UI and detail routing no longer depend on them.

## Core Types

- `LibrarySidebarDestination` (`Pangolin/Stores/FolderNavigationStore.swift`)
  - `.search`
  - `.smartCollection(SmartCollectionKind)`
  - `.folder(Folder)`
  - `.video(Video)`
- `SmartCollectionKind` (`Pangolin/Models/SmartCollectionKind.swift`)
  - centralizes titles, sidebar icons, and query rules
- `LibraryDetailSurface` (`Pangolin/Stores/FolderNavigationStore.swift`)
  - derived routing surface for the detail column

## Sidebar Rendering

`SidebarView` renders:

- a virtual `Search` row
- virtual smart collection rows from `SmartCollectionKind.allCases`
- user folders from Core Data (`store.userFolders()`)

Persisted smart folders are no longer fetched for sidebar display.

## Detail Routing

`DetailColumnView` switches on `folderStore.currentDetailSurface`:

- `searchResults` -> `SearchResultsView`
- `smartCollectionTable` -> `FolderContentView` (smart collection mode)
- `folderOutline` -> `FolderContentView` (outline mode)
- `videoDetail` -> `DetailView`
- `empty` -> empty state

## Content Loading

`FolderNavigationStore.refreshContent()` delegates data loading to `LibraryContentProvider`:

- `loadSmartCollection(_:library:context:)`
- `loadFolderContent(folderID:library:context:)`

This removes smart-folder query logic from the store and avoids repeated string switches.

## Compatibility Notes

- `LibraryManager` still creates/ensures persisted smart folders for existing libraries.
- These persisted smart folders are considered legacy compatibility artifacts for now.
- UI routing/display should prefer `SmartCollectionKind`.
