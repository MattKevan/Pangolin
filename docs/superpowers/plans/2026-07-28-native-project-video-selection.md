# Native Project Video Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make project-detail video selection and activation use native AppKit and UIKit collection behavior.

**Architecture:** `ProjectDetailView` keeps route, toolbar, and action ownership while platform representables own collection interaction. Stable video UUIDs cross the bridge through one selection binding, and shared SwiftUI card content is hosted in reusable native items or cells.

**Tech Stack:** Swift 5, SwiftUI, AppKit `NSCollectionView`, UIKit `UICollectionView`, Swift Testing, Xcode 26.

---

### Task 1: Define Native Interaction Policies

**Files:**
- Modify: `Pangolin/Views/ProjectsView.swift`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Write the failing iOS editing-selection test**

```swift
@Test("Native iOS project collection opens outside editing and selects while editing")
func nativeIOSProjectCollectionInteractionPolicy() {
    let id = UUID()

    #expect(IOSProjectVideoCollectionPolicy.interaction(
        for: id,
        selection: [],
        isEditing: false
    ) == .open(id))
    #expect(IOSProjectVideoCollectionPolicy.interaction(
        for: id,
        selection: [],
        isEditing: true
    ) == .selecting([id]))
    #expect(IOSProjectVideoCollectionPolicy.interaction(
        for: id,
        selection: [id],
        isEditing: true
    ) == .selecting([]))
}
```

- [ ] **Step 2: Run the test and verify the missing policy fails**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/PangolinCodexDerivedData test -only-testing:PangolinTests/ProjectsStoreTests/nativeIOSProjectCollectionInteractionPolicy
```

Expected: compilation fails because `IOSProjectVideoCollectionPolicy` does not exist.

- [ ] **Step 3: Add the minimal policy**

```swift
enum IOSProjectVideoCollectionPolicy {
    static func interaction(
        for id: UUID,
        selection: Set<UUID>,
        isEditing: Bool
    ) -> ProjectVideoTouchInteraction {
        guard isEditing else { return .open(id) }
        var next = selection
        if !next.insert(id).inserted {
            next.remove(id)
        }
        return .selecting(next)
    }
}
```

- [ ] **Step 4: Run the focused policy tests**

Expected: the new test and existing macOS activation policy tests pass.

### Task 2: Restore the Native macOS Collection

**Files:**
- Modify: `Pangolin/Views/Components/MacProjectVideoCollectionView.swift`
- Modify: `Pangolin/Views/ProjectsView.swift`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Make the bridge synchronize without reloading on selection-only changes**

Track a stable section signature in the coordinator. Reload only when the visible section/video identity changes, then synchronize `selectionIndexPaths` under an `isSynchronizingSelection` guard.

```swift
func updateParent(_ parent: MacProjectVideoCollectionView) {
    self.parent = parent
    if contentSignature != nextContentSignature {
        contentSignature = nextContentSignature
        collectionView?.reloadData()
    }
    synchronizeSelection()
}
```

- [ ] **Step 2: Resolve activation from native selection**

After `super.mouseDown(with:)`, use the collection view's current `selectionIndexPaths` for double-click validation. This prevents a SwiftUI binding update from becoming part of click recognition.

```swift
override func mouseDown(with event: NSEvent) {
    let clicked = indexPathForItem(at: convert(event.locationInWindow, from: nil))
    super.mouseDown(with: event)
    if event.clickCount == 2, let clicked {
        onDoubleClick?(clicked)
    }
}
```

- [ ] **Step 3: Replace the macOS SwiftUI grid in `ProjectDetailView`**

Render the existing hero, `MacProjectVideoCollectionView`, and footer in a vertical detail layout. Bind directly to `store.selectedProjectVideoIDs` and forward `onOpen` to `store.openProjectVideo(_:in:)`.

- [ ] **Step 4: Run macOS policy tests and build**

Expected: macOS compiles with no SwiftUI card tap or drag recognizer in the active project-detail path.

### Task 3: Add Native iOS Collection Editing

**Files:**
- Modify: `Pangolin/Views/Components/ProjectVideoGrid.swift`
- Modify: `Pangolin/Views/ProjectsView.swift`
- Test: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Add `IOSProjectVideoCollectionView`**

Create a `UIViewRepresentable` backed by a vertically scrolling `UICollectionViewFlowLayout`. Configure:

```swift
collectionView.allowsSelection = true
collectionView.allowsMultipleSelection = false
collectionView.allowsSelectionDuringEditing = true
collectionView.allowsMultipleSelectionDuringEditing = true
```

Host `ProjectVideoCardContent` with `UIHostingConfiguration`, use reusable section headers, and synchronize native selected index paths with the UUID binding.

- [ ] **Step 2: Separate activation from editing selection**

In `didSelectItemAt`, open and immediately deselect outside editing mode. In editing mode, publish the native selected UUID set.

```swift
if collectionView.isEditing {
    publishSelection()
} else {
    parent.onOpen(video)
    collectionView.deselectItem(at: indexPath, animated: false)
}
```

- [ ] **Step 3: Enable native two-finger selection**

```swift
func collectionView(
    _ collectionView: UICollectionView,
    shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath
) -> Bool {
    video(at: indexPath).id != nil
}

func collectionView(
    _ collectionView: UICollectionView,
    didBeginMultipleSelectionInteractionAt indexPath: IndexPath
) {
    parent.onEditingChanged(true)
}
```

- [ ] **Step 4: Connect SwiftUI edit mode**

Pass `isSelectingProjectVideos` into the representable and update the SwiftUI edit-mode binding when UIKit starts native multiple selection. Add `EditButton` to the phone toolbar as well as the iPad toolbar.

- [ ] **Step 5: Keep long press for context actions**

Provide `UIContextMenuConfiguration` actions for favourite, edit, and delete. Do not use long press to enter selection.

- [ ] **Step 6: Build the iOS Simulator target**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PangolinCodexDerivedData-ios CODE_SIGNING_ALLOWED=NO build
```

Expected: build succeeds.

### Task 4: Verify Native Behavior and Regressions

**Files:**
- Modify: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Run all `ProjectsStoreTests`**

Resolve the existing project-video column expectations by keeping video cards at the intended 180-point minimum width, independent from project artwork cards.

- [ ] **Step 2: Run the complete macOS test suite**

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -derivedDataPath /tmp/PangolinCodexDerivedData test
```

- [ ] **Step 3: Build both application targets**

Run the macOS build and generic iOS Simulator build. Record any unrelated existing warnings separately.

- [ ] **Step 4: Review the diff**

Confirm there is one selection binding, no platform interaction in `ProjectVideoCardContent`, no macOS marquee `DragGesture`, no iOS long-press selection, and no unrelated refactor.
