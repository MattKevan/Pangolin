# Project Video Thumbnail Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace project-detail video rows with a sectioned thumbnail grid on every platform, with reliable native macOS multiselection and touch-first iOS/iPadOS selection.

**Architecture:** Keep project ordering, filtering, and selected UUIDs in `FolderNavigationStore`. Extract pure layout and interaction policies for test-first coverage. Render SwiftUI card content on every platform; iOS/iPadOS renders it in a `LazyVGrid`, while macOS hosts it in an `NSCollectionView` so the operating system owns multiselection, keyboard navigation, and double-click activation.

**Tech Stack:** SwiftUI, AppKit `NSCollectionView`, Core Data `Video`, Swift Testing, Xcode.

---

## File structure

- Modify `Pangolin/Views/ProjectsView.swift`: replace the existing project row list/scroll variants with the common project-grid shell and keep hero, filtering, toolbar, deletion, and navigation wiring.
- Create `Pangolin/Views/Components/ProjectVideoGrid.swift`: shared layout and touch-grid/card SwiftUI implementation.
- Create `Pangolin/Views/Components/MacProjectVideoCollectionView.swift`: narrow AppKit collection bridge for native macOS selection and activation.
- Modify `PangolinTests/ProjectsStoreTests.swift`: exercise the new pure layout, touch-selection, and activation policies.

### Task 1: Define testable grid and interaction policies

**Files:**

- Modify: `Pangolin/Views/ProjectsView.swift:256-284`
- Test: `PangolinTests/ProjectsStoreTests.swift:31-75`

- [ ] **Step 1: Write failing policy tests**

```swift
@Test("Project video grid keeps two columns in compact and regular layouts")
func projectVideoGridColumnPolicyKeepsMinimumOfTwoColumns() {
    #expect(ProjectVideoGridLayout.columnCount(availableWidth: 300, isCompact: true) == 2)
    #expect(ProjectVideoGridLayout.columnCount(availableWidth: 300, isCompact: false) == 2)
    #expect(ProjectVideoGridLayout.columnCount(availableWidth: 800, isCompact: false) > 2)
}

@Test("Touch video interactions open, begin selection, and toggle predictably")
func projectTouchInteractionPolicy() {
    let id = UUID()
    #expect(ProjectVideoTouchInteractionPolicy.tap(id, selection: [], isSelecting: false) == .open(id))
    #expect(ProjectVideoTouchInteractionPolicy.longPress(id, selection: []) == .selecting([id]))
    #expect(ProjectVideoTouchInteractionPolicy.tap(id, selection: [id], isSelecting: true) == .selecting([]))
}

@Test("Project video activation requires one visible selection")
func projectGridActivationRequiresExactlyOneVisibleSelection() {
    let first = UUID()
    let second = UUID()
    #expect(ProjectVideoActivationPolicy.videoID(selection: [first], visibleIDs: [first, second]) == first)
    #expect(ProjectVideoActivationPolicy.videoID(selection: [first, second], visibleIDs: [first, second]) == nil)
}
```

- [ ] **Step 2: Run the focused test bundle and verify it fails because the new policy types do not exist**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests`

Expected: compilation fails with unresolved `ProjectVideoGridLayout`, `ProjectVideoTouchInteractionPolicy`, and `ProjectVideoActivationPolicy`.

- [ ] **Step 3: Add minimal pure policies**

```swift
enum ProjectVideoGridLayout {
    static let spacing: CGFloat = ProjectGridLayout.spacing
    static let minimumRegularCardWidth: CGFloat = 180

    static func columnCount(availableWidth: CGFloat, isCompact: Bool) -> Int {
        guard !isCompact else { return 2 }
        return max(2, Int((availableWidth + spacing) / (minimumRegularCardWidth + spacing)))
    }
}

enum ProjectVideoActivationPolicy {
    static func videoID(selection: Set<UUID>, visibleIDs: Set<UUID>) -> UUID? {
        guard selection.count == 1, let id = selection.first, visibleIDs.contains(id) else { return nil }
        return id
    }
}

enum ProjectVideoTouchInteraction: Equatable {
    case open(UUID)
    case selecting(Set<UUID>)
}

enum ProjectVideoTouchInteractionPolicy {
    static func tap(_ id: UUID, selection: Set<UUID>, isSelecting: Bool) -> ProjectVideoTouchInteraction {
        guard isSelecting else { return .open(id) }
        var next = selection
        if !next.insert(id).inserted { next.remove(id) }
        return .selecting(next)
    }

    static func longPress(_ id: UUID, selection: Set<UUID>) -> ProjectVideoTouchInteraction {
        .selecting(selection.union([id]))
    }
}
```

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests`

Expected: `ProjectVideoGridLayout`, touch interaction, and single-selection activation tests pass.

- [ ] **Step 5: Commit the policies and their tests**

```bash
git add Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "test: define project video grid interactions"
```

### Task 2: Build shared thumbnail card and touch grid

**Files:**

- Create: `Pangolin/Views/Components/ProjectVideoGrid.swift`
- Modify: `Pangolin/Views/ProjectsView.swift:584-764`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Write a failing visibility/selection test**

```swift
@Test("Project grid reconciliation drops selections hidden by filtering")
func projectGridReconciliationDropsHiddenSelections() {
    let visible = UUID()
    let hidden = UUID()
    #expect(ProjectVideoSelectionPolicy.reconciledSelection([visible, hidden], visibleIDs: [visible]) == [visible])
}
```

- [ ] **Step 2: Run the focused test and confirm it initially passes only after retaining the existing reconciliation policy**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests`

Expected: the existing selection reconciliation test remains green; do not alter this behavior while replacing the UI.

- [ ] **Step 3: Create the shared card and touch grid**

```swift
struct ProjectVideoCardContent: View {
    let video: Video
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VideoThumbnailView(video: video, size: .zero)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            Text(video.title ?? video.fileName ?? "Untitled")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Label(video.watchStatus.displayName, systemImage: watchStatusSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .clipShape(.rect(cornerRadius: 8))
    }
}
```

Implement `ProjectVideoGrid` as a `ScrollView` containing a `LazyVGrid` for each `ProjectSectionSnapshot`. Use a `GeometryReader` only to calculate the grid column count once per container. Use stable `video.id` identity, call the supplied `onOpen` closure for normal touch taps, and apply the touch interaction policy to long press/toggle behavior. Include card accessibility labels and selected traits. Replace iOS/iPadOS `sectionListContent` with this component while preserving project search, context actions, deletion alert, and hero.

- [ ] **Step 4: Build the iOS target**

Run: `xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ProjectGrid-iOS build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit the shared grid**

```bash
git add Pangolin/Views/Components/ProjectVideoGrid.swift Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "feat: show project videos in thumbnail grids"
```

### Task 3: Add native macOS collection selection and activation

**Files:**

- Create: `Pangolin/Views/Components/MacProjectVideoCollectionView.swift`
- Modify: `Pangolin/Views/ProjectsView.swift:583-703`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Write failing delegate-policy tests**

```swift
@Test("Mac collection double click opens only a singly selected visible video")
func macCollectionDoubleClickActivationPolicy() {
    let id = UUID()
    #expect(MacProjectVideoCollectionPolicy.activatedID(clickedID: id, selection: [id], visibleIDs: [id]) == id)
    #expect(MacProjectVideoCollectionPolicy.activatedID(clickedID: id, selection: [], visibleIDs: [id]) == nil)
    #expect(MacProjectVideoCollectionPolicy.activatedID(clickedID: id, selection: [id, UUID()], visibleIDs: [id]) == nil)
}
```

- [ ] **Step 2: Run the focused test and verify it fails because `MacProjectVideoCollectionPolicy` does not exist**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests`

Expected: compilation fails with unresolved `MacProjectVideoCollectionPolicy`.

- [ ] **Step 3: Implement the narrow AppKit bridge**

```swift
enum MacProjectVideoCollectionPolicy {
    static func activatedID(clickedID: UUID, selection: Set<UUID>, visibleIDs: Set<UUID>) -> UUID? {
        guard selection == [clickedID], visibleIDs.contains(clickedID) else { return nil }
        return clickedID
    }
}

struct MacProjectVideoCollectionView: NSViewRepresentable {
    let sections: [ProjectSectionSnapshot]
    @Binding var selection: Set<UUID>
    let onOpen: (Video) -> Void
    // makeNSView configures an NSCollectionViewFlowLayout and an NSScrollView.
    // The coordinator maps item index paths to videos, mirrors selection changes,
    // and invokes onOpen from collectionView(_:didDoubleClickItemAt:) and Return.
}
```

Use `NSCollectionViewFlowLayout` with a minimum 180-point card width and 22-point spacing. Give each section an `NSCollectionViewSupplementaryView` heading. Register an item whose `NSHostingView` root is `ProjectVideoCardContent`. Enable multiple selection. In `collectionView(_:didSelectItemsAt:)` and `didDeselectItemsAt:`, write the UUID set back to the binding. In `keyDown`, send Return through the exactly-one-selection policy. In the double-click delegate, send the clicked UUID through `MacProjectVideoCollectionPolicy` and call `onOpen` directly. Synchronize externally changed bindings back to `collectionView.selectionIndexPaths` without feedback loops.

Replace `macProjectDetail`’s `List`, `contextMenu(forSelectionType:)`, `primaryAction`, and `onKeyPress` with the bridge. Keep the hero above the collection content and keep the existing project toolbar/search/deletion sheets in `ProjectDetailView`.

- [ ] **Step 4: Run macOS tests and build**

Run: `xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test`

Expected: `TEST SUCCEEDED`.

Run: `xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit the macOS collection bridge**

```bash
git add Pangolin/Views/Components/MacProjectVideoCollectionView.swift Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "feat: use native project video grid selection on macOS"
```

### Task 4: Verify cross-platform behavior and accessibility

**Files:**

- Modify: `Pangolin/Views/Components/ProjectVideoGrid.swift`
- Modify: `Pangolin/Views/Components/MacProjectVideoCollectionView.swift`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Add accessibility assertions to the focused policy tests**

```swift
@Test("Project video grid card accessibility text includes state metadata")
func projectVideoGridAccessibilityLabel() {
    #expect(ProjectVideoCardAccessibility.label(title: "Lecture", watchState: "Unwatched", duration: "12:30", availability: "In iCloud") == "Lecture, Unwatched, 12:30, In iCloud")
}
```

- [ ] **Step 2: Run the test and verify it fails because the accessibility helper does not exist**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests`

Expected: compilation fails with unresolved `ProjectVideoCardAccessibility`.

- [ ] **Step 3: Add the accessibility helper and apply it to both card hosts**

```swift
enum ProjectVideoCardAccessibility {
    static func label(title: String, watchState: String, duration: String, availability: String) -> String {
        [title, watchState, duration, availability].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
```

Use the helper in the SwiftUI card’s `accessibilityLabel`, selected trait, and hint. Mark duplicate duration and cloud overlays hidden from accessibility. Use the same label as the AppKit collection item’s accessibility label. Mark section supplementary headings as headings.

- [ ] **Step 4: Run all required verification**

Run: `xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test`

Expected: `TEST SUCCEEDED`.

Run: `xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ProjectGrid-iOS build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manually verify interaction behavior**

On macOS, open a multi-section project and verify click, Command-click, Shift-click, arrows, Return, double-click, filtering, inactive selection, and the context menu. On iPhone and iPad, verify two/regular-width columns, tap opening, long-press selection, selection toggling, clearing selection, and VoiceOver labels.

- [ ] **Step 6: Commit final accessibility work**

```bash
git add Pangolin/Views/Components/ProjectVideoGrid.swift Pangolin/Views/Components/MacProjectVideoCollectionView.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "test: cover project video grid accessibility"
```
