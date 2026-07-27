# Project Video Thumbnail Grid Design

## Goal

Replace the project-detail video table with a sectioned thumbnail grid on macOS, iPadOS, and iOS. The view should take its visual cues from Apple Books: prominent artwork, concise metadata, and generous spacing. It must preserve project section boundaries and provide dependable, platform-native selection and activation.

## Reference and Scope

The supplied Apple Books screenshot establishes the visual direction: thumbnail-forward cards with title and compact metadata underneath. Pangolin keeps its own video-specific information and does not copy Books branding or its reading-progress layout.

This change covers project-detail video presentation on all supported platforms. Project-grid presentation, video detail presentation, and the All Videos table remain outside the scope except where shared policy extraction is needed.

## Layout

`ProjectDetailView` becomes a vertically scrolling project page containing the existing hero, then one grid per nonempty project section, followed by the existing totals footer. Project sections remain ordered as they are today; video order within a section remains unchanged.

Use the existing `ProjectGridLayout` sizing policy as the basis for video grids:

- iPhone: exactly two equally sized columns.
- iPad and macOS: adaptive equally sized columns, with at least two columns.
- Grid insets and inter-card spacing remain consistent with the project grid.
- Cards use a 16:9 thumbnail to match video media, rather than the project card aspect ratio.

Search filtering hides empty sections. The hero stays visible. An empty project or empty filtered result shows the existing appropriate unavailable-content state below the hero.

## Video Card

Each card uses a focused, reusable SwiftUI card-content view:

1. A 16:9 thumbnail with a modest rounded rectangle clip.
2. Duration at the lower trailing edge of the thumbnail.
3. iCloud availability icon at the upper trailing edge where the video is cloud-only, downloading, missing, or in an error state.
4. A title below the artwork, limited to two lines.
5. A compact metadata row containing watch state and duration/availability information.

The card has no separate favourite button or overflow button in its permanent visual chrome. Existing edit, delete, and favourite operations remain reachable through each platform’s context menu (right-click on macOS and long press on iOS/iPadOS when not entering selection mode).

Selected state must remain visible without obscuring thumbnail content. The macOS selection presentation is delegated to the native collection view. Touch platforms use a clearly visible, accessible selection outline and checkmark treatment.

## Interaction and State

`FolderNavigationStore` remains the source of truth for project sections, the `selectedProjectVideoIDs` set, search filtering, and opening a video. Selection is separate from activation.

### macOS

The macOS grid is hosted by `NSCollectionView` through a narrow SwiftUI representable. The collection view supplies native focus, active/inactive selection, and selection modification:

- Click selects one card.
- Command-click adds or removes a card.
- Shift-click selects a contiguous range in the displayed project order, including across section boundaries.
- Arrow keys navigate cards.
- Return opens only when exactly one card is selected.
- Double-click opens the clicked card only when one card is selected.

The bridge forwards selected stable video UUIDs to `selectedProjectVideoIDs` and forwards activation directly to `FolderNavigationStore.openProjectVideo(_:in:)`. It must not depend on the `List.contextMenu(primaryAction:)` callback that caused the existing double-click failure.

### iPhone and iPad

- A normal tap opens a video.
- A long press enters selection mode and selects the pressed video.
- While selection mode is active, taps toggle cards in the selection set.
- The existing clear-selection command ends selection mode when no cards remain selected.

The app must not create transient selection IDs. Videos lacking a persistent UUID are visible but cannot be selected or activated.

Whenever filtering changes, selected IDs are intersected with visible IDs. This prevents invisible selections. Deleting a selected video uses the existing store deletion path and clears its ID.

## Accessibility

- Each section title is a heading.
- Every card has a label containing its title, watch status, duration, and availability state.
- Cards expose their selected state and an Open action.
- Thumbnail overlays that repeat card metadata are hidden from accessibility.
- The macOS collection bridge exposes the native collection semantics and accessibility tree.
- Context-menu actions keep explicit labels.

## Architecture

Extract focused pieces rather than expanding `ProjectDetailView` further:

- `ProjectVideoGridLayout`: shared sizing constants and column calculation, based on `ProjectGridLayout`.
- `ProjectVideoCardContent`: reusable SwiftUI thumbnail and metadata presentation.
- `ProjectVideoGrid`: iOS/iPadOS SwiftUI grid with touch selection behavior.
- `MacProjectVideoCollectionView`: macOS collection-view representable, collection data source/delegate, selection synchronization, and activation forwarding.
- Small pure selection/activation policies for testing.

The AppKit bridge is intentionally limited to interaction behavior SwiftUI’s `LazyVGrid` does not provide: native range/discontiguous selection, keyboard navigation, and reliable double-click activation. Visual card content remains SwiftUI-hosted.

## Testing and Verification

Before implementation, add failing tests for:

- iPhone versus regular-width column counts and a two-column minimum.
- Section-preserving visible ID ordering and filtering selection reconciliation.
- Mac activation only for exactly one selected visible ID.
- Touch interaction policy: normal tap opens before selection mode; long press enters selection mode and selects; subsequent taps toggle.
- Mac collection selection synchronization and double-click activation using a delegate-level test seam.

Verification includes targeted tests, the full macOS test suite, macOS build, and iOS Simulator build. Manually verify that project sections stay distinct; macOS click, Command-click, Shift-click, arrows, Return, and double-click work; and iPhone/iPad tap and long-press behavior work as specified.

## Acceptance Criteria

- Project-detail videos appear as sectioned thumbnail grids on every platform.
- iPhone always has two columns; iPad and macOS never have fewer than two.
- A card conveys thumbnail, title, watched state, duration, and relevant iCloud availability.
- macOS uses reliable native multiselection, keyboard navigation, Return, and double-click opening.
- iPhone/iPad tap opens; long press begins multiselection.
- Searches retain grouping and cannot leave invisible selections.
- Existing project navigation and video-detail opening continue to work.
- VoiceOver receives useful card labels, selection state, headings, and activation behavior.
