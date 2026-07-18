# Animated Video Docking Design

## Goal

Animate the video smoothly between its inline position in the video detail page and its floating picture-in-picture position without interrupting playback or recreating the player.

## Scope

This change affects the macOS video-detail presentation only. It changes player ownership and dock/undock presentation, while retaining the existing floating threshold, window-contained placement, drag and resize controls, inspector overlap rules, aspect-ratio preservation, and reset behavior.

The work will also close the two transcript-follow lifecycle gaps found during review: following must recover when the active lazy transcript row has not produced geometry, and removing the active timed transcript must cancel delayed follow work.

## Player Architecture

The video detail page will render one persistent `VideoPlayerWithPosterView`. That player will live in the root video presentation layer rather than switching between separate inline and floating player views.

The header will contain an aspect-ratio-preserving placeholder. It reports its frame in a named coordinate space owned by the root split-view content. The root layer uses that frame as the player's docked destination. Because the same player view and `VideoPlayerViewModel` remain alive in both states, playback time, rate, pause state, controls, subtitles, buffering, and poster state remain continuous.

The placeholder keeps the document layout stable while the live player is floating. It retains the existing subtle video-area background when the player is elsewhere.

## Dock and Undock Animation

The root presentation layer chooses between two destinations:

- **Docked:** the current inline placeholder frame.
- **Floating:** the committed frame in `FloatingVideoState`, prepared or clamped by the existing layout rules.

Crossing the existing visibility threshold starts an approximately 250-millisecond ease-in-out geometry transition. The live player visibly moves and resizes between the current frame and the destination frame. The player is not cross-faded, removed, or reinserted.

Ordinary page scrolling while docked does not animate. The player follows the placeholder frame directly so it remains visually attached to the document. Dragging and resizing while floating also remain direct and animation-free. Animation is limited to changes between docked and floating presentation states.

If the threshold reverses while a transition is running, the animation retargets from its current presentation toward the new destination. There is no intermediate jump back to either endpoint.

## Coordinate and Layout Behavior

The named root coordinate space covers the split-view content below the toolbar. Inline measurements and floating frames therefore use the same coordinate system.

The live player may overlap the inspector, as currently required, but its floating bounds remain below the toolbar and within the Pangolin window. Opening or closing the inspector, resizing the window, or changing the video aspect ratio updates or clamps the applicable destination without recreating the player.

When docked, the player is clipped with the existing rounded rectangle and receives normal video interaction. When floating, the same player receives the existing shadow, drag handle, reset button, resize handles, keyboard movement, and accessibility actions.

## State and Data Flow

`DetailView` reports the selected video ID, the inline placeholder frame, and its visibility measurement. `FloatingVideoState` continues to own whether the player is floating and its committed floating frame.

`MainView` owns the persistent player presentation because it can position the player across the entire split-view content. A small presentation policy selects the destination frame and whether a state transition should animate. Gesture-local preview frames continue to override the committed floating frame during an active drag or resize, without publishing every pointer update into shared state.

Changing or leaving the selected video clears stale inline geometry and hides the root player presentation. A newly selected video does not reuse geometry belonging to the previous video.

## Transcript-Follow Review Fixes

When playback changes the active paragraph but its lazy row has no reported geometry, the page will scroll directly to the active paragraph ID once, allowing SwiftUI to realise the row and resume geometry-based following. This fallback respects playback state and user suppression.

When the active timed paragraph becomes `nil`, transcript-follow suppression, geometry, and any delayed resume task are cleared immediately. A later replacement transcript cannot be moved by work scheduled for the removed content.

## Error and Edge Handling

- Missing, zero-sized, non-finite, or stale inline geometry does not produce a transition.
- The inline placeholder remains visible until a valid destination is known, preventing the player from flashing at the origin.
- A floating frame is prepared before the undock animation begins.
- Window and aspect-ratio changes clamp the destination through the existing pure layout functions.
- Rapid threshold changes retarget the live animation rather than creating multiple player instances.
- Gesture updates never inherit the dock/undock animation transaction.
- Paused video docks and undocks exactly like playing video.

## Testing

Automated tests will cover:

- docked and floating destination selection;
- rejection of stale or invalid inline frames;
- animation only when the presentation state changes;
- direct, non-animated updates during inline scrolling and floating gestures;
- transition retargeting without replacing the player identity;
- lazy-row transcript fallback while playing and unsuppressed;
- suppression preventing that fallback; and
- active-transcript removal cancelling pending follow state.

macOS verification will cover uninterrupted playing and paused transitions, rapid scroll reversal, inline scrolling, floating drag and resize, inspector changes, window resizing, and toolbar exclusion. The shared view changes must continue to compile for iOS.

## Acceptance Criteria

- The live video visibly travels and resizes smoothly between inline and floating positions.
- Playback and player controls continue without a reset, pause, poster flash, or duplicate audio.
- Page scrolling while docked and pointer movement while floating remain immediate and stable.
- Reversing direction during a transition produces a smooth retarget rather than a jump.
- The floating player stays inside the Pangolin window, below the toolbar, and may overlap the inspector.
- The two reviewed transcript-follow lifecycle gaps are closed without changing the four-second user override behavior.
