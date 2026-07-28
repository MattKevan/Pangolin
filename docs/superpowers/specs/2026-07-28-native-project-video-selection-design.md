# Native Project Video Selection Design

## Goal

Make project-detail video interaction follow each platform's native collection-selection model while preserving the existing thumbnail card presentation and navigation state.

## Interaction

### macOS

An `NSCollectionView` owns video selection and activation:

- A click selects one video.
- Command-click extends or toggles selection.
- Shift-click and Shift-arrow extend a range.
- Dragging across the collection background performs native rubber-band selection.
- Arrow keys move through the collection.
- Return opens the only selected video.
- Double-click selects and opens the clicked video.
- Clicking the background clears selection.
- A contextual click preserves a multi-selection when the clicked item is already selected; otherwise it selects the clicked item before showing actions.

SwiftUI tap and drag recognizers must not participate in macOS card interaction.

### iOS and iPadOS

A `UICollectionView` owns normal and editing selection:

- Outside selection mode, a tap opens the tapped video.
- A Select/Done control enters and leaves collection editing mode.
- In selection mode, taps toggle videos without opening them.
- Native two-finger pan selection can enter selection mode and select multiple items.
- Long press presents the video's context menu instead of acting as a hidden selection gesture.
- Leaving selection mode retains the selected IDs until the user clears them or navigates away.

## Architecture

`FolderNavigationStore.selectedProjectVideoIDs` remains the application source of truth. Each native collection mirrors that set into its platform selection and publishes user-initiated changes back through a binding. Synchronization must avoid feedback loops.

The platform collection views are narrow representable bridges:

- `MacProjectVideoCollectionView` wraps `NSCollectionView`.
- `IOSProjectVideoCollectionView` wraps `UICollectionView`.
- `ProjectVideoCardContent` remains the shared SwiftUI card visual hosted inside native reusable items or cells.
- `ProjectDetailView` supplies sections, selection, and callbacks for open, edit, delete, and favourite.

Collection data uses stable video UUIDs. Filtering reconciles selection with visible UUIDs before native selection is restored.

## Layout

The existing project hero remains above the native collection and totals remain below it for this interaction-focused change. The native collection owns scrolling inside the remaining detail area. Section headers remain native supplementary views.

The change does not redesign card artwork, metadata, the hero, or video detail.

## Accessibility

Native collection semantics expose focus and selection. Hosted card content supplies a useful label and Open action. Selected state is reflected by the native item or cell and by the existing card outline.

## Testing

- Pure policies cover Return and double-click activation, filtering reconciliation, and iOS tap behavior in and out of editing mode.
- macOS bridge tests cover selection publication and double-click forwarding through a coordinator seam.
- Targeted unit tests run before and after implementation.
- Verification includes the macOS test suite, macOS build, iOS Simulator build, and manual checks for modifier selection, rubber-band selection, double-click, Return, Select/Done, and two-finger pan.

## Acceptance Criteria

- macOS cards have no SwiftUI tap or drag recognizers.
- macOS click, Command-click, Shift-click, rubber-band selection, arrows, and Return use `NSCollectionView`.
- Double-click opens the clicked video's detail route.
- iPhone and iPad use `UICollectionView` editing selection rather than long-press selection.
- A normal iOS tap opens a video when selection mode is inactive.
- Both platforms keep `selectedProjectVideoIDs` synchronized using stable UUIDs.
- Existing project filtering and video actions continue to work.
