# Smooth Floating Drag and Transcript Follow Design

## Goal

Remove visible shaking while the floating video is dragged or resized, and keep the active timed-transcript paragraph visible during playback without fighting intentional user scrolling.

## Scope

This change affects only:

- floating-player drag and resize presentation;
- active timed-transcript visibility tracking;
- playback-driven transcript following; and
- temporary suspension of following after intentional navigation.

It does not change floating thresholds, playback state, player ownership, transcript generation, search matching, page layout, or floating-pane persistence.

## Floating Player Interaction

The current drag gesture measures translation in the moving view's local coordinate space while publishing a new shared frame on every pointer event. Moving the coordinate space that supplies the gesture creates a feedback loop, and publishing every intermediate frame repeatedly invalidates the AVKit-backed hierarchy.

Drag and resize interactions will instead use gesture-local preview state measured in a stable root coordinate space:

1. Capture the committed floating frame when the gesture begins.
2. Derive a clamped preview frame from that immutable start frame and the gesture translation.
3. Render the pane from the preview frame without mutating `FloatingVideoState` on every pointer event.
4. Commit the final preview frame to `FloatingVideoState` when the gesture ends.
5. Clear preview state after the committed frame is installed.

Dragging changes position only. Resizing changes the preview size and position while preserving the video aspect ratio, minimum width, and root-window bounds. Keyboard and accessibility adjustments remain discrete committed operations.

## Transcript Auto-Follow

Timed transcript paragraphs retain stable IDs. The active paragraph reports its frame in the existing detail viewport coordinate space. The outer `DetailView` owns scroll decisions because it owns the only vertical `ScrollView` and its proxy.

While playback is running and follow is enabled:

- if the active paragraph leaves the lower visible safe area, the page scrolls smoothly to place it near the lower-middle portion of the viewport;
- if following resumes while the active paragraph is above or below the viewport, the current paragraph is smoothly returned to the safe area;
- changes within an already-visible safe area do not scroll; and
- paused playback does not generate follow scrolling.

The safe area includes a bottom margin so the highlight moves before text is clipped by the window edge.

## User Override

Direct user scrolling immediately suppresses transcript following. The suppression remains active for four seconds after user scrolling becomes idle. At the end of that interval, if playback is still running, the current active paragraph is smoothly returned to the safe area and normal following resumes.

The following interactions also start the same four-second suppression interval because they represent intentional navigation:

- changing or navigating transcript search results; and
- explicit search-driven paragraph scrolling.

Playback-driven programmatic scrolling does not count as user interaction and therefore does not extend the suppression interval.

If the user scrolls again before the interval expires, the four-second timer restarts. Changing videos, leaving the transcript tab, or removing the active timed transcript cancels pending follow work and resets suppression state.

## State and Data Flow

A small, testable follow-policy value type will decide whether an active paragraph should scroll based on:

- playback state;
- whether user suppression is active;
- the active paragraph frame;
- the viewport frame; and
- the configured safe-area margins.

SwiftUI view state owns the current suppression deadline and cancellable resume task. Geometry preferences carry only the current video ID, paragraph ID, and active paragraph frame so stale measurements from another video cannot trigger scrolling.

The floating interaction uses pure `VideoFloatingLayout` geometry for preview frames. No additional player, window, or persistence layer is introduced.

## Error and Edge Handling

- Missing, empty, stale, or non-finite paragraph geometry produces no scroll.
- Plain transcripts have no timed active paragraph and therefore do not auto-follow.
- A video or tab change invalidates stale geometry and pending resume work.
- Releasing a gesture after the root geometry changes reclamps the final frame to the latest bounds.
- Gesture cancellation commits no invalid frame and leaves the last committed frame reachable.

## Testing

Automated tests will cover:

- drag preview derives from an immutable start frame and remains stable across repeated updates;
- preview and committed frames preserve bounds and aspect ratio;
- active paragraphs inside the safe area do not scroll;
- paragraphs below the lower safe boundary request a follow scroll;
- suppression prevents follow scrolling;
- resumption requests a scroll when the active paragraph is outside the safe area;
- invalid and stale geometry is ignored; and
- the four-second suppression deadline restarts after subsequent user input.

macOS verification will cover smooth pointer movement, all resize corners, uninterrupted playback, manual scroll override, delayed follow resumption, search navigation, and paused playback. The shared DetailView changes must continue to compile for iOS.

## Acceptance Criteria

- The floating player tracks pointer movement smoothly without visible position or size shaking.
- Playback time, rate, poster, subtitles, and controls remain unaffected during drag or resize.
- During playback, the active transcript remains readable as it advances below the viewport.
- Manual scrolling is never immediately counteracted by playback following.
- Following resumes four seconds after the user's last scroll and smoothly returns to the current highlight.
- Search navigation receives the same temporary override.
- The detail page still contains exactly one vertical scroll view.
