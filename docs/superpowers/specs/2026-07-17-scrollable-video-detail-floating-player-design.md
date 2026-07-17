# Scrollable Video Detail and Floating Player Design

## Goal

Turn the video detail page into one continuous document whose height is driven by its content. When the inline player has mostly scrolled away, preserve access to playback through a draggable, resizable floating player contained within the Pangolin window.

## Scope

This change applies to video detail pages on macOS. It covers:

- the page's scrolling model;
- inline-player sizing;
- automatic floating and docking;
- floating-player placement, dragging, and resizing;
- transcript and summary integration with the outer scroll view; and
- uninterrupted playback during presentation changes.

It does not introduce system Picture in Picture, a separate player window, persistent pane placement between videos, or changes to transcript-generation and summary-generation behaviour.

## Page Layout

The video detail page uses one vertical `ScrollView` containing, in order:

1. the inline video player;
2. the title and compact actions;
3. the Transcript/Summary tabs;
4. the selected transcript or summary content; and
5. Previous/Next navigation.

The video, title, tabs, text, and navigation retain the existing centred content-column alignment. The inline player fills the available width of that column. Its height is derived from the source video's aspect ratio, rather than a fixed height. Until source dimensions are available, the player uses 16:9 as its fallback ratio.

The adaptive grey header surface continues behind the inline player and title. Tabs and text remain on the standard content surface.

`MergedTranscriptView` and `SummaryView` no longer create their own scroll views. They expand to their full content height inside the page's outer scroll view. Transcript search navigation scrolls the outer container to the matching paragraph.

## Floating Trigger and Docking

The page tracks the inline player's frame relative to the visible scroll viewport and derives a visible fraction.

- The player floats when its visible fraction falls to 25 percent or less.
- The player docks inline when its visible fraction rises to 60 percent or more.
- Separate thresholds provide hysteresis and prevent rapid floating/docking near one boundary.
- Floating occurs whether playback is playing or paused.

When floating, the inline location retains a placeholder with the same aspect-ratio-derived size. This prevents a layout jump and keeps the return threshold stable.

Docking and floating change only presentation. They must not reload the video, replace the active `AVPlayer`, seek, pause, play, change volume, change subtitles, dismiss the poster unexpectedly, or reset playback controls.

## Player Architecture

The existing `VideoPlayerViewModel` and its single `AVPlayer` remain the source of truth for playback. Only one active player surface is rendered at a time:

- the inline surface while the player is docked; or
- the floating surface while the player is floating.

Both surfaces use the same view model and player. Switching surfaces reattaches presentation to the existing player without constructing a new player item.

`DetailView` becomes a presentation container composed from focused units:

- `VideoDetailScrollView` owns the single page scroll container and reports inline-player visibility;
- `InlineVideoSection` renders the player location, grey header surface, title, and actions; and
- `FloatingVideoPane` renders the draggable and resizable player above the page.

A lightweight `FloatingVideoState` stores presentation-only state:

- whether the player is floating;
- its current size;
- its drag position; and
- the video identifier for which the state is valid.

Selecting a different video resets the floating size and position. The state is not stored between app launches. Within one video, user-adjusted size and position survive repeated docking and floating.

## Floating Placement and Bounds

The floating player initially appears at the top-right of the video-detail presentation area. Its initial width is 55 percent of the inline player's width, clamped only when needed to fit the available window region. The floating player has a minimum width of 240 points, or the available width when the window is narrower.

The floating layer is attached at the full video-detail presentation boundary rather than inside the scroll content. It may overlap transcript or summary content and the right inspector. It must remain below the window toolbar and must not cover the toolbar.

Users can drag the pane anywhere within that below-toolbar region. The pane remains fully reachable inside the Pangolin window. Opening or closing the inspector may change the available geometry; the pane retains its size and position where possible and is moved only enough to remain reachable.

The pane can be resized from visible corner handles. Resizing always preserves the source video aspect ratio. Its minimum width is 240 points, or the available width when the window is narrower. It has no configured maximum; the physical below-toolbar window bounds are the only upper constraint.

If the window is resized so that the pane lies outside the reachable region, its frame is clamped back inside that region.

## Interaction and Accessibility

Dragging the pane must not interfere with native playback controls. Dedicated resize handles avoid treating control interactions as resize gestures.

Keyboard and accessibility support includes:

- moving the pane in 10-point increments;
- resetting it to the default top-right position;
- accessible labels for floating state and resize controls; and
- preserved keyboard focus when switching between inline and floating surfaces where the platform permits.

The existing player controls, full-screen action, subtitles, poster, loading state, unavailable-file state, and playback errors remain available in either presentation.

## Transcript Search and Scrolling

Transcript paragraph identifiers remain stable. Search state continues to live in `VideoPageSearchModel`, but match navigation sends a scroll request to the outer page rather than a nested transcript `ScrollViewReader`.

Active timed-transcript highlighting continues to update during playback. Playback progress does not automatically scroll the outer page to the active paragraph, because doing so would fight manual reading and could trigger floating without a user scroll. Search match navigation remains an explicit scroll action.

## State Transitions

Changing videos performs these actions:

1. reset floating presentation state;
2. place the new player inline at the top of the page;
3. reset the outer page scroll position to the top; and
4. load the selected video through the existing player view model.

Switching Transcript/Summary tabs does not alter the player presentation or playback state. Opening or closing the right inspector does not dock the player or reset user placement.

## Testing and Verification

Unit-test the presentation calculations independently of SwiftUI rendering:

- 25-percent float and 60-percent dock thresholds;
- hysteresis between thresholds;
- aspect-ratio-derived inline height;
- default top-right placement;
- per-video reset;
- aspect-ratio-preserving resize;
- drag-bound and window-resize clamping; and
- inspector geometry changes.

Integration and manual macOS verification cover:

- one continuous page with no nested transcript or summary scrolling;
- inline player filling the content-column width;
- uninterrupted time, play/pause state, volume, and subtitles across floating and docking;
- floating while paused;
- dragging and resizing without stealing playback-control input;
- overlap of transcript and inspector but not the toolbar;
- transcript search scrolling the outer page to matches;
- stable behaviour around the hysteresis thresholds;
- switching videos while floating; and
- light/dark appearances at narrow and wide window sizes.

## Out of Scope

- System-managed Picture in Picture.
- A separate `NSWindow` or external player window.
- Remembering pane geometry between videos or app launches.
- A user-configurable floating threshold.
- A configured maximum floating-player size below the physical window bounds.
