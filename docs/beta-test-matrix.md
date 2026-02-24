# Pangolin Beta Test Matrix

Use this matrix on exported release artifacts (TestFlight build and notarized direct app), not only Xcode local runs.

## Severity

- `P0`: release blocker, data loss, crash-on-core-flow, install failure.
- `P1`: major regression that blocks intended beta usage.
- `P2`: minor issues acceptable for beta with follow-up.

## 1) Packaging and Install

- [ ] `P0` TestFlight install works on target test machine.
- [ ] `P0` Direct build installs and launches outside Xcode.
- [ ] `P0` Direct build passes Gatekeeper (`spctl`) after notarization and stapling.
- [ ] `P1` App relaunches after reboot without startup failure.

## 2) Startup and Library Lifecycle

- [ ] `P0` First launch can create a new `.pangolin` library.
- [ ] `P0` Existing recent library reopens correctly.
- [ ] `P1` Corrupted library path shows recovery/reset overlay behavior.
- [ ] `P1` Library migration flow preserves usability for pre-1.1.0 data.

## 3) Import and Content Organization

- [ ] `P0` Import mixed files/folders completes without crash.
- [ ] `P1` Nested folder imports preserve expected hierarchy.
- [ ] `P1` Subtitle auto-match attaches matching subtitle files.
- [ ] `P1` Imported videos appear in expected folder and smart views.

## 4) Search and Navigation (MainView Regression Coverage)

- [ ] `P0` Search mode shows principal toolbar search field.
- [ ] `P1` Search field auto-focuses when entering search mode.
- [ ] `P1` Return key submits search and results render.
- [ ] `P1` Navigation title behavior in search mode is acceptable.
- [ ] `P1` Toggle sidebar button remains functional in search mode.

## 5) Processing Pipeline

- [ ] `P0` Transcription success path works end-to-end on supported locale.
- [ ] `P1` Permission-denied path shows actionable error messaging.
- [ ] `P1` Unsupported-language/model-missing paths are handled cleanly.
- [ ] `P1` Translation and summarization flows complete for at least one sample.

## 6) Data Safety and Storage Policy

- [ ] `P0` No data loss when reopening library after processing tasks.
- [ ] `P1` Cloud-only/local transitions are reflected correctly in UI state.
- [ ] `P1` Transfer failures surface in task/issue indicators.
- [ ] `P1` Storage policy enforcement does not evict active/selected items incorrectly.

## 7) UI Smoke

- [ ] `P1` Sidebar rename/delete shortcuts work correctly.
- [ ] `P1` Drag-and-drop between folders works and updates UI immediately.
- [ ] `P1` Task popover reflects background processing and transfer issues.

## 8) Exit Rule

- [ ] `P0` count is `0`.
- [ ] `P1` count is `0` for external beta release; any accepted `P1` must be explicitly documented with mitigation.
