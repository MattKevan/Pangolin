# FolderNavigationStore @Observable Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `FolderNavigationStore` from `ObservableObject`/`@Published` to the `@Observable` macro and update every consumer view, eliminating the Combine workarounds and legacy property-wrapper plumbing in the navigation core.

**Architecture:** The store becomes an `@Observable` class (iOS 17+/macOS 14+; app targets 26.0) with plain stored properties; the Observation macro provides fine-grained invalidation. Consumers switch from `@EnvironmentObject`/`@ObservedObject` to `@Environment(FolderNavigationStore.self)` (or plain `let` for passed params), with `@Bindable` only where bindings are needed (ProjectsView's 3 sites). The store keeps its Combine subscriptions to `LibraryManager.$currentLibrary` and the context-save notification — those publishers are external and unchanged. Its one self-subscription (`$currentFolderID`) converts to a `didSet` observer mirroring the existing deferral pattern.

**Tech Stack:** SwiftUI Observation framework (`@Observable`, `@Environment`, `@Bindable`, `@State`), Swift Concurrency, existing Combine for external publishers.

## Global Constraints

- Deployment target iOS/macOS 26.0 — all Observation APIs available, no `#available` gating needed.
- **Behavior preservation is the contract:** navigation, selection preservation, route-sync policies, and deferral semantics must not change. The 263-test suite (esp. `ProjectsStoreTests`, `VideoNavigationSequenceTests`) is the gate.
- No force casts/`try!` (CI gate). `@State` stays `private`. No new singletons.
- Keep `import Combine` in the store (still subscribes to `LibraryManager` + notifications).
- Commit after every task; build + run the named tests before each commit.
- Do NOT touch the content views' `@ObservedObject var video: Video` (H5) in this plan — those re-render via the parent re-passing a fresh `Video` instance when the store refreshes, so they are unaffected by this migration. Documented separately.

---

### Task 1: Convert the store to @Observable

**Files:**

- Modify: `Pangolin/Stores/FolderNavigationStore.swift`
- Test: `PangolinTests/ProjectsStoreTests.swift`, `PangolinTests/VideoNavigationSequenceTests.swift` (unchanged — must still pass)

**Interfaces:**

- Consumes: nothing new.
- Produces: `@Observable class FolderNavigationStore` — same public API, same `@MainActor` isolation; all 15 `@Published` become observable stored properties; `currentFolderID` gains a deferred `didSet` refresh; `selectedSidebarItem`/`currentSortOption` keep their existing `didSet`.

- [ ] **Step 1: Apply the class-level conversion**

  - `import SwiftUI` → add `import Observation` (keep `Combine`, `CoreData`).
  - `class FolderNavigationStore: ObservableObject` → `@Observable class FolderNavigationStore`.
  - Remove `: ObservableObject`; delete nothing else yet.
  - All 15 `@Published` → plain `var` (keep `private(set)` where present, e.g. `projectSelectionAnchorID`).

- [ ] **Step 2: Convert the self-subscription**

  The `$currentFolderID.dropFirst().receive(on:).sink { refreshContent() }` block (lines ~209-217) references a publisher that no longer exists. Replace it with a deferred `didSet` on the property, matching the store's existing "defer cross-property mutations" style:

```swift
@Published var currentFolderID: UUID? {
    didSet {
        guard oldValue != currentFolderID else { return }
        // Defer to the next main-actor turn to avoid publishing during view updates.
        Task { @MainActor [weak self] in
            self?.refreshContent()
        }
    }
}
```

  Keep the two external Combine subscriptions (`libraryManager.$currentLibrary`, context-save notification) exactly as they are.

- [ ] **Step 3: Build**

Run: `cd /Users/mattkevan/Dev/Pangolin && xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. (Store tests compile against the app module.)

- [ ] **Step 4: Run the store test suites**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests -only-testing:PangolinTests/VideoNavigationSequenceTests`
Expected: all pass (store API unchanged; tests construct the store directly).

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Stores/FolderNavigationStore.swift
git commit -m "refactor: migrate FolderNavigationStore to @Observable"
```

---

### Task 2: MainView plumbing

**Files:**

- Modify: `Pangolin/Views/MainView.swift` (store ownership, 16 injection sites, phone-shell views, RootContainerView/RootEventsModifier params)

**Interfaces:**

- Consumes: `@Observable FolderNavigationStore` from Task 1.
- Produces: `.environment(folderStore)` injection (replaces `.environmentObject(folderStore)`); `@Environment(FolderNavigationStore.self)` reads in DetailColumnView, PhoneCollectionTabView, PhoneVideoNavigationStack; plain `let folderStore` params in RootContainerView/RootEventsModifier.

- [ ] **Step 1: Ownership — `@StateObject` → `@State`**

```swift
// before
@StateObject private var folderStore: FolderNavigationStore
// init
self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
// after
@State private var folderStore: FolderNavigationStore
// init
self._folderStore = State(initialValue: FolderNavigationStore(libraryManager: libraryManager))
```

- [ ] **Step 2: Passed params — `@ObservedObject` → `let`**

  `RootContainerView` (line ~710) and `RootEventsModifier` (line ~763): `@ObservedObject var folderStore: FolderNavigationStore` → `let folderStore: FolderNavigationStore`. (SwiftUI `onChange(of:)` and view body reads work identically on a plain reference.)

- [ ] **Step 3: Environment reads**

  `DetailColumnView` (~833), `PhoneCollectionTabView` (~896), `PhoneVideoNavigationStack` (~912):
  `@EnvironmentObject private var folderStore: FolderNavigationStore` → `@Environment(FolderNavigationStore.self) private var folderStore`.

- [ ] **Step 4: Injection sites — all 16 `.environmentObject(folderStore)` → `.environment(folderStore)`** (mechanical, lines ~209, 377, 430, 439, 454, 499, 516, 532, 846, 850, 854, 864, 873, 904, 976 + any remaining).

- [ ] **Step 5: Build**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Run navigation tests**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests/ProjectsStoreTests -only-testing:PangolinTests/VideoNavigationSequenceTests`
Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Pangolin/Views/MainView.swift
git commit -m "refactor: inject FolderNavigationStore via @State/@Environment in MainView"
```

---

### Task 3: Convert the five direct-consumer views

**Files:**

- Modify: `Pangolin/Views/DetailView.swift` (line 109), `Pangolin/Views/SidebarView.swift` (68), `Pangolin/Views/Components/FolderContentView.swift` (11), `Pangolin/Views/Components/VideoResultsTableView.swift` (34), `Pangolin/Views/Components/ContentRowView.swift` (29)

**Interfaces:**

- Consumes: `.environment(folderStore)` from Task 2.
- Produces: each view reads `@Environment(FolderNavigationStore.self) private var store` with identical member access.

- [ ] **Step 1: Mechanical conversion in all five files**

  `@EnvironmentObject private var store: FolderNavigationStore` → `@Environment(FolderNavigationStore.self) private var store`.
  (`FolderContentView`/`VideoResultsTableView`/`ContentRowView` are injected in MainView's detail column and the phone stacks — covered by Task 2's injection changes.)

- [ ] **Step 2: Build**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full unit suite (regression gate — store observation is now fine-grained; this catches any view that relied on re-rendering for an unread property)**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests`
Expected: 263 tests pass. If a view fails to update visually it won't fail tests — see Task 5's manual smoke checklist.

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Views/DetailView.swift Pangolin/Views/SidebarView.swift Pangolin/Views/Components/FolderContentView.swift Pangolin/Views/Components/VideoResultsTableView.swift Pangolin/Views/Components/ContentRowView.swift
git commit -m "refactor: read FolderNavigationStore from environment in detail/sidebar/content views"
```

---

### Task 4: ProjectsView bindings + SearchResultsView

**Files:**

- Modify: `Pangolin/Views/ProjectsView.swift` (ProjectDetailView, lines ~534-745: `$store.projectSearchQuery`, `$store.selectedProjectVideoIDs`), `Pangolin/Views/SearchResultsView.swift` (line 19 + preview at ~293)

**Interfaces:**

- Consumes: `@Observable FolderNavigationStore`.
- Produces: `@Bindable` local in ProjectDetailView's body; `.environment(FolderNavigationStore(...))` in SearchResultsView's `#Preview`.

- [ ] **Step 1: ProjectsView — environment read + @Bindable for the 3 bindings**

```swift
// ProjectDetailView (and ProjectsGridView at line 361):
@EnvironmentObject private var store: FolderNavigationStore
// becomes
@Environment(FolderNavigationStore.self) private var store

// In ProjectDetailView's body (which uses $store.projectSearchQuery and
// $store.selectedProjectVideoIDs at lines ~625, 660, 745), add a local @Bindable:
var body: some View {
    @Bindable var store = store
    // ... existing body — $store.projectSearchQuery / $store.selectedProjectVideoIDs work unchanged
}
```

- [ ] **Step 2: SearchResultsView — environment read + preview**

  Line 19: `@EnvironmentObject private var folderStore: FolderNavigationStore` → `@Environment(FolderNavigationStore.self) private var folderStore`.
  Preview (~293): `.environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))` → `.environment(FolderNavigationStore(libraryManager: LibraryManager.shared))`.
  `SearchResultsTableView`'s `let folderStore` param (138) needs no change.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full unit suite**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests`
Expected: 263 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Pangolin/Views/ProjectsView.swift Pangolin/Views/SearchResultsView.swift
git commit -m "refactor: bind FolderNavigationStore properties in ProjectsView, update search preview"
```

---

### Task 5: Full verification and smoke checklist

**Files:** none (verification only)

- [ ] **Step 1: Full test suite + UI target**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test`
Expected: PangolinTests 263/263, PangolinUITests 4/4.

- [ ] **Step 2: LSP diagnostics**

Run: `lsp_diagnostics` over `Pangolin/` — expect zero errors.

- [ ] **Step 3: Manual smoke (runtime behavior of fine-grained observation)**

  These behaviors must still work in the running app (spot-check at least the first two):
  1. Open a project from the grid → grid → project detail navigation.
  2. Select a video → detail view; prev/next navigation between neighbors.
  3. Search (Cmd-F) → results table → select row → video detail opens.
  4. Rename a project inline; sidebar selection highlight follows.

- [ ] **Step 4: Commit any stragglers (none expected)**

---

## Self-Review

- **Spec coverage:** Every requirement from the audit recommendation (@Observable store migration, wrapper cleanup, binding correctness) maps to Tasks 1-4; Task 5 gates it all. H5 (content-view video observation) is explicitly scoped out with a documented reason.
- **Placeholder scan:** All steps contain concrete code or exact commands; no TBDs. The only judgment-dependent step (5.3 smoke checklist) is intentionally manual and lists exact behaviors.
- **Type consistency:** `@Environment(FolderNavigationStore.self)`, `.environment(folderStore)`, `@Bindable var store = store`, `@State private var folderStore` + `State(initialValue:)` are consistent across tasks. `currentFolderID` didSet mirrors the existing `selectedSidebarItem` deferral exactly.


---

## Execution Log (2026-08-05)

**Deviation from plan task boundaries:** Tasks 1-4 were executed as ONE atomic
change (commit `8add32c`) because no intermediate state compiles — SwiftUI's
`@StateObject`/`@EnvironmentObject`/`.environmentObject` hard-require
`ObservableObject`, so the store conversion forces every consumer change in
the same commit. The per-task build gates in the plan were therefore
impossible as written; the atomic change was gated on: build succeeds +
263/263 unit tests + 0 LSP errors + UI target 4/4.

- [x] Task 1: store converted to @Observable (15 @Published -> stored props,
      \$currentFolderID self-subscription -> deferred didSet, external Combine
      subscriptions unchanged)
- [x] Task 2: MainView plumbing (@State ownership, let params, @Environment
      reads, 15 .environment injection sites)
- [x] Task 3: DetailView/SidebarView/FolderContentView/VideoResultsTableView/
      ContentRowView environment reads
- [x] Task 4: ProjectsView @Bindable locals (body/macProjectDetail/
      iosProjectDetail) + SearchResultsView preview
- [x] Task 5 (automated portions): full suite 263/263, UI 4/4, LSP clean.
      Runtime smoke checklist below is PENDING — needs human eyes.
- [x] Test fix: VideoNavigationSequenceTests replaced Combine \$selectedVideo
      sink (projection no longer exists) with direct behavioral assertions.

**Remaining (human):** runtime smoke — see checklist below.
