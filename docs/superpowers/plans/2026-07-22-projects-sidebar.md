# Projects Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native selectable project rows, folder-drop creation, and project actions to the macOS sidebar, and make the activity popover scroll through every active item.

**Architecture:** `SidebarView` remains the selection owner and gains a `Projects` section powered by `FolderNavigationStore.projects()`. It reuses the existing `projectFolderDrop` modifier and store rename/delete APIs. `ProcessingPopoverView` places all activity rows in a bounded scroll view while keeping controls pinned below.

**Tech Stack:** SwiftUI `List`, `Section`, native context menus and alerts, Core Data-backed `Folder` objects, XCTest, XcodeGen.

---

### Task 1: Add sidebar project-selection coverage

**Files:**
- Modify: `PangolinTests/PangolinTests.swift`
- Modify: `Pangolin/Views/SidebarView.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testSidebarProjectSelectionPolicyOpensOnlyProjects() {
    XCTAssertTrue(SidebarProjectSelectionPolicy.canOpen(isProject: true))
    XCTAssertFalse(SidebarProjectSelectionPolicy.canOpen(isProject: false))
}
```

- [ ] **Step 2: Run the test and confirm it is red**

Run `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/testSidebarProjectSelectionPolicyOpensOnlyProjects test`.

Expected: compilation fails because the policy is undefined.

- [ ] **Step 3: Add the policy**

```swift
enum SidebarProjectSelectionPolicy {
    static func canOpen(isProject: Bool) -> Bool { isProject }
}
```

- [ ] **Step 4: Re-run the focused test**

Run the command from Step 2. Expected: PASS.

### Task 2: Add native project rows, drop support, and actions

**Files:**
- Modify: `Pangolin/Views/SidebarView.swift`

- [ ] **Step 1: Add state for inline rename and delete confirmation**

```swift
@State private var renamingProjectID: UUID?
@State private var editedProjectTitle = ""
@FocusState private var focusedProjectID: UUID?
@State private var projectPendingDeletion: Folder?
@State private var showingProjectDeletionConfirmation = false
```

- [ ] **Step 2: Add the `Projects` list section below the existing Pangolin section**

```swift
Section("Projects") {
    ForEach(store.projects(), id: \.objectID) { project in
        projectSidebarRow(project)
            .tag(SidebarSelection.folder(project))
    }
}
```

The normal row is `Label(project.resolvedProjectTitle, systemImage: "folder.fill")`; the renamed row is a focused `TextField`. Attach native context-menu actions for `Open`, `Rename`, and destructive `Delete`.

- [ ] **Step 3: Use existing project navigation and mutation APIs**

When the selected tag contains a project folder, gate with `SidebarProjectSelectionPolicy.canOpen(isProject:)` and call `store.openProject(project)`. Rename through `ProjectRenamePolicy.savedTitle` and `await store.renameItem(id:to:)`. Delete through `await store.deleteItems([id])`.

- [ ] **Step 4: Add identical folder-drop behavior**

Apply the existing modifier to the sidebar list:

```swift
.projectFolderDrop(
    isEnabled: libraryManager.currentLibrary != nil,
    libraryManager: libraryManager
)
```

- [ ] **Step 5: Add the grid-equivalent confirmation**

```swift
.alert("Delete Project?", isPresented: $showingProjectDeletionConfirmation) {
    Button("Cancel", role: .cancel) { cancelProjectDeletion() }
    Button("Delete", role: .destructive) { Task { await confirmProjectDeletion() } }
} message: {
    Text("This project and all its contents will be permanently deleted from your library and removed from disk. This action cannot be undone.")
}
```

### Task 3: Make all activity items scrollable

**Files:**
- Modify: `PangolinTests/PangolinTests.swift`
- Modify: `Pangolin/Views/Components/ProcessingPopoverView.swift`

- [ ] **Step 1: Write the failing policy test**

```swift
func testActivityPopoverPolicyShowsEveryActiveItem() {
    XCTAssertEqual(ActivityPopoverPolicy.visibleItemLimit, nil)
}
```

- [ ] **Step 2: Run the test and confirm it is red**

Run `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/testActivityPopoverPolicyShowsEveryActiveItem test`.

Expected: compilation fails because the policy is undefined.

- [ ] **Step 3: Implement the scrollable content region**

```swift
enum ActivityPopoverPolicy {
    static let visibleItemLimit: Int? = nil
}

ScrollView {
    LazyVStack(alignment: .leading, spacing: 12) {
        if let cloudSyncStatus { CloudSyncStatusRow(status: cloudSyncStatus) }
        ForEach(activeTasks) { CompactTaskRowView(task: $0) }
        ForEach(activeTransfers) { ActiveTransferRow(transfer: $0) }
        ForEach(transferIssues) { TransferIssueRow(issue: $0, onRetry: {}) }
        ForEach(failedTasks) { CompactTaskRowView(task: $0) }
    }
}
.frame(maxHeight: 360)
```

Use `ForEach(activeTasks)`, `ForEach(activeTransfers)`, `ForEach(transferIssues)`, and `ForEach(failedTasks)` without `prefix` truncation. Keep pause/retry/clear controls outside the `ScrollView`.

- [ ] **Step 4: Re-run the focused test**

Run the command from Step 2. Expected: PASS.

### Task 4: Verify the feature

**Files:**
- Modify: `Pangolin/Views/SidebarView.swift`
- Modify: `Pangolin/Views/Components/ProcessingPopoverView.swift`
- Modify: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Run focused tests**

Run `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/testSidebarProjectSelectionPolicyOpensOnlyProjects -only-testing:PangolinTests/testActivityPopoverPolicyShowsEveryActiveItem test`.

Expected: PASS.

- [ ] **Step 2: Build and check the patch**

Run `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build -quiet` and then `git diff --check`.

Expected: both commands succeed.

- [ ] **Step 3: Commit the implementation**

Run `git add Pangolin/Views/SidebarView.swift Pangolin/Views/Components/ProcessingPopoverView.swift PangolinTests/PangolinTests.swift` followed by `git commit -m "feat: add projects to sidebar"`.
