# Video List Context Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide cross-platform Edit Video and Delete Video actions from All Videos and project video lists.

**Architecture:** A reusable editor sheet owns title/favourite drafts and writes through `LibraryManager`. The table and project detail resolve one selected video, present that sheet, and confirm deletion through `FolderNavigationStore`.

**Tech Stack:** SwiftUI, Core Data, Swift Testing, Xcode.

---

### Task 1: Test metadata input validation

**Files:**
- Modify: `PangolinTests/ProjectsStoreTests.swift`
- Create: `Pangolin/Views/Components/VideoMetadataEditor.swift`

- [ ] Add a failing `VideoMetadataEditPolicy` test proving whitespace is trimmed and blank titles are rejected; run `xcodebuild test -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/ProjectsStoreTests` and confirm it fails for the missing policy.
- [ ] Add the minimal policy and reusable editor sheet; rerun the focused tests and confirm they pass.

### Task 2: Add All Videos table actions

**Files:**
- Modify: `Pangolin/Views/Components/VideoResultsTableView.swift`

- [ ] Add macOS single-selection context-menu actions, editor-sheet state, and destructive deletion confirmation using the existing store API.

### Task 3: Add project-list actions on macOS and iOS

**Files:**
- Modify: `Pangolin/Views/ProjectsView.swift`

- [ ] Extend the macOS selection context menu with Edit Video/Delete Video and attach native per-row context menus to iOS project rows; present the shared editor and confirmation from `ProjectDetailView`.

### Task 4: Verify and commit

**Files:**
- Modify: `Pangolin/Views/Components/VideoMetadataEditor.swift`
- Modify: `Pangolin/Views/Components/VideoResultsTableView.swift`
- Modify: `Pangolin/Views/ProjectsView.swift`
- Modify: `PangolinTests/ProjectsStoreTests.swift`

- [ ] Run `git diff --check HEAD`, the focused project tests, and `xcodebuild build -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'`; commit the feature only after all commands exit successfully.
