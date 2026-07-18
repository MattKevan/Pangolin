# Animated Video Docking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Animate one persistent video player between its inline and floating frames while preserving playback, stable floating interaction, and correct transcript-follow lifecycle behavior.

**Architecture:** `DetailView` becomes a layout/measurement source for an inline video placeholder, while `MainView` owns one root-level player surface for the active video detail. `FloatingVideoState` stores the validated inline frame and precomputes the floating destination before the visibility state changes; the player surface animates only dock/undock mode changes and keeps drag/resize previews local. Small pure policies cover destination selection and transcript fallback decisions so critical behavior is testable without rendering SwiftUI.

**Tech Stack:** Swift 6, SwiftUI, AVKit-backed existing player view, Swift Testing, Xcode/macOS and iOS Simulator builds.

---

## File Structure

- Modify `Pangolin/Views/Components/VideoFloatingLayout.swift`: define the shared root coordinate space, pure presentation policy, and inline-frame state.
- Modify `Pangolin/Views/Components/FloatingVideoPane.swift`: turn the existing floating-only pane into one persistent docked/floating player surface while retaining local interaction previews.
- Modify `Pangolin/Views/DetailView.swift`: report root-space inline geometry, render only the inline placeholder, and close transcript-follow lifecycle gaps.
- Modify `Pangolin/Views/MainView.swift`: keep one player surface mounted throughout the active video detail and prepare its floating destination before animation.
- Modify `PangolinTests/PangolinTests.swift`: test presentation policy, state reset, animation eligibility, and transcript fallback/reset policy.

### Task 1: Define Player Presentation Geometry

**Files:**
- Modify: `Pangolin/Views/Components/VideoFloatingLayout.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing tests for destination selection and transition eligibility**

Add a suite that exercises valid docked frames, floating frames, stale/invalid inline frames, and mode-only animation:

```swift
@Suite("Video player presentation policy")
struct VideoPlayerPresentationPolicyTests {
    private let inline = CGRect(x: 100, y: 80, width: 800, height: 450)
    private let floating = CGRect(x: 700, y: 40, width: 440, height: 247.5)

    @Test("Docked presentation uses the inline frame")
    func dockedDestination() {
        #expect(VideoPlayerPresentationPolicy.destination(
            isFloating: false,
            inlineFrame: inline,
            floatingFrame: floating
        ) == inline)
    }

    @Test("Floating presentation uses the committed floating frame")
    func floatingDestination() {
        #expect(VideoPlayerPresentationPolicy.destination(
            isFloating: true,
            inlineFrame: inline,
            floatingFrame: floating
        ) == floating)
    }

    @Test("Invalid destinations are rejected")
    func invalidDestination() {
        #expect(VideoPlayerPresentationPolicy.destination(
            isFloating: false,
            inlineFrame: .zero,
            floatingFrame: floating
        ) == nil)
    }

    @Test("Only dock state changes animate")
    func animationEligibility() {
        #expect(VideoPlayerPresentationPolicy.shouldAnimate(from: false, to: true))
        #expect(VideoPlayerPresentationPolicy.shouldAnimate(from: true, to: false))
        #expect(!VideoPlayerPresentationPolicy.shouldAnimate(from: false, to: false))
        #expect(!VideoPlayerPresentationPolicy.shouldAnimate(from: true, to: true))
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPlayerPresentationPolicyTests
```

Expected: compilation fails because `VideoPlayerPresentationPolicy` does not exist.

- [ ] **Step 3: Add the pure policy and inline-frame state**

Add a shared coordinate-space identifier and a policy which validates frames before returning them:

```swift
enum VideoFloatingCoordinateSpace {
    static let root = "videoFloatingRoot"
}

enum VideoPlayerPresentationPolicy {
    static func destination(
        isFloating: Bool,
        inlineFrame: CGRect,
        floatingFrame: CGRect
    ) -> CGRect? {
        let candidate = isFloating ? floatingFrame : inlineFrame
        guard candidate.minX.isFinite,
              candidate.minY.isFinite,
              candidate.width.isFinite,
              candidate.height.isFinite,
              candidate.width > 0,
              candidate.height > 0 else { return nil }
        return candidate
    }

    static func shouldAnimate(from oldValue: Bool, to newValue: Bool) -> Bool {
        oldValue != newValue
    }
}
```

Extend `FloatingVideoState` with `@Published private(set) var inlineFrame = CGRect.zero`, clear it in `reset(for:)`, and add `updateInlineFrame(_:)` that accepts only a finite positive frame. Update the tests to verify a video change clears both destinations and prevents stale geometry reuse.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Task 1 command again.

Expected: all `VideoPlayerPresentationPolicyTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Pangolin/Views/Components/VideoFloatingLayout.swift PangolinTests/PangolinTests.swift
git commit -m "Define video presentation geometry"
```

### Task 2: Mount One Persistent Player Surface

**Files:**
- Modify: `Pangolin/Views/Components/FloatingVideoPane.swift`
- Modify: `Pangolin/Views/MainView.swift`
- Modify: `Pangolin/Views/DetailView.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write a failing state test for preparing the floating destination before undocking**

Add a test proving that a valid inline frame can initialise a nonzero floating destination while still docked:

```swift
@Test("Inline geometry prepares a floating destination before undocking")
@MainActor
func preparesDestinationWhileDocked() {
    let state = FloatingVideoState()
    let videoID = UUID()
    state.reset(for: videoID)
    state.updateInlineFrame(CGRect(x: 120, y: 40, width: 800, height: 450))
    state.updateInlineWidth(800)
    state.prepareFloatingDestination(
        in: CGRect(x: 0, y: 0, width: 1200, height: 800),
        aspectRatio: 16.0 / 9.0
    )

    #expect(!state.isFloating)
    #expect(state.frame != .zero)
}
```

- [ ] **Step 2: Run the focused state test and verify RED**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/FloatingVideoStateTests
```

Expected: compilation fails because `prepareFloatingDestination(in:aspectRatio:)` does not exist.

- [ ] **Step 3: Report the inline slot in root coordinates**

In `DetailView`, keep the aspect-ratio placeholder but remove its conditional `VideoPlayerWithPosterView`. Extend `InlineVideoGeometry` to include `rootFrame`, reported with:

```swift
geometry.frame(in: .named(VideoFloatingCoordinateSpace.root))
```

Validate and publish that frame into `FloatingVideoState` before calling `updateVisibilityMeasurement`. The existing viewport-space frame remains responsible for visible-fraction calculation.

- [ ] **Step 4: Refactor the pane into a persistent docked/floating surface**

Keep `VideoPlayerWithPosterView` structurally unconditional inside `FloatingVideoPane`. Compute its base destination through the policy:

```swift
private var baseFrame: CGRect {
    VideoPlayerPresentationPolicy.destination(
        isFloating: floatingState.isFloating,
        inlineFrame: floatingState.inlineFrame,
        floatingFrame: floatingState.frame
    ) ?? .zero
}

private var renderedFrame: CGRect {
    interactionPreviewFrame ?? baseFrame
}
```

Show the drag handle, reset button, resize handles, and shadow only while floating. Apply the 250 ms ease-in-out animation with `value: floatingState.isFloating`; do not attach animation to `renderedFrame`, `interactionPreviewFrame`, page geometry, or committed drag/resize state. Disable floating gestures and keyboard movement while docked.

- [ ] **Step 5: Keep the root player mounted for the whole active detail**

Apply `.coordinateSpace(name: VideoFloatingCoordinateSpace.root)` to the split-view content. Replace `shouldShowFloatingVideo` with a validity check for the active video and inline frame, and mount `FloatingVideoPane` whenever that check succeeds, regardless of `isFloating`.

Add `FloatingVideoState.prepareFloatingDestination(in:aspectRatio:)`, which calls the existing `prepareDefaultFrame` with the stored `inlineWidth`. On valid inline-frame or root-size changes, call this method so the floating destination exists before the threshold toggles. Keep frame clamping on window and aspect-ratio changes. Allow hit testing whenever the persistent player is visible.

- [ ] **Step 6: Run focused tests and build macOS**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPlayerPresentationPolicyTests
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'
```

Expected: tests pass and `** BUILD SUCCEEDED **` appears.

- [ ] **Step 7: Commit Task 2**

```bash
git add Pangolin/Views/Components/FloatingVideoPane.swift Pangolin/Views/Components/VideoFloatingLayout.swift Pangolin/Views/DetailView.swift Pangolin/Views/MainView.swift PangolinTests/PangolinTests.swift
git commit -m "Animate persistent video docking"
```

### Task 3: Close Transcript-Follow Lifecycle Gaps

**Files:**
- Modify: `Pangolin/Views/DetailView.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing policy tests for missing geometry and active-content removal**

Extend `TranscriptFollowPolicyTests` with explicit fallback decisions:

```swift
@Test("Playing paragraph without geometry uses an ID fallback")
func missingGeometryFallsBack() {
    #expect(TranscriptFollowPolicy.shouldScrollToIDFallback(
        hasActiveParagraph: true,
        hasMeasurement: false,
        isPlaying: true,
        isSuppressed: false
    ))
}

@Test("Suppression prevents the missing-geometry fallback")
func suppressionPreventsFallback() {
    #expect(!TranscriptFollowPolicy.shouldScrollToIDFallback(
        hasActiveParagraph: true,
        hasMeasurement: false,
        isPlaying: true,
        isSuppressed: true
    ))
}

@Test("Removing the active paragraph requires lifecycle reset")
func removalRequiresReset() {
    #expect(TranscriptFollowPolicy.shouldResetLifecycle(activeParagraphID: nil))
    #expect(!TranscriptFollowPolicy.shouldResetLifecycle(activeParagraphID: "paragraph-1"))
}
```

- [ ] **Step 2: Run the focused transcript suite and verify RED**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/TranscriptFollowPolicyTests
```

Expected: compilation fails because the new policy methods do not exist.

- [ ] **Step 3: Implement the minimal lifecycle policies**

Add pure methods that return true only for a playing, unsuppressed active paragraph with no geometry, and for a missing active paragraph respectively. Do not change the four-second suppression calculation.

- [ ] **Step 4: Integrate lazy-row fallback and cancellation**

Pass the current `ScrollViewProxy` into `updateActiveTranscriptParagraph`. After a non-nil ID change clears stale geometry, call `attemptTranscriptFollow(mode: .playbackAdvance, ...)`; when geometry is missing and the fallback policy permits, scroll directly to the active ID once so the lazy row is realised.

When the new active ID is `nil`, cancel `transcriptFollowResumeTask`, clear its deadline, suppression flags, user-scroll flag, active ID, and measurement immediately. Ensure a later transcript cannot inherit the cancelled deadline.

- [ ] **Step 5: Run transcript tests and the complete macOS test suite**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/TranscriptFollowPolicyTests
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'
```

Expected: the focused suite and complete suite pass with zero failures.

- [ ] **Step 6: Commit Task 3**

```bash
git add Pangolin/Views/DetailView.swift PangolinTests/PangolinTests.swift
git commit -m "Harden transcript follow lifecycle"
```

### Task 4: Cross-Platform and Runtime Verification

**Files:**
- Modify only if verification exposes a defect in the files already listed.

- [ ] **Step 1: Build the shared code for iOS Simulator**

Run:

```bash
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run repository verification**

Run:

```bash
./script/build_and_run.sh --verify
git diff --check
git status --short
```

Expected: verification launches successfully, `git diff --check` is silent, and only intentional changes are present.

- [ ] **Step 3: Manually exercise the macOS transitions**

Verify all of the following in Pangolin:

1. Playing video animates inline to floating and back without pausing, flashing a poster, or producing duplicate audio.
2. Paused video performs the same transition.
3. Reversing scroll direction mid-transition retargets smoothly.
4. Docked scrolling tracks the placeholder without lag.
5. Floating drag and resize remain immediate, stable, and aspect-ratio preserving.
6. The player stays below the toolbar, remains inside the window, and may overlap the inspector.
7. A far-away active transcript row is realised and followed unless the user override is active.

- [ ] **Step 4: Commit any verification correction**

If verification required a code correction, add only the affected files and commit with a message describing that correction. If no correction is required, do not create an empty commit.
