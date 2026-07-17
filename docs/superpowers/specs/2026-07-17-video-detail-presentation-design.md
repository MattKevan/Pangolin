# Video Detail Presentation Design

## Goal

Present a video detail page as a focused, full-window content surface without the library sidebar. The page must retain its navigation origin, provide a video-specific toolbar, align all primary content to one centred column, and continue to work with the native right inspector.

## Scope

This change applies to video detail pages opened from:

- a course detail page;
- a smart collection such as All Videos or Favorites; and
- search results.

It does not redesign course pages, collection tables, search results, transcript controls, or the inspector contents.

## Navigation Model

`FolderNavigationStore` will retain a lightweight video navigation origin before opening a video. The origin identifies the surface that Back should restore:

- the selected course detail;
- the originating smart collection; or
- search results.

Opening a video changes the root `NavigationSplitView` column visibility to detail-only. This makes the detail content occupy the whole window content area while preserving the existing navigation hierarchy and state.

Back performs these actions as one store operation:

1. Clear the selected video.
2. Restore the recorded sidebar destination and relevant course or list selection.
3. Clear the consumed video origin.
4. Return the split view to its normal sidebar-and-detail visibility.

Existing previous and next video navigation stays inside the video presentation and does not replace the recorded Back origin.

## Toolbar

The toolbar is route-driven rather than layered in an overlay.

While a video is open, the toolbar contains only video-specific items:

- Back as the first leading item;
- the in-video search field when the Transcript tab is active;
- the existing background-task status control when work or failures are present; and
- the right-inspector toggle.

Library import controls and the standard sidebar toggle are absent from this state. Returning from the video restores the normal library or course toolbar.

This avoids a visual overlay over an interactive split view and keeps keyboard focus, accessibility order, commands, and the native macOS toolbar attached to the active route.

## Page Layout

The page is divided into two vertical surfaces.

### Header surface

The player and title row sit on a semantic secondary background. In light mode this reads as pale grey; in dark mode it uses the corresponding system-adaptive surface rather than a fixed colour.

One centred content column contains:

- the 16:9 video player at the full width of the column; and
- the title, favorite control, and more/settings control directly beneath it.

### Content surface

The tabs, transcript or summary, and previous/next navigation sit on the standard content background. They use the same centred column width and horizontal alignment as the player and title.

The shared column has a maximum width of 760 points and flexible side margins. At narrower window sizes it contracts to the available width. When the native right inspector opens, SwiftUI reduces the detail region and the column automatically recentres within the remaining space.

No manual offset is applied for the inspector.

## Action Controls

The heart and ellipsis/settings controls retain their current actions and accessibility labels but use a compact visual treatment. Their visible frames shrink from 46 to 34 points. Their interactive regions remain at least 44 points through transparent padding or content shape, with clear hover and keyboard-focus feedback.

## State And Error Handling

- If a video has no resolvable origin, Back restores the destination retained by the store; if none exists, it returns to the Projects grid.
- Opening the inspector must not change the selected video, selected tab, playback state, or recorded Back origin.
- Opening previous or next videos must preserve the original Back destination.
- Existing transcript, playback, empty, processing, and error states remain unchanged.

## Testing

Store tests will be written first for:

- restoring a course after Back;
- restoring a smart collection after Back;
- restoring search after Back;
- preserving the origin while moving to previous or next videos; and
- falling back safely when no origin is available.

Layout code will keep the shared 760-point content width and related spacing in one layout definition. Build verification and a focused macOS UI pass will confirm:

- the sidebar is absent on video pages;
- the video toolbar replaces the library toolbar;
- player, title, tabs, and transcript align to one column;
- header and transcript surfaces adapt in light and dark appearances;
- the inspector shifts and recentres the content column; and
- compact action controls remain usable with pointer, keyboard focus, and accessibility labels.

## Out Of Scope

- Adding the Highlights tab shown in the wireframe.
- Changing transcript typography or transcript-generation behavior.
- Redesigning the right inspector.
- Replacing native `NavigationSplitView` or `.inspector` behavior with a custom split implementation.
