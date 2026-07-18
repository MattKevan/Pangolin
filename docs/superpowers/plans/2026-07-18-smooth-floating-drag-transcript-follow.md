# Smooth Floating Drag and Transcript Follow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make floating-player movement visually stable and keep the active timed transcript visible while allowing a four-second manual-scroll override.

**Architecture:** Floating gestures render from view-local preview frames derived in a stable coordinate space and commit once at gesture end. A pure transcript-follow policy decides whether geometry requires scrolling, while `DetailView` owns active-paragraph geometry, scroll phases, suppression timing, and the single outer scroll proxy.

**Tech Stack:** Swift 5, SwiftUI, AVKit, Swift Testing, Xcode 27 beta, macOS 26 deployment target.

---

## File Map

- Modify `Pangolin/Views/Components/VideoFloatingLayout.swift`: add pure stable drag-preview geometry.
- Modify `Pangolin/Views/Components/FloatingVideoPane.swift`: render gesture-local drag/resize preview frames and commit once.
- Modify `Pangolin/Views/DetailView.swift`: add transcript-follow policy, active-row geometry, scroll-phase suppression, and resume timing.
- Modify `PangolinTests/PangolinTests.swift`: cover stable preview geometry and transcript-follow decisions.

### Task 1: Stabilize Floating Drag and Resize

**Files:**
- Modify: `Pangolin/Views/Components/VideoFloatingLayout.swift`
- Modify: `Pangolin/Views/Components/FloatingVideoPane.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing stable-preview tests**

Add tests that call a new helper from an immutable committed frame:

```swift
@Test func dragPreviewUsesImmutableStartFrame() {
    let start = CGRect(x: 600, y: 20, width: 400, height: 225)
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let first = VideoFloatingLayout.draggedFrame(
        from: start,
        translation: CGSize(width: -50, height: 30),
        aspectRatio: 16.0 / 9.0,
        in: bounds
    )
    let repeated = VideoFloatingLayout.draggedFrame(
        from: start,
        translation: CGSize(width: -50, height: 30),
        aspectRatio: 16.0 / 9.0,
        in: bounds
    )
    #expect(first == repeated)
    #expect(first.size == start.size)
    #expect(first.origin == CGPoint(x: 550, y: 50))
}

@Test func dragPreviewClampsWithoutChangingSize() {
    let start = CGRect(x: 400, y: 20, width: 400, height: 225)
    let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
    let preview = VideoFloatingLayout.draggedFrame(
        from: start,
        translation: CGSize(width: 1000, height: 1000),
        aspectRatio: 16.0 / 9.0,
        in: bounds
    )
    #expect(preview.size == start.size)
    #expect(preview.maxX <= bounds.maxX - VideoFloatingLayout.edgeInset)
    #expect(preview.maxY <= bounds.maxY - VideoFloatingLayout.edgeInset)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoFloatingLayoutTests test
```

Expected: compile failure because `draggedFrame` does not exist.

- [ ] **Step 3: Add the pure drag-preview helper**

```swift
static func draggedFrame(
    from startFrame: CGRect,
    translation: CGSize,
    aspectRatio: CGFloat,
    in bounds: CGRect
) -> CGRect {
    fittedFrame(
        startFrame.offsetBy(dx: translation.width, dy: translation.height),
        aspectRatio: aspectRatio,
        in: bounds
    )
}
```

- [ ] **Step 4: Render local gesture previews**

In `FloatingVideoPane`, add:

```swift
@State private var interactionStartFrame: CGRect?
@State private var interactionPreviewFrame: CGRect?

private var renderedFrame: CGRect {
    interactionPreviewFrame ?? floatingState.frame
}
```

Use `renderedFrame` for `.frame` and `.position`. Define drag and resize gestures with `coordinateSpace: .global`. On change, capture `interactionStartFrame` once and update only `interactionPreviewFrame` through `VideoFloatingLayout.draggedFrame` or `VideoFloatingLayout.resizedFrame`. On end, call `floatingState.setFrame` once using the preview and latest root bounds, then clear both local states. Keyboard, reset, and accessibility adjustments remain direct committed operations.

- [ ] **Step 5: Run focused tests and macOS build**

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoFloatingLayoutTests test
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: both exit 0.

- [ ] **Step 6: Commit stable floating interaction**

```bash
git add Pangolin/Views/Components/VideoFloatingLayout.swift Pangolin/Views/Components/FloatingVideoPane.swift PangolinTests/PangolinTests.swift
git commit -m "Smooth floating video interaction"
```

### Task 2: Add a Pure Transcript-Follow Policy

**Files:**
- Modify: `Pangolin/Views/DetailView.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing follow-policy tests**

Add `TranscriptFollowPolicyTests` covering these exact cases:

```swift
@Test func playbackScrollsWhenActiveParagraphCrossesBottomBoundary() {
    let viewport = CGRect(x: 0, y: 0, width: 760, height: 700)
    let paragraph = CGRect(x: 100, y: 650, width: 560, height: 80)
    #expect(TranscriptFollowPolicy.shouldScroll(
        paragraphFrame: paragraph,
        viewport: viewport,
        isPlaying: true,
        isSuppressed: false,
        mode: .playbackAdvance
    ))
}
```

Also test a paragraph inside the safe area, suppression, paused playback, resume with a paragraph above the viewport, and invalid/non-finite geometry.

- [ ] **Step 2: Run policy tests and verify RED**

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/TranscriptFollowPolicyTests test
```

Expected: compile failure because `TranscriptFollowPolicy` does not exist.

- [ ] **Step 3: Implement the minimal policy**

Add near the detail geometry preference types:

```swift
enum TranscriptFollowMode {
    case playbackAdvance
    case resume
}

enum TranscriptFollowPolicy {
    static let bottomMargin: CGFloat = 96
    static let topMargin: CGFloat = 40
    static let suppressionDuration: Duration = .seconds(4)

    static func shouldScroll(
        paragraphFrame: CGRect,
        viewport: CGRect,
        isPlaying: Bool,
        isSuppressed: Bool,
        mode: TranscriptFollowMode
    ) -> Bool {
        guard isPlaying, !isSuppressed,
              isValid(paragraphFrame), isValid(viewport) else { return false }
        let below = paragraphFrame.maxY > viewport.maxY - bottomMargin
        let above = paragraphFrame.minY < viewport.minY + topMargin
        return below || (mode == .resume && above)
    }
}
```

Keep `isValid` private to the policy and require finite origins and positive finite sizes.

- [ ] **Step 4: Run policy tests and verify GREEN**

Run the focused policy command again. Expected: all policy tests pass.

- [ ] **Step 5: Commit the follow policy**

```bash
git add Pangolin/Views/DetailView.swift PangolinTests/PangolinTests.swift
git commit -m "Define transcript follow policy"
```

### Task 3: Integrate Active-Paragraph Following and User Override

**Files:**
- Modify: `Pangolin/Views/DetailView.swift`

- [ ] **Step 1: Report active-paragraph geometry**

Define an optional preference payload containing `videoID`, `paragraphID`, and `frame`. In the active timed paragraph row, attach a `GeometryReader` background that reports its frame in `DetailView.detailViewportCoordinateSpace`. Plain rows report nothing.

Extend `MergedTranscriptView` with `onActiveParagraphChange: (String?) -> Void`. Invoke it only when `updateActiveParagraph` changes the ID and clear it when timed content disappears.

- [ ] **Step 2: Add outer-scroll follow state**

Add to `DetailView`:

```swift
@State private var activeTranscriptParagraphID: String?
@State private var activeTranscriptMeasurement: ActiveTranscriptGeometry?
@State private var isTranscriptFollowSuppressed = false
@State private var isUserScrollingTranscript = false
@State private var transcriptFollowResumeTask: Task<Void, Never>?
```

Cancel and reset these values when the video changes, the selected tab leaves Transcript, or video detail disappears.

- [ ] **Step 3: Detect direct user scrolling**

On the single outer `ScrollView`, handle phases:

```swift
case .tracking, .interacting, .decelerating:
    beginUserScrollOverride()
case .idle:
    finishUserScrollAndScheduleResume(proxy: proxy, videoID: selectedVideo.id)
case .animating:
    break
```

User phases immediately suppress following and cancel the pending task. Idle schedules a new four-second task. Programmatic animation does not extend suppression.

- [ ] **Step 4: Suppress following for search navigation**

Before existing search-driven `proxy.scrollTo` calls, start the same cancellable four-second interval. Do not classify the resulting `.animating` phase as manual scrolling.

- [ ] **Step 5: Evaluate follow requests**

On active paragraph ID or geometry change, evaluate `.playbackAdvance`. If the policy returns true, animate `proxy.scrollTo(paragraphID, anchor: .center)` over about 0.2 seconds.

When the four-second task completes, validate captured video ID, Transcript tab, active paragraph ID, and playback state; clear suppression and evaluate `.resume`. If active-row geometry is absent because the lazy row is offscreen, scroll the known active ID directly.

- [ ] **Step 6: Verify lifecycle and the one-scroll structure**

```bash
rg -n "ScrollView|ScrollViewReader" Pangolin/Views/DetailView.swift
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests test
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-TranscriptFollow-iOS build
```

Expected: the page retains one outer vertical `ScrollView`; tests pass; both builds exit 0.

- [ ] **Step 7: Commit transcript following**

```bash
git add Pangolin/Views/DetailView.swift PangolinTests/PangolinTests.swift
git commit -m "Follow active transcript during playback"
```

### Task 4: Final Interaction Verification

**Files:**
- Verify all changed production and test files.

- [ ] **Step 1: Run repository checks**

```bash
git diff --check
plutil -lint Pangolin.xcodeproj/project.pbxproj
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -showBuildSettings >/dev/null
```

- [ ] **Step 2: Run the full test and build matrix**

Run the full macOS unit target and fresh macOS/iOS builds. Read the macOS result bundle and confirm zero failures and skips.

- [ ] **Step 3: Run the app and verify interactions**

Use `./script/build_and_run.sh --verify`, then verify with a populated timed transcript where available:

1. Drag slowly and quickly; position and size remain stable.
2. Resize from each corner; preview remains smooth and ratio-constrained.
3. Let playback cross the lower safe boundary; the highlight scrolls into view.
4. Scroll manually; follow remains suspended for four seconds after idle.
5. Scroll again during suppression; the timer restarts.
6. After four seconds, the highlight returns smoothly and following resumes.
7. Navigate search results; the same override applies.
8. Pause playback; no follow scrolling occurs.

Do not claim visual checks the desktop session cannot expose.

- [ ] **Step 4: Commit only necessary verification polish**

If verification reveals a defect, add a failing regression test, fix it, rerun Steps 1–3, and commit:

```bash
git commit -m "Polish floating drag and transcript follow"
```

Do not create an empty commit.
