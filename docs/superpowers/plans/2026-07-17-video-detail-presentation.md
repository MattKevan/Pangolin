# Video Detail Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present video details without the library sidebar, restore the correct originating surface on Back, replace the toolbar for the video route, and align the page to one centred 760-point column with an adaptive header surface.

**Architecture:** Keep the existing `NavigationSplitView`, but bind its visibility to route state so video details force `.detailOnly` while library surfaces retain user-controlled visibility. `FolderNavigationStore` records a typed origin before entering video detail and restores it atomically on Back. `DetailView` owns a shared layout metric used by the player, title, tabs, transcript, and summary.

**Tech Stack:** Swift 5, SwiftUI, Core Data, Swift Testing, Xcode 26.

---

## File Map

- Modify `Pangolin/Stores/FolderNavigationStore.swift`: record and restore video presentation origins.
- Modify `PangolinTests/VideoNavigationSequenceTests.swift`: cover course, collection, search, neighbor, and fallback Back behavior.
- Modify `Pangolin/Views/MainView.swift`: force detail-only split visibility and compose route-specific toolbars.
- Modify `Pangolin/Views/DetailView.swift`: define shared layout metrics, adaptive surfaces, aligned content, and compact title actions.
- Modify `Pangolin/Views/Components/SummaryView.swift`: align summary content to the shared video-detail column.
- Modify `Pangolin/Utilities/Color+App.swift`: provide semantic video header and content surface colors.

### Task 1: Restore Video Navigation Origins

**Files:**
- Modify: `PangolinTests/VideoNavigationSequenceTests.swift`
- Modify: `Pangolin/Stores/FolderNavigationStore.swift`

- [ ] **Step 1: Write failing course-origin and neighbor-preservation tests**

Add tests that open a project video, move to its neighbor with `selectVideo(_:)`, call `navigateBackFromDetail()`, and expect `.projects`, the same `selectedProject`, no selected video, and `.projectDetail`.

```swift
@Test("Back from a project video restores its course")
@MainActor
func backFromProjectVideoRestoresCourse() async throws {
    let (manager, context, tempRoot) = try await makeLibraryContext()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let library = try requireLibrary(from: manager)
    let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
    let section = try makeFolder(named: "Module", in: context, parent: project, library: library)
    let first = try makeVideo(title: "One", thumbnailPath: nil, in: context, folder: section, library: library)
    let second = try makeVideo(title: "Two", thumbnailPath: nil, in: context, folder: section, library: library)
    try context.save()
    let store = FolderNavigationStore(libraryManager: manager)

    store.openProjectVideo(first, in: project)
    store.selectVideo(second)
    store.navigateBackFromDetail()

    #expect(store.selectedVideo == nil)
    #expect(store.selectedSidebarItem == .projects)
    #expect(store.selectedProject?.objectID == project.objectID)
    #expect(store.currentDetailSurface == .projectDetail)
}
```

- [ ] **Step 2: Write failing smart-collection, search, and fallback tests**

Set the originating destination before `openVideoDetailWithoutLocation(_:)`, then expect Back to restore `.smartCollection(.favorites)` or `.search`. For the fallback, clear the destination before opening an orphan and expect `.projects` and `.projectsGrid`.

```swift
store.selectedSidebarItem = .smartCollection(.favorites)
store.openVideoDetailWithoutLocation(video)
store.navigateBackFromDetail()
#expect(store.selectedSidebarItem == .smartCollection(.favorites))
#expect(store.currentDetailSurface == .smartCollectionTable(.favorites))

store.activateSearch()
store.openVideoDetailWithoutLocation(video)
store.navigateBackFromDetail()
#expect(store.selectedSidebarItem == .search)
#expect(store.currentDetailSurface == .searchResults)

store.selectedSidebarItem = nil
store.openVideoDetailWithoutLocation(orphan)
store.navigateBackFromDetail()
#expect(store.selectedSidebarItem == .projects)
#expect(store.currentDetailSurface == .projectsGrid)
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoNavigationSequenceTests test
```

Expected: the new Back-origin assertions fail because the store only clears `selectedVideo` and does not restore the originating destination.

- [ ] **Step 4: Add the typed origin and capture helpers**

Add a private origin enum and state to `FolderNavigationStore`:

```swift
private enum VideoNavigationOrigin {
    case project(Folder)
    case sidebar(LibrarySidebarDestination)
}

private var videoNavigationOrigin: VideoNavigationOrigin?
```

Capture `.project` in `openProjectVideo`, capture the current search/smart/folder destination before `openVideoDetailWithoutLocation` clears it, and capture `.search` before `openFromSearchCitation` reveals a location. Do not replace a recorded origin when `selectVideo(_:)` moves between neighboring videos.

- [ ] **Step 5: Restore the origin from `navigateBackFromDetail()`**

When a video is selected, clear it and consume `videoNavigationOrigin`. Restore projects with `openProject(_:)`, restore sidebar origins by assigning the saved destination with the existing callback-suppression rules, and use `.projects` as the fallback.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Task 1 test command again. Expected: `VideoNavigationSequenceTests` passes with zero failures.

- [ ] **Step 7: Commit navigation behavior**

```bash
git add Pangolin/Stores/FolderNavigationStore.swift PangolinTests/VideoNavigationSequenceTests.swift
git commit -m "Restore video detail navigation origins"
```

### Task 2: Make Video Detail a Detail-Only Route With Its Own Toolbar

**Files:**
- Modify: `Pangolin/Views/MainView.swift`
- Modify: `Pangolin/Views/DetailView.swift`

- [ ] **Step 1: Add route-driven split visibility**

Store the user-controlled non-video visibility in `MainView`:

```swift
@State private var libraryColumnVisibility: NavigationSplitViewVisibility = .all

private var rootColumnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
        get: { folderStore.showsVideoBackButton ? .detailOnly : libraryColumnVisibility },
        set: { if !folderStore.showsVideoBackButton { libraryColumnVisibility = $0 } }
    )
}
```

Pass this binding to `NavigationSplitView(columnVisibility:)` so the sidebar disappears immediately on the video route and returns with the prior library visibility.

- [ ] **Step 2: Split the toolbar by active route**

When `showsVideoBackButton` is true, render only the leading Back button and the existing background-task status control from `MainView`. Keep import controls and project Back behavior in the library branch. Leave transcript search and inspector toggle in `DetailView`, where they already follow the selected video tab.

- [ ] **Step 3: Remove the sidebar toggle and toolbar title for video detail**

Apply the macOS sidebar-toggle removal while `DetailView` is active and make `RootEventsModifier` return an empty navigation title for `.videoDetail`. The video-specific search remains the principal toolbar item.

- [ ] **Step 4: Build the app**

Run:

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **` with no Swift compile errors.

- [ ] **Step 5: Commit route presentation**

```bash
git add Pangolin/Views/MainView.swift Pangolin/Views/DetailView.swift
git commit -m "Present video details without the sidebar"
```

### Task 3: Align the Video Page and Apply Adaptive Surfaces

**Files:**
- Modify: `Pangolin/Views/DetailView.swift`
- Modify: `Pangolin/Views/Components/SummaryView.swift`
- Modify: `Pangolin/Utilities/Color+App.swift`

- [ ] **Step 1: Define shared metrics and semantic surfaces**

Add an internal layout definition with `contentMaxWidth = 760`, `horizontalPadding = 16`, and `compactActionSize = 34`. Add adaptive `appVideoHeaderBackground` and `appContentBackground` colors using `NSColor.windowBackgroundColor`/`controlBackgroundColor` on macOS and the corresponding secondary/system backgrounds on iOS.

- [ ] **Step 2: Rebuild the header around one centred column**

Make the header background span the available detail region. Inside it, constrain one `VStack` to 760 points; let the 16:9 player fill that stack and put the title/action row directly below it.

- [ ] **Step 3: Align tabs, transcript, summary, and navigation**

Wrap tabs in the same 760-point centred container. Move the `MergedTranscriptView` source label and paragraphs into one 760-point container instead of centring only the paragraph list. Give `SummaryView` the same outer constraint. Constrain the previous/next bar to the same column.

- [ ] **Step 4: Shrink the heart and ellipsis controls**

Render each symbol in a 34-point visible frame and retain at least a 44-point interaction region with transparent padding/content shape, accessibility labels, and the existing glass hover/focus treatment.

- [ ] **Step 5: Build and run focused tests**

Run:

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoNavigationSequenceTests test
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: tests pass and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit visual layout**

```bash
git add Pangolin/Views/DetailView.swift Pangolin/Views/Components/SummaryView.swift Pangolin/Utilities/Color+App.swift
git commit -m "Align and style the video detail page"
```

### Task 4: Full Verification

**Files:**
- Verify: all modified files

- [ ] **Step 1: Run all unit tests**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests test
```

Expected: all Pangolin unit tests pass with zero failures.

- [ ] **Step 2: Run a clean build check**

```bash
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Review the final diff against the spec**

Confirm there are no unrelated changes, no fixed light-only colors, and every video entry path records an origin. Confirm the header, tabs, transcript, summary, and navigation all reference the same 760-point layout metric.

- [ ] **Step 4: Record verification in the handoff**

Report the exact test/build commands, their results, the navigation behavior implemented, and any visual checks that still require launching the user’s populated library.
