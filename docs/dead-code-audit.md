# Dead Code Audit Workflow (Swift / Pangolin)

## Goal

Find declarations that are:

- unreferenced (`no call sites`)
- preview-only / legacy UI
- referenced but currently unreachable in the active routing flow

## Quick Audit (recommended first pass)

Use the helper script:

```bash
scripts/dead_code_audit.sh
```

The script runs:

- `rg` call-site checks for common library-view components
- a broad symbol search report for selected views
- optional `periphery` check (only if installed)

## Manual Verification Checklist

1. Use `rg` to find direct instantiations or symbol references.
2. Use Xcode “Find References” / “Call Hierarchy” for UI entrypoints.
3. Trace runtime reachability from `MainView` / router views (not just references).
4. Before deleting a file, confirm there are no project references that require pbxproj changes.
5. Build the app after removal/deprecation.

## Current Notes (library views)

- `SearchDetailView`: appears preview-only and is now marked deprecated.
- `HierarchicalContentView`: appears unused in current routing and is now marked deprecated.
- `FolderOutlinePane`: now actively used via `FolderContentView` for normal folder detail surface.

## Optional Periphery

If installed, run (example):

```bash
periphery scan --project Pangolin.xcodeproj --schemes Pangolin
```

Notes:

- Expect false positives for SwiftUI previews, selectors, reflection, and some Core Data patterns.
- Always verify with `rg`/Xcode references before deleting.
