# Apple Music-Style Project Detail Design

## Goal

Make the macOS project overview feel like an Apple Music album page while preserving Pangolin's course-specific grouping. The artwork and course metadata, module headings, video rows, and footer should form one continuously scrolling surface. Video rows should use native macOS selection, focus, keyboard navigation, and accessibility behavior.

The iOS and iPadOS project-detail layouts are outside this change unless shared component extraction requires a behavior-preserving adjustment.

## Reference

The visual reference is Apple Music's macOS album view:

- Large square artwork beside album metadata and actions.
- Generous whitespace with no enclosing hero card.
- Lightweight, full-width track rows separated by subtle rules.
- Native row selection and keyboard behavior.
- Multiple groups retain headings comparable to multi-disc albums.
- Album totals appear as subdued footer metadata.

Pangolin should use this composition and behavior without copying Apple Music branding or unrelated playback controls.

## Layout

Use one native SwiftUI `List` as the macOS project's only vertical scrolling container. Its content appears in this order:

1. An unselectable hero row.
2. One native `Section` for every nonempty project module.
3. An unselectable project-totals footer row.

The hero, module headings, video rows, and footer therefore scroll together. Do not place the `List` inside another vertical `ScrollView`.

Keep the existing 24-point horizontal page inset. Align the hero, section headings, and video content to a consistent content grid. Video ordinals may sit slightly inside the artwork's leading edge, following the Apple Music reference.

### Hero

The hero uses a side-by-side layout at normal macOS window widths:

- Square artwork on the left, approximately 200–220 points.
- Course title, provider, video count, and duration on the right.
- Actions near the bottom of the metadata column.
- `Continue watching` remains the prominent action.
- `Highlights` remains secondary.
- No card background, border, or separator between the hero and the first module.

At narrower widths, reduce the artwork and spacing before switching to a stacked hero. Do not compress the metadata into an unreadable column. The exact breakpoint should be derived from available width rather than device assumptions.

### Module Sections

Every project module remains visible as a section, comparable to the disc headings in a multi-disc album. A section contains:

- A small semibold module title.
- Optional video count or duration only when already available without introducing additional data loading.
- Video numbering that restarts at 1.
- No empty module after search filtering.

### Video Rows

Rows remain approximately 40–44 points high and contain:

- Module-relative ordinal.
- Watch-status indicator.
- Video title.
- Favourite control.
- Duration.
- Overflow menu.

Use primary styling for the title and secondary styling for ordinal, status, and duration. Use the list's native row highlight; remove the custom rounded translucent selection background. Use subtle system separators and avoid card styling.

### Footer

After the final module, show subdued project totals in the form of video count and formatted duration. This is analogous to Apple Music's track-count and album-duration footer. Do not add new metadata that Pangolin does not already own.

## Components

Keep `ProjectDetailView` responsible for assembling and routing the page, while extracting focused macOS presentation components where this improves clarity:

- `ProjectAlbumHero`: artwork, metadata, and hero actions.
- `ProjectVideoListRow`: the contents of one video row; it does not paint or own selection.
- `ProjectSectionHeader`: module identity and optional totals.
- `ProjectAlbumFooter`: project count and duration.

Component names may be adjusted to match existing naming conventions, but their responsibilities should remain separated. Avoid unrelated refactoring outside project-detail presentation and selection.

## State and Data Flow

`FolderNavigationStore` remains the source of truth for:

- Project sections and ordering.
- Project-scoped search.
- Selected project video IDs.
- Opening a project video.
- Aggregate project count and duration.

Bind the native list selection to `selectedProjectVideoIDs`. Every selectable video row must have its stable `UUID` tag. Hero, section headers, footer, and empty-state content must not have selection tags.

Remove the macOS-only manual selection path:

- `handleMacSelection(for:)`.
- Inspection of `NSApp.currentEvent` modifier flags.
- Custom selection background state in the row.

Keep selection separate from activation. A single click or keyboard movement selects; double-click or Return opens a video.

When project search changes the visible rows, reconcile selection so hidden video IDs do not remain as invisible selections. Preserve visible selected IDs. If no selected IDs remain visible, leave the list without a selection rather than selecting a row unexpectedly.

## Interaction

Native list behavior should provide:

- Up and down arrow navigation through videos, including across module boundaries.
- Shift-arrow range extension.
- Command-click discontiguous selection.
- Active-window accent highlighting.
- Inactive-window gray highlighting.
- Automatic scrolling to keep keyboard selection visible.

Add explicit activation behavior:

- Double-click opens the clicked video.
- Return opens the primary selected video when exactly one video is selected.
- Return does nothing when selection is empty or ambiguous.

Existing favourite and overflow controls remain independently actionable. Activating either control must not open the video.

## Empty and Filtered States

For a project with no videos, keep the hero visible and show the existing `ContentUnavailableView` as an unselectable list row.

For a search with no matching videos, keep the hero visible and show a search-specific empty state rather than the project's general no-content message. Clearing search restores all sections and rows in their stable order.

## Accessibility

- Group hero artwork and metadata as coherent course information.
- Expose module titles as headings.
- Give every video row a useful combined label containing its ordinal, title, duration, and watch state.
- Rely on native list semantics for selected state and row position.
- Keep favourite and overflow controls separately reachable and labelled.
- Provide an accessible activation action equivalent to opening the video.
- Ensure selection remains distinguishable in active and inactive windows and under increased-contrast settings.

## Error Handling

Videos without a stable UUID cannot participate in native selection. Treat this as a data-integrity exception: keep the row visible only if required for recovery, disable activation, and expose an appropriate accessibility description. Do not silently assign transient view-generated IDs.

Favourite persistence retains the current rollback behavior when Core Data saving fails. This design does not add new user-facing error presentation for that existing path.

## Testing

Add or update tests at the narrowest useful level:

- Store tests for preserving module order and module-relative numbering inputs.
- Store or policy tests for reconciling selection against filtered visible IDs.
- Tests for resolving Return activation only when one valid video is selected.
- macOS UI coverage proving that arrow keys move selection and Return opens the selected video.
- UI coverage proving that module headers are skipped during keyboard selection.
- Accessibility identifiers for the list, module headers, and video rows where UI tests need stable targets.

Run the existing project aggregation, project navigation, and full macOS test suites, followed by a macOS build. Because `ProjectsView.swift` is shared, also build the iOS Simulator target to catch cross-platform compilation regressions.

## Acceptance Criteria

- The hero and all module sections scroll together in one continuous surface.
- Module headings remain visible and video numbering restarts within every module.
- The initial composition closely follows the supplied Apple Music album reference while retaining Pangolin's content and actions.
- Video selection uses the native active and inactive macOS highlight.
- Arrow keys move selection across videos and module boundaries.
- Shift and Command multi-selection follow native macOS behavior.
- Double-click and Return open a single selected video.
- Hero, module headings, footer, and empty states are never selectable.
- Search preserves module grouping and cannot leave invisible selected IDs.
- VoiceOver receives native list semantics plus useful course, module, row, and control labels.
- Existing macOS and iOS project-detail behavior outside this scope continues to compile and pass tests.
