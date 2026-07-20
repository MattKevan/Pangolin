# Project Grid Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people rename or delete a project from its project-grid card's context menu.

**Architecture:** `ProjectsGridView` owns the one active inline editor, its draft text, and delete confirmation state. `ProjectCard` renders the context menu and accepts focused, explicit callbacks; persistence remains in `FolderNavigationStore` through its existing rename and deletion APIs. A small policy type in `ProjectsView.swift` makes title-save decisions testable without UI automation.

**Tech Stack:** SwiftUI, Core Data, Swift Testing, Xcode.

---

### Task 1: Define and test project-title save policy

**Files:**
- Modify: `PangolinTests/ProjectsStoreTests.swift`
- Modify: `Pangolin/Views/ProjectsView.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Project title save policy trims changed titles and rejects empty or unchanged input")
func projectRenamePolicyReturnsOnlyMeaningfulTitles() {
    #expect(ProjectRenamePolicy.savedTitle(draft: "  New Name  ", current: "Old Name") == "New Name")
    #expect(ProjectRenamePolicy.savedTitle(draft: "   ", current: "Old Name") == nil)
    #expect(ProjectRenamePolicy.savedTitle(draft: "Old Name", current: "Old Name") == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/ProjectsStoreTests`

Expected: FAIL because `ProjectRenamePolicy` does not exist.

- [ ] **Step 3: Add the minimal policy**

```swift
enum ProjectRenamePolicy {
    static func savedTitle(draft: String, current: String) -> String? {
        let trimmedTitle = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != current else { return nil }
        return trimmedTitle
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/ProjectsStoreTests`

Expected: PASS with the new policy test and all existing `ProjectsStoreTests` passing.

### Task 2: Add inline rename and confirmed deletion to project cards

**Files:**
- Modify: `Pangolin/Views/ProjectsView.swift`

- [ ] **Step 1: Give the grid one rename editor and one deletion alert**

Add `@State` properties for the active project ID, draft title, selected deletion item, and alert visibility, plus a `@FocusState` project ID. Pass the related bindings and actions into each `ProjectCard`.

- [ ] **Step 2: Add the card context menu and inline title editor**

Add a context menu to `ProjectCard` with `Rename` and destructive `Delete` actions. When its project is the active editor, replace only its title `Text` with a focused plain `TextField`; Return and focus loss call the save action, while Escape calls cancel.

- [ ] **Step 3: Connect persistence and cleanup**

Start rename by copying `resolvedProjectTitle` into the draft and focusing on the next main-actor turn. Save only the `ProjectRenamePolicy` result through `store.renameItem(id:to:)`; cancel clears the editor state. On delete confirmation, call `store.deleteItems([projectID])` and clear local alert/editor state when the store reports success.

- [ ] **Step 4: Build and run the focused test suite**

Run: `xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/ProjectsStoreTests`

Expected: PASS, confirming the behavior compiles with the project persistence test suite.

### Task 3: Verify the complete application target

**Files:**
- Modify: `Pangolin/Views/ProjectsView.swift`
- Modify: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Inspect the final diff**

Run: `git diff --check HEAD && git diff -- Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift`

Expected: no whitespace errors; the diff is limited to project-grid behavior and its policy test.

- [ ] **Step 2: Build the app**

Run: `xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit the feature**

Run: `git add Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift` followed by `git commit -m "feat: add project grid actions"`.

Expected: a commit containing the context menu, inline rename interaction, deletion confirmation, and policy coverage.
