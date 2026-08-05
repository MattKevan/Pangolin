# Pangolin — Follow-up & Audit Backlog

> Living log of outstanding work from the Aug 2025 code audit, the `@Observable`
> migration, and the projects-grid keyboard work. Updated as items land.
> Tracked alongside `docs/superpowers/plans/2026-08-05-folder-store-observable-migration.md`.

## Priority: High (correctness / reliability)

- [x] **Test isolation (audit Critical #2) — partially, with a revert on record:** suites
      `.serialized` (`94a29b0`). The teardown-into-defer attempt (`2ce237d`) was REVERTED
      (`da898d4`): the fire-and-forget defer Task ran the close AFTER the synchronous
      temp-root deletion, so save() hit a deleted SQLite file — a repeating
      "LIBRARY: Save failed" loop in the test host (18+/run) plus CloudKit recovery churn.
      The correct non-racy teardown is an awaited wrapper (withLibraryContext { body }) that
      closes before removing — logged as TODO below. Also fixed: frame-update wait flake
      (`2494173`, main-actor starvation).
- [ ] **Awaited teardown wrapper (replaces the reverted defer approach):** wrap library-touching
      tests in `withLibraryContext { }` so closeCurrentLibrary runs in-body (before temp-root
      removal) on every path including throws, with no post-test async task. Note: the
      consolidation test still logs one transient "Save failed" under full-suite load
      (pre-existing, present with both merge policies — test-host CloudKit mirroring noise).
- [x] **CI entitlements gate (audit G3):** fixed in `94a29b0` — now checks
      `Pangolin-macOS.entitlements` + `Pangolin-iOS.entitlements` + the legacy file; negative-tested.
- [x] **UI tests vacuous (audit H6):** closed in `9a3c1a4` — real smoke tests launch the app,
      assert the library sidebar renders, measure real launch performance, and confirm
      `.runningForeground`. 4/4 pass locally.
- [x] **Rename affordance (user-reported):** double-click on the project title to rename added
      in `ea56e4b` (macOS-gated). **Pending runtime verification** that the double-click
      gesture arbitrates against single-click open. Context-menu rename refreshed correctly
      since `e5ec72b`.

## Priority: Medium (modernization / platform-native)

- [x] **`os.Logger` sweep:** done in `a216af3` — all 193 `print()` calls replaced with
      per-subsystem `Logger`s (`Utilities/Logging.swift`); error/warning/info levels from
      the diagnostic prefix; print-only error paths now visible in Console.app.
- [ ] **Shared-component extraction (audit §3) — remaining:** error banner done (`426a1f8`,
      `InlineErrorBanner`); cloud-status resolver deduped in `73c0e7f` (shared
      `VideoFileManager.resolvedSnapshot` + `transferNotification`, key constant).
      Status/task colors were deduped by the dead-code pass. Still open: toolbar search field
      duplicated (DetailView macOS vs iOS).
- [ ] **Structural decomposition (flagged in pi-lens, pre-existing):**
      `SpeechTranscriptionService` (2.2k lines — split into audio-prep/recognition/translation/
      summarization/flashcards), `FolderNavigationStore` (1.7k), `ProcessingQueueManager` (1.5k),
      `VideoFileManager` (1.2k), `ProjectsView` (1.5k), `DetailView` (1.4k),
      `PangolinTests.swift` (2k). God-class + large-file/type/function-length items.
- [x] **Merge policy (audit M2):** editing viewContext now uses
      `NSMergeByPropertyObjectTrump` (`577720e`) so CloudKit merges can no longer silently
      overwrite unsaved user edits.
- [ ] **Singleton → environment composition (audit M9):** 10 `static let shared` singletons with
      init-time cross-references (`LibraryManager.shared` touches `VideoFileManager.shared`).
      Inject from a composition root; `VideoFileStatusView` re-injecting the singleton via
      `.environmentObject` is the smell to eliminate first.
- [x] **Deprecated `Task.sleep(nanoseconds:)`:** all 14 sites → `Task.sleep(for:)` (`fad31f6`).

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
