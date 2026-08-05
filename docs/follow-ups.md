# Pangolin — Follow-up & Audit Backlog

> Living log of outstanding work from the Aug 2025 code audit, the `@Observable`
> migration, and the projects-grid keyboard work. Updated as items land.
> Tracked alongside `docs/superpowers/plans/2026-08-05-folder-store-observable-migration.md`.

## Priority: High (correctness / reliability)

- [ ] **Test isolation (audit Critical #2):** `ProjectsStoreTests`, `LibraryManagerTests`,
      `TimedTranscriptTests` share `LibraryManager.shared` and are NOT `.serialized`;
      **44 `closeCurrentLibrary()` calls exist with zero in `defer`** — a mid-test throw
      leaves the singleton holding an open library whose backing store was deleted.
      Partially done: marked `.serialized` (see commit log); remaining: move teardown into
      `defer`/`setUp`, and consider a CI test job with `-parallel-testing-enabled NO`.
      Files: `PangolinTests/ProjectsStoreTests.swift`, `PangolinTests/LibraryManagerTests.swift`,
      `PangolinTests/TimedTranscriptTests.swift`, `.github/workflows/quality-gates.yml` (no test job today).
- [ ] **CI gate checks the wrong entitlements file (audit G3):** `scripts/quality_gates.sh`
      validates `Pangolin/Pangolin.entitlements` — which is excluded from the target and never
      signed. The real signing files are `Pangolin-macOS.entitlements` / `Pangolin-iOS.entitlements`.
      The forbidden `temporary-exception` entitlement could be added to the real file and CI would pass.
- [ ] **UI tests are vacuous (audit H6):** `PangolinUITests` never call `app.launch()`;
      `testLaunchPerformance` measures an empty body. Zero end-to-end coverage.
- [ ] **Rename affordance (user-reported):** add Finder-style slow double-click on the project
      title to rename (macOS-gated, ~15 lines on the title area in `ProjectCard`).
      Context-menu rename works and now refreshes correctly (fixed in `e5ec72b`).

## Priority: Medium (modernization / platform-native)

- [ ] **`os.Logger` sweep:** replace 203 `print()` call sites with structured logging
      (subsystems/categories). Several are print-only error paths where failures are
      invisible (e.g. `SpeechTranscriptionService` disk-persist failures ~209/308/416).
- [ ] **Shared-component extraction (audit §3):** error banner hand-rolled 4×
      (FlashcardsView, TranscriptionView, TranslationView, SummaryView); status/task color
      switches duplicated (BulkProcessingView vs ProcessingPopoverView); ~47-line cloud-status
      resolver duplicated (VideoResultsTableView vs FolderOutlineRow) + magic `"videoID"`
      userInfo key in 4 observers; toolbar search field duplicated (DetailView macOS vs iOS).
- [ ] **Structural decomposition (flagged in pi-lens, pre-existing):**
      `SpeechTranscriptionService` (2.2k lines — split into audio-prep/recognition/translation/
      summarization/flashcards), `FolderNavigationStore` (1.7k), `ProcessingQueueManager` (1.5k),
      `VideoFileManager` (1.2k), `ProjectsView` (1.5k), `DetailView` (1.4k),
      `PangolinTests.swift` (2k). God-class + large-file/type/function-length items.
- [ ] **`NSMergeByPropertyStoreTrump` on the editing viewContext (audit M2):** CloudKit merges
      silently overwrite in-flight user edits. Evaluate switching the editing context to
      `NSMergeByPropertyObjectTrump`.
- [ ] **Singleton → environment composition (audit M9):** 10 `static let shared` singletons with
      init-time cross-references (`LibraryManager.shared` touches `VideoFileManager.shared`).
      Inject from a composition root; `VideoFileStatusView` re-injecting the singleton via
      `.environmentObject` is the smell to eliminate first.
- [ ] **Deprecated `Task.sleep(nanoseconds:)`** at VideoFileManager:202/558,
      StoragePolicyManager:365, ProcessingQueueManager:1224 → `Task.sleep(for:)`.

## Priority: Low / polish

- [ ] **Hover affordance on project cards (macOS):** `.plain` button gives no hover feedback.
- [ ] **iPadOS multi-select / edit mode for the projects grid** (Files-style) — optional.
- [ ] **`quality_gates.sh` doesn't run the test suite** — add a macOS test job.
- [ ] **`ImportProgressView`/`VideoDropDelegate` were deleted as dead code** — if bulk import
      progress UI is desired, rebuild it on the live `enqueueImport` path.

## Done (record)

- 2026-08-05 `4181744` — race-safe AI flows/downloads/imports + dead-code removal (audit C1/H1/H2/H4, §2).
- 2026-08-05 `8add32c` — FolderNavigationStore → `@Observable` (atomic, per plan deviation).
- 2026-08-05 `e5ec72b` — `contentRevision` refresh fix for method-driven views (rename-in-place bug).
- 2026-08-05 `01b07c2` — projects-grid keyboard navigation (arrows/Return), accessibility hint,
  `ProjectGridFocusPolicy` + tests.
