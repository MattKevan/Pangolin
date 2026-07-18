# Video Presentation Stability and Platform Design

## Goal

Remove the remaining dock/undock judder, align the inline video exactly with its placeholder, and make video-detail toolbar behavior predictable. The implementation must preserve one uninterrupted player and establish maintainable platform boundaries: macOS and iPad use the workspace-style split layout, while iPhone continues to use stack navigation.

## Platform Model

Presentation decisions will be based on the active application shell rather than scattered `os(macOS)` checks.

- **Workspace shell:** macOS and iPad use `NavigationSplitView`, route-driven toolbar content, the full-width video-detail surface, and the root-hosted inline/floating player.
- **Phone shell:** iPhone keeps its existing `NavigationStack` and pushed video detail. It has no split-view sidebar control, but it still hosts the same persistent inline/floating player within the phone window.

Shared player geometry, transition, and layout policy will remain platform-neutral Swift. Platform-specific view modifiers, safe-area bounds, and input affordances will be kept at the shell edge. This lets both iPad and iPhone retain floating playback with touch-appropriate drag and resize interaction, while preventing desktop navigation assumptions from leaking into the phone stack.

The current device-idiom split is retained for now because it matches the product navigation model. The new policy types will not query `UIDevice`, making a later size-class or window-scene refinement possible without rewriting player behavior.

## Toolbar Ownership

The app will explicitly own the leading workspace toolbar controls instead of conditionally relying on SwiftUI's automatic sidebar item.

On platforms that support removing the automatic split-view sidebar item, it will be removed at the workspace root. Pangolin will provide a custom sidebar button on ordinary workspace routes. The button remains available when the sidebar is collapsed so it can restore the sidebar; “visible sidebar” therefore means a route whose navigation model includes the library sidebar, not only the sidebar's current expanded state.

Video detail is a focused, detail-only workspace route. It shows the video Back button and omits the sidebar button. Leaving video detail restores the ordinary workspace toolbar. iPhone uses the navigation stack's native Back behavior and receives neither the workspace sidebar button nor the workspace-specific replacement Back button.

Toolbar visibility will be derived by a small route-and-shell policy with direct tests, rather than from view nesting side effects.

## Coordinate-Space Contract

The inline placeholder reports its frame in the named workspace-root coordinate space. The persistent-player overlay may have a different local origin because the system toolbar and split-view content can introduce an offset.

Before positioning the player, the root host will convert the placeholder frame from workspace-root coordinates into overlay-local coordinates by subtracting the overlay's frame origin measured in the same named root space. Raw root-space rectangles will never be passed directly to a view that positions in overlay-local coordinates.

The conversion will be a pure function that rejects non-finite or empty geometry and is covered by tests for zero and non-zero overlay origins. This corrects the current toolbar-height vertical offset and makes the contract resilient to iPad toolbar and window-layout differences.

## Persistent Player and Transition Controller

There remains exactly one live `VideoPlayerWithPosterView` for the selected video. Moving between inline and floating presentation changes only its rendered frame and decoration; it never replaces the player or reloads the media.

A focused presentation-frame controller will own the rendered frame and transition phase:

- **Docked:** valid inline geometry follows the placeholder directly with animations disabled, so normal scrolling has no lag.
- **Transitioning:** dock or undock animates from the currently displayed frame to the selected destination over approximately 250 milliseconds. A destination change during the transition is deliberately retargeted from the current presentation instead of starting a second implicit animation.
- **Floating:** the committed floating frame is displayed directly. Drag and resize previews bypass transition animation and update at gesture cadence.

The broad `.animation(value: isFloating)` modifier will be removed from the entire player modifier chain. Only the presentation controller's state transition will create an animation transaction. Shadow and floating controls may animate with the same transition phase but cannot implicitly animate geometry updates.

The transition controller and destination-selection policy will use plain values and remain testable without rendering `AVPlayer`. Player identity remains owned by the shell-level `VideoPlayerViewModel`.

## Floating Behavior Across Platforms

The floating destination remains contained within the Pangolin content region, below the toolbar, while being permitted to overlap the right inspector. Opening the inspector must not recreate or offset the player incorrectly.

macOS preserves pointer drag, keyboard movement, reset, and corner resizing. iPad and iPhone use the same placement and aspect-ratio rules with touch gestures and touch-sized controls. Every platform preserves the video's aspect ratio, allows user resizing up to the usable host bounds rather than an arbitrary product maximum, and retains the saved floating placement until reset or clamping is necessary.

Each shell supplies its own overlay host and usable bounds:

- macOS and iPad use the detail/workspace host, may overlap the inspector, and remain below the toolbar;
- iPhone uses a root overlay above the active navigation-stack content, constrained to the phone window and safe-area/toolbar rules; and
- neither host recreates the player when navigation chrome or available bounds change.

The existing visibility threshold applies while playing or paused. Rapid scrolling across the threshold retargets one transition and cannot create duplicate player instances.

## Phone Behavior

iPhone remains a conventional pushed video-detail screen inside its originating tab's `NavigationStack`:

- navigation uses the native stack Back affordance;
- the inline video participates in document scrolling;
- no sidebar button or split-view column mutation is used;
- when the inline video crosses the visibility threshold, the same persistent player transitions into a phone-bounded floating pane;
- the floating pane remains draggable and resizable with touch while preserving aspect ratio; and
- shared transcript-follow and playback state continue to work.

The phone presentation reuses the shared state machine and geometry policy but supplies its own overlay-local coordinate conversion and safe-area bounds. It is not implemented as a split-view overlay or made dependent on workspace toolbar state.

## State and Lifecycle

Changing the selected video or leaving video detail cancels any transition, clears stale inline geometry, and removes the root presentation only after the route no longer owns it. Returning to a video starts from newly measured geometry and cannot reuse another video's rectangle.

Window resizing, iPad multitasking resizing, toolbar changes, inspector changes, and video aspect-ratio changes recompute valid destinations. Docked layout changes apply directly; floating layout changes clamp through the existing layout policy; active dock/undock changes retarget smoothly.

## Testing

Tests will be written before implementation for:

- conversion from workspace-root frames to overlay-local frames, including a toolbar-sized vertical origin;
- invalid coordinate conversion inputs;
- toolbar policy for ordinary workspace, collapsed workspace sidebar, workspace video detail, and phone video detail;
- overlay-local conversion for workspace and phone hosts;
- direct docked frame updates without animation;
- direct floating gesture updates without animation;
- a single dock/undock transition and smooth destination retargeting;
- transition cancellation when the selected video changes; and
- platform-neutral geometry policy compiling for both macOS and iOS.

Verification will include macOS unit tests and build/run checks, an iPad build with the workspace shell, and an iPhone build with the stack shell. Manual checks will cover dock alignment, slow and rapid threshold crossings, playback continuity, drag and resize on pointer and touch, inspector overlap, phone safe-area containment, sidebar collapse/restore, and native phone Back navigation.

## Acceptance Criteria

- The docked player exactly covers its inline placeholder on macOS, iPad, and iPhone, with no toolbar or safe-area offset.
- Docking, undocking, and rapid reversal are visually smooth and do not shake or flicker.
- Playback continues unaffected while playing or paused.
- Inline scrolling and floating drag/resize remain immediate rather than inheriting transition animation.
- Ordinary macOS and iPad workspace routes provide a restorable sidebar control; video detail provides only its Back control.
- iPhone retains stack-based navigation, keeps floating video, and does not show workspace sidebar controls.
- macOS, iPad, and iPhone targets build successfully, and shared policy behavior is unit tested.

## Out of Scope

- Replacing `NavigationSplitView` with a custom split-view implementation.
- Replacing the iPhone tab and navigation-stack architecture.
- Changing transcript content, player controls, or inspector contents.
