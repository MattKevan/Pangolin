# Scrollable Video Detail and Floating Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the video detail page one continuous scrollable document and automatically move the existing player into a draggable, aspect-ratio-preserving floating pane when the inline player mostly leaves view.

**Architecture:** `MainView` will own the existing `VideoPlayerViewModel` plus a presentation-only `FloatingVideoState`, allowing a window-level overlay to sit above the detail page and right inspector while remaining below the toolbar. `DetailView` will use one outer `ScrollView`, report inline-player visibility, and render either the inline player or an equal-sized placeholder. Pure `VideoFloatingLayout` calculations will own thresholds, aspect ratio, placement, resize, and clamping so behaviour is testable without rendering SwiftUI.

**Tech Stack:** Swift 5, SwiftUI, AVKit/AVFoundation, AppKit on macOS, Swift Testing, Xcode 27 beta with macOS 26 deployment target.

---

## File Map

- Create `Pangolin/Views/Components/VideoFloatingLayout.swift`: pure geometry rules and `FloatingVideoState`.
- Create `Pangolin/Views/Components/FloatingVideoPane.swift`: macOS floating player chrome, dragging, resizing, and keyboard/accessibility actions.
- Modify `Pangolin.xcodeproj/project.pbxproj`: register the two production files with the Components group and Pangolin target.
- Modify `PangolinTests/PangolinTests.swift`: test floating thresholds, aspect ratio, placement, resizing, clamping, and reset behaviour without adding another project reference.
- Modify `Pangolin/ViewModels/VideoPlayerViewModel.swift`: expose the selected video's aspect ratio without replacing the player.
- Modify `Pangolin/Views/MainView.swift`: own shared player/presentation state and render the floating layer above the split view and inspector.
- Modify `Pangolin/Views/DetailView.swift`: build one outer scroll view, report inline visibility, keep a placeholder while floating, and route transcript search scrolling.
- Modify `Pangolin/Views/Components/SummaryView.swift`: remove its nested scroll view.

## Project Registration IDs

Use these fixed, unused identifiers when editing `project.pbxproj` so later steps and reviews refer to the same entries:

```text
F20A00000000000000000001  VideoFloatingLayout.swift file reference
F20A00000000000000000002  VideoFloatingLayout.swift build file
F20A00000000000000000003  FloatingVideoPane.swift file reference
F20A00000000000000000004  FloatingVideoPane.swift build file
```

### Task 1: Test and Implement Floating Geometry

**Files:**
- Create: `Pangolin/Views/Components/VideoFloatingLayout.swift`
- Modify: `PangolinTests/PangolinTests.swift`
- Modify: `Pangolin.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing layout tests**

Append this suite to `PangolinTests/PangolinTests.swift`:

```swift
@Suite("Video floating layout")
struct VideoFloatingLayoutTests {
    @Test("Floating uses hysteresis")
    func floatingUsesHysteresis() {
        #expect(VideoFloatingLayout.shouldFloat(isFloating: false, visibleFraction: 0.25))
        #expect(!VideoFloatingLayout.shouldFloat(isFloating: false, visibleFraction: 0.26))
        #expect(VideoFloatingLayout.shouldFloat(isFloating: true, visibleFraction: 0.59))
        #expect(!VideoFloatingLayout.shouldFloat(isFloating: true, visibleFraction: 0.60))
    }

    @Test("Resolution determines aspect ratio with a sixteen by nine fallback")
    func aspectRatioParsing() {
        #expect(VideoFloatingLayout.aspectRatio(for: "1920x1080") == 16.0 / 9.0)
        #expect(VideoFloatingLayout.aspectRatio(for: "1080x1920") == 9.0 / 16.0)
        #expect(VideoFloatingLayout.aspectRatio(for: nil) == 16.0 / 9.0)
        #expect(VideoFloatingLayout.aspectRatio(for: "invalid") == 16.0 / 9.0)
    }

    @Test("Default frame starts at top right and uses fifty five percent width")
    func defaultFramePlacement() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: 16.0 / 9.0
        )

        #expect(abs(frame.width - 418) < 0.01)
        #expect(abs(frame.height - 235.125) < 0.01)
        #expect(abs(frame.maxX - 1184) < 0.01)
        #expect(abs(frame.minY - 16) < 0.01)
    }

    @Test("Resize preserves ratio and the opposite corner")
    func resizePreservesRatio() {
        let start = CGRect(x: 700, y: 16, width: 400, height: 225)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let resized = VideoFloatingLayout.resizedFrame(
            from: start,
            handle: .bottomLeading,
            translation: CGSize(width: -100, height: 20),
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )

        #expect(abs(resized.width / resized.height - 16.0 / 9.0) < 0.001)
        #expect(abs(resized.maxX - start.maxX) < 0.01)
        #expect(abs(resized.minY - start.minY) < 0.01)
    }

    @Test("Frames are clamped inside available bounds")
    func clamping() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let frame = CGRect(x: 800, y: 550, width: 400, height: 225)
        let clamped = VideoFloatingLayout.fittedFrame(
            frame,
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )

        #expect(clamped.minX >= 16)
        #expect(clamped.minY >= 16)
        #expect(clamped.maxX <= 884)
        #expect(clamped.maxY <= 584)
        #expect(abs(clamped.width / clamped.height - 16.0 / 9.0) < 0.001)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/PangolinTests test
```

Expected: compilation fails because `VideoFloatingLayout` and `VideoResizeHandle` do not exist.

- [ ] **Step 3: Create the geometry implementation**

Create `Pangolin/Views/Components/VideoFloatingLayout.swift`:

```swift
import CoreGraphics
import Foundation

enum VideoResizeHandle: CaseIterable, Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

enum VideoFloatingLayout {
    static let floatVisibleFraction = 0.25
    static let dockVisibleFraction = 0.60
    static let initialWidthScale = 0.55
    static let minimumWidth: CGFloat = 240
    static let edgeInset: CGFloat = 16
    static let fallbackAspectRatio: CGFloat = 16.0 / 9.0

    static func shouldFloat(isFloating: Bool, visibleFraction: Double) -> Bool {
        let fraction = min(max(visibleFraction, 0), 1)
        return isFloating ? fraction < dockVisibleFraction : fraction <= floatVisibleFraction
    }

    static func aspectRatio(for resolution: String?) -> CGFloat {
        guard let resolution else { return fallbackAspectRatio }
        let parts = resolution.lowercased().split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return fallbackAspectRatio
        }
        return CGFloat(width / height)
    }

    static func defaultFrame(
        in bounds: CGRect,
        inlineWidth: CGFloat,
        aspectRatio: CGFloat
    ) -> CGRect {
        let ratio = validRatio(aspectRatio)
        let requestedWidth = max(minimumWidth, inlineWidth * initialWidthScale)
        let size = fittedSize(width: requestedWidth, aspectRatio: ratio, in: bounds)
        return CGRect(
            x: bounds.maxX - edgeInset - size.width,
            y: bounds.minY + edgeInset,
            width: size.width,
            height: size.height
        )
    }

    static func fittedFrame(
        _ frame: CGRect,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let size = fittedSize(width: frame.width, aspectRatio: aspectRatio, in: bounds)
        let minimumX = bounds.minX + edgeInset
        let minimumY = bounds.minY + edgeInset
        let maximumX = max(minimumX, bounds.maxX - edgeInset - size.width)
        let maximumY = max(minimumY, bounds.maxY - edgeInset - size.height)
        return CGRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: size.width,
            height: size.height
        )
    }

    static func resizedFrame(
        from frame: CGRect,
        handle: VideoResizeHandle,
        translation: CGSize,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let ratio = validRatio(aspectRatio)
        let horizontalDelta: CGFloat
        let verticalDelta: CGFloat
        switch handle {
        case .topLeading:
            horizontalDelta = -translation.width
            verticalDelta = -translation.height * ratio
        case .topTrailing:
            horizontalDelta = translation.width
            verticalDelta = -translation.height * ratio
        case .bottomLeading:
            horizontalDelta = -translation.width
            verticalDelta = translation.height * ratio
        case .bottomTrailing:
            horizontalDelta = translation.width
            verticalDelta = translation.height * ratio
        }

        let delta = abs(horizontalDelta) >= abs(verticalDelta) ? horizontalDelta : verticalDelta
        let requestedWidth = max(minimumWidth, frame.width + delta)
        let size = fittedSize(width: requestedWidth, aspectRatio: ratio, in: bounds)
        let origin: CGPoint
        switch handle {
        case .topLeading:
            origin = CGPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        case .topTrailing:
            origin = CGPoint(x: frame.minX, y: frame.maxY - size.height)
        case .bottomLeading:
            origin = CGPoint(x: frame.maxX - size.width, y: frame.minY)
        case .bottomTrailing:
            origin = frame.origin
        }
        return fittedFrame(CGRect(origin: origin, size: size), aspectRatio: ratio, in: bounds)
    }

    private static func fittedSize(
        width: CGFloat,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGSize {
        let ratio = validRatio(aspectRatio)
        let availableWidth = max(1, bounds.width - edgeInset * 2)
        let availableHeight = max(1, bounds.height - edgeInset * 2)
        var fittedWidth = min(max(minimumWidth, width), availableWidth)
        var fittedHeight = fittedWidth / ratio
        if fittedHeight > availableHeight {
            fittedHeight = availableHeight
            fittedWidth = fittedHeight * ratio
        }
        return CGSize(width: fittedWidth, height: fittedHeight)
    }

    private static func validRatio(_ ratio: CGFloat) -> CGFloat {
        ratio.isFinite && ratio > 0 ? ratio : fallbackAspectRatio
    }
}
```

- [ ] **Step 4: Register `VideoFloatingLayout.swift` with the app target**

Edit `Pangolin.xcodeproj/project.pbxproj` in four places:

```text
PBXBuildFile:
F20A00000000000000000002 /* VideoFloatingLayout.swift in Sources */ = {isa = PBXBuildFile; fileRef = F20A00000000000000000001 /* VideoFloatingLayout.swift */; };

PBXFileReference:
F20A00000000000000000001 /* VideoFloatingLayout.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = VideoFloatingLayout.swift; sourceTree = "<group>"; };

Components group children:
F20A00000000000000000001 /* VideoFloatingLayout.swift */,

Pangolin Sources build phase:
F20A00000000000000000002 /* VideoFloatingLayout.swift in Sources */,
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the Step 2 command again.

Expected: all `PangolinTests` tests selected by the command pass, including five `VideoFloatingLayoutTests`.

- [ ] **Step 6: Commit the geometry engine**

```bash
git add Pangolin/Views/Components/VideoFloatingLayout.swift PangolinTests/PangolinTests.swift Pangolin.xcodeproj/project.pbxproj
git commit -m "Test floating video geometry"
```

### Task 2: Test and Implement Floating Presentation State

**Files:**
- Modify: `Pangolin/Views/Components/VideoFloatingLayout.swift`
- Modify: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing state tests**

Add this suite below `VideoFloatingLayoutTests`:

```swift
@Suite("Floating video state")
@MainActor
struct FloatingVideoStateTests {
    @Test("Visibility uses hysteresis without resetting geometry")
    func visibilityUsesHysteresis() {
        let state = FloatingVideoState()
        let videoID = UUID()
        state.reset(for: videoID)
        state.prepareDefaultFrame(
            in: CGRect(x: 0, y: 0, width: 1200, height: 800),
            inlineWidth: 760,
            aspectRatio: 16.0 / 9.0
        )
        let originalFrame = state.frame

        state.updateVisibleFraction(0.20)
        #expect(state.isFloating)
        state.updateVisibleFraction(0.40)
        #expect(state.isFloating)
        #expect(state.frame == originalFrame)
        state.updateVisibleFraction(0.70)
        #expect(!state.isFloating)
    }

    @Test("A new video resets placement")
    func videoReset() {
        let state = FloatingVideoState()
        let firstID = UUID()
        state.reset(for: firstID)
        state.prepareDefaultFrame(
            in: CGRect(x: 0, y: 0, width: 1200, height: 800),
            inlineWidth: 760,
            aspectRatio: 16.0 / 9.0
        )
        state.move(by: CGSize(width: -100, height: 100), in: CGRect(x: 0, y: 0, width: 1200, height: 800), aspectRatio: 16.0 / 9.0)

        state.reset(for: UUID())

        #expect(!state.isFloating)
        #expect(state.frame == .zero)
        #expect(state.videoID != firstID)
    }

    @Test("Setting a drag frame clamps the proposed position")
    func settingDragFrameClampsPosition() {
        let state = FloatingVideoState()
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        state.reset(for: UUID())
        state.setFrame(
            CGRect(x: 850, y: 580, width: 320, height: 180),
            in: bounds,
            aspectRatio: 16.0 / 9.0
        )

        #expect(state.frame.maxX <= 884)
        #expect(state.frame.maxY <= 584)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run the Task 1 Step 2 command.

Expected: compilation fails because `FloatingVideoState` does not exist.

- [ ] **Step 3: Add the presentation state model**

Append this implementation to `VideoFloatingLayout.swift`:

```swift
import SwiftUI

@MainActor
final class FloatingVideoState: ObservableObject {
    @Published private(set) var isFloating = false
    @Published private(set) var frame: CGRect = .zero
    @Published private(set) var videoID: UUID?

    func reset(for videoID: UUID?) {
        guard self.videoID != videoID else { return }
        self.videoID = videoID
        isFloating = false
        frame = .zero
    }

    func prepareDefaultFrame(in bounds: CGRect, inlineWidth: CGFloat, aspectRatio: CGFloat) {
        guard frame == .zero else {
            frame = VideoFloatingLayout.fittedFrame(frame, aspectRatio: aspectRatio, in: bounds)
            return
        }
        frame = VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        )
    }

    func updateVisibleFraction(_ visibleFraction: Double) {
        isFloating = VideoFloatingLayout.shouldFloat(
            isFloating: isFloating,
            visibleFraction: visibleFraction
        )
    }

    func move(by translation: CGSize, in bounds: CGRect, aspectRatio: CGFloat) {
        let proposed = frame.offsetBy(dx: translation.width, dy: translation.height)
        setFrame(proposed, in: bounds, aspectRatio: aspectRatio)
    }

    func setFrame(_ proposedFrame: CGRect, in bounds: CGRect, aspectRatio: CGFloat) {
        frame = VideoFloatingLayout.fittedFrame(
            proposedFrame,
            aspectRatio: aspectRatio,
            in: bounds
        )
    }

    func resize(
        from startFrame: CGRect,
        handle: VideoResizeHandle,
        translation: CGSize,
        in bounds: CGRect,
        aspectRatio: CGFloat
    ) {
        frame = VideoFloatingLayout.resizedFrame(
            from: startFrame,
            handle: handle,
            translation: translation,
            aspectRatio: aspectRatio,
            in: bounds
        )
    }

    func clamp(to bounds: CGRect, aspectRatio: CGFloat) {
        guard frame != .zero else { return }
        frame = VideoFloatingLayout.fittedFrame(frame, aspectRatio: aspectRatio, in: bounds)
    }

    func resetPlacement(in bounds: CGRect, inlineWidth: CGFloat, aspectRatio: CGFloat) {
        frame = VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        )
    }
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Task 1 Step 2 command.

Expected: all selected tests pass, including both `FloatingVideoStateTests`.

- [ ] **Step 5: Commit presentation state**

```bash
git add Pangolin/Views/Components/VideoFloatingLayout.swift PangolinTests/PangolinTests.swift
git commit -m "Add floating video presentation state"
```

### Task 3: Share One Player and Derive Its Aspect Ratio

**Files:**
- Modify: `Pangolin/ViewModels/VideoPlayerViewModel.swift`
- Modify: `Pangolin/Views/MainView.swift`
- Modify: `Pangolin/Views/DetailView.swift`

- [ ] **Step 1: Move player ownership to `MainView`**

Add alongside `folderStore` in `MainView`:

```swift
@StateObject private var videoPlayerViewModel = VideoPlayerViewModel()
@StateObject private var floatingVideoState = FloatingVideoState()
```

Change `DetailView` from a private `@StateObject` to an injected observed object:

```swift
@ObservedObject var playerViewModel: VideoPlayerViewModel

init(video: Video?, playerViewModel: VideoPlayerViewModel) {
    self.video = video
    self.playerViewModel = playerViewModel
}
```

Remove this line from `DetailView`:

```swift
@StateObject private var playerViewModel = VideoPlayerViewModel()
```

Update every `DetailView(video:)` call in `MainView.swift` to pass `videoPlayerViewModel`:

```swift
DetailView(video: video, playerViewModel: videoPlayerViewModel)
```

- [ ] **Step 2: Expose a stable aspect ratio from the player view model**

Add to `VideoPlayerViewModel`:

```swift
@Published private(set) var videoAspectRatio: CGFloat = VideoFloatingLayout.fallbackAspectRatio
```

At the start of `loadVideo(_:, autoPlay:)`, after assigning `currentVideo`, add:

```swift
videoAspectRatio = VideoFloatingLayout.aspectRatio(for: video.resolution)
```

In `clearLoadedVideo()`, add:

```swift
videoAspectRatio = VideoFloatingLayout.fallbackAspectRatio
```

This reads existing imported metadata and uses 16:9 until valid dimensions are available. Do not create or replace an `AVPlayer` in response to a floating-state change.

- [ ] **Step 3: Reset floating state on video changes**

In `DetailView`'s existing selected-video change handling, add:

```swift
floatingVideoState.reset(for: selected.id)
```

Inject `FloatingVideoState` into `DetailView` as another observed object:

```swift
@ObservedObject var floatingVideoState: FloatingVideoState
```

and pass it from every `MainView` call:

```swift
DetailView(
    video: video,
    playerViewModel: videoPlayerViewModel,
    floatingVideoState: floatingVideoState
)
```

- [ ] **Step 4: Build to catch ownership and initializer errors**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: exit code 0. Existing warnings are permitted; there must be no Swift compile errors.

- [ ] **Step 5: Commit shared player ownership**

```bash
git add Pangolin/ViewModels/VideoPlayerViewModel.swift Pangolin/Views/MainView.swift Pangolin/Views/DetailView.swift
git commit -m "Share video player across detail presentations"
```

### Task 4: Convert the Detail Page to One Scroll View

**Files:**
- Modify: `Pangolin/Views/DetailView.swift`
- Modify: `Pangolin/Views/Components/SummaryView.swift`

- [ ] **Step 1: Remove the nested summary scroll view**

Replace `SummaryView.body` with non-scrolling content:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 16) {
        content
    }
    .padding(.vertical)
    .frame(maxWidth: VideoDetailLayout.contentMaxWidth, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, VideoDetailLayout.horizontalPadding)
}
```

- [ ] **Step 2: Give transcript content an outer-scroll callback**

Add to `MergedTranscriptView`:

```swift
let onRequestScrollToParagraph: (String) -> Void
```

Replace its `ScrollViewReader { ScrollView { ... } }` wrappers with its existing content `VStack` directly. Keep paragraph `.id(paragraph.id)` modifiers. Change search helpers to remove `ScrollViewProxy` parameters:

```swift
private func moveAcrossSearchResults() {
    let matches = matchingParagraphIDs
    guard !matches.isEmpty else {
        currentMatchID = nil
        searchModel.setSearchState(totalMatches: 0, currentMatchIndex: nil)
        return
    }

    let currentIndex = currentMatchID.flatMap { matches.firstIndex(of: $0) }
    let nextIndex: Int
    switch searchModel.direction {
    case .next:
        nextIndex = ((currentIndex ?? -1) + 1 + matches.count) % matches.count
    case .previous:
        nextIndex = ((currentIndex ?? 0) - 1 + matches.count) % matches.count
    }

    currentMatchID = matches[nextIndex]
    searchModel.setSearchState(totalMatches: matches.count, currentMatchIndex: nextIndex)
    onRequestScrollToParagraph(matches[nextIndex])
}

private func refreshSearchState(scrollToMatch: Bool) {
    let matches = matchingParagraphIDs
    guard !matches.isEmpty else {
        currentMatchID = nil
        searchModel.setSearchState(totalMatches: 0, currentMatchIndex: nil)
        return
    }

    let nextMatchID = currentMatchID.flatMap { matches.contains($0) ? $0 : nil } ?? matches[0]
    currentMatchID = nextMatchID
    searchModel.setSearchState(
        totalMatches: matches.count,
        currentMatchIndex: matches.firstIndex(of: nextMatchID) ?? 0
    )
    if scrollToMatch {
        onRequestScrollToParagraph(nextMatchID)
    }
}
```

Use `refreshSearchState(scrollToMatch: false)` after content reloads, `refreshSearchState(scrollToMatch: true)` when the query changes, and `moveAcrossSearchResults()` for navigation requests. Delete the existing `onChange(of: activeParagraphID)` auto-scroll block; active paragraphs continue highlighting without moving the outer page.

- [ ] **Step 3: Build one outer detail scroll view**

Replace `page(for:)` with this structure:

```swift
@ViewBuilder
private func page(for selectedVideo: Video) -> some View {
    ScrollViewReader { pageProxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                header(for: selectedVideo)
                Divider()

                if isSearchVisibleOnPhone && selectedInspectorTab == .transcript {
                    inlineSearchField
                        .padding(.horizontal, VideoDetailLayout.horizontalPadding)
                        .padding(.vertical, 12)
                    Divider()
                }

                VideoPageTabPicker(selectedTab: $selectedInspectorTab)
                    .frame(maxWidth: VideoDetailLayout.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, VideoDetailLayout.horizontalPadding)
                    .padding(.top, 12)

                currentContent(for: selectedVideo) { paragraphID in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        pageProxy.scrollTo(paragraphID, anchor: .center)
                    }
                }

                navigationBar(for: selectedVideo)
            }
        }
        .coordinateSpace(name: VideoDetailCoordinateSpace.viewport)
        .scrollPosition(id: $pageScrollPosition, anchor: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appContentBackground)
}
```

Add:

```swift
private enum VideoDetailCoordinateSpace {
    static let viewport = "video-detail-viewport"
}

@State private var pageScrollPosition: UUID?
```

Update `currentContent` to accept and pass the callback:

```swift
private func currentContent(
    for selectedVideo: Video,
    onRequestScrollToParagraph: @escaping (String) -> Void
) -> some View
```

When the selected video changes, set `pageScrollPosition = selected.id` and add `.id(selectedVideo.id)` to the header so the scroll position resets to its top.

- [ ] **Step 4: Build and manually confirm there is one scrollbar**

Run the Task 3 Step 4 build command, then launch Pangolin and open a video with a long transcript.

Expected: the video, title, tabs, text, and Previous/Next controls move under one scrollbar. Transcript and summary show no inner scrollbar, and changing search matches scrolls the page to the matching paragraph.

- [ ] **Step 5: Commit continuous scrolling**

```bash
git add Pangolin/Views/DetailView.swift Pangolin/Views/Components/SummaryView.swift
git commit -m "Make video details one scrollable page"
```

### Task 5: Report Inline Visibility and Preserve Its Layout Slot

**Files:**
- Modify: `Pangolin/Views/DetailView.swift`

- [ ] **Step 1: Add a pure visible-fraction helper test**

Add to `VideoFloatingLayoutTests` in `PangolinTests.swift`:

```swift
@Test("Visible fraction measures vertical intersection")
func visibleFraction() {
    let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
    let halfVisible = CGRect(x: 20, y: -200, width: 760, height: 400)
    #expect(abs(VideoFloatingLayout.visibleFraction(of: halfVisible, in: viewport) - 0.5) < 0.001)
    #expect(VideoFloatingLayout.visibleFraction(of: CGRect(x: 20, y: -500, width: 760, height: 400), in: viewport) == 0)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run the Task 1 Step 2 command.

Expected: compilation fails because `visibleFraction(of:in:)` is missing.

- [ ] **Step 3: Implement visible fraction**

Add to `VideoFloatingLayout`:

```swift
static func visibleFraction(of frame: CGRect, in viewport: CGRect) -> Double {
    guard frame.height > 0 else { return 0 }
    let visibleHeight = frame.intersection(viewport).height
    return Double(min(max(visibleHeight / frame.height, 0), 1))
}
```

- [ ] **Step 4: Add an inline-frame preference**

Add near `VideoDetailCoordinateSpace` in `DetailView.swift`:

```swift
private struct InlineVideoFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
```

Wrap the inline player location in a named helper:

```swift
private func inlinePlayer(for video: Video) -> some View {
    Group {
        if floatingVideoState.isFloating {
            Color.black.opacity(0.08)
                .overlay {
                    Label("Video is floating", systemImage: "pip.fill")
                        .foregroundStyle(.secondary)
                }
        } else {
            VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .aspectRatio(playerViewModel.videoAspectRatio, contentMode: .fit)
    .background {
        GeometryReader { proxy in
            Color.clear.preference(
                key: InlineVideoFramePreferenceKey.self,
                value: proxy.frame(in: .named(VideoDetailCoordinateSpace.viewport))
            )
        }
    }
}
```

Use `inlinePlayer(for:)` in `header(for:)` and remove the hard-coded `16.0 / 9.0` modifier.

- [ ] **Step 5: Update floating state from the viewport**

Place a `GeometryReader` around the outer page and calculate the viewport from its local bounds:

```swift
.onPreferenceChange(InlineVideoFramePreferenceKey.self) { frame in
    let viewport = CGRect(origin: .zero, size: viewportSize)
    inlinePlayerWidth = frame.width
    floatingVideoState.updateVisibleFraction(
        VideoFloatingLayout.visibleFraction(of: frame, in: viewport)
    )
}
```

Add state for `viewportSize` and `inlinePlayerWidth`, update `viewportSize` from the outer `GeometryReader`, and report positive inline widths to `MainView` through `onInlineWidthChange`. Do not prepare the floating frame from the narrower detail viewport; Task 6 prepares it from the split-view-root bounds so its default placement can overlap the inspector. The placeholder remains exactly the same aspect-ratio-derived size as the inline player.

- [ ] **Step 6: Run tests and build**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/PangolinTests test
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: both commands exit 0.

- [ ] **Step 7: Commit inline visibility tracking**

```bash
git add Pangolin/Views/DetailView.swift Pangolin/Views/Components/VideoFloatingLayout.swift PangolinTests/PangolinTests.swift
git commit -m "Track inline video visibility"
```

### Task 6: Render the Draggable and Resizable Window-Level Pane

**Files:**
- Create: `Pangolin/Views/Components/FloatingVideoPane.swift`
- Modify: `Pangolin.xcodeproj/project.pbxproj`
- Modify: `Pangolin/Views/MainView.swift`

- [ ] **Step 1: Create `FloatingVideoPane`**

Create `Pangolin/Views/Components/FloatingVideoPane.swift`:

```swift
import SwiftUI

#if os(macOS)
struct FloatingVideoPane: View {
    let video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject var floatingState: FloatingVideoState
    let availableBounds: CGRect
    let inlineWidth: CGFloat

    @State private var dragStartFrame: CGRect?
    @State private var resizeStartFrames: [VideoResizeHandle: CGRect] = [:]
    @FocusState private var isFocused: Bool

    var body: some View {
        VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
            .frame(width: floatingState.frame.width, height: floatingState.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .top) { dragHandle }
            .overlay(alignment: .topTrailing) { resetButton }
            .overlay { resizeHandles }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .position(x: floatingState.frame.midX, y: floatingState.frame.midY)
            .focusable()
            .focused($isFocused)
            .onMoveCommand(perform: moveWithKeyboard)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Floating video player")
            .accessibilityValue("Position (Int(floatingState.frame.minX)), (Int(floatingState.frame.minY)); width (Int(floatingState.frame.width))")
            .accessibilityAction(named: "Reset position") {
                floatingState.resetPlacement(
                    in: availableBounds,
                    inlineWidth: inlineWidth,
                    aspectRatio: playerViewModel.videoAspectRatio
                )
            }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(.white.opacity(0.8))
            .frame(width: 44, height: 5)
            .padding(8)
            .contentShape(Rectangle())
            .accessibilityLabel("Move floating video")
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartFrame ?? floatingState.frame
                        dragStartFrame = start
                        let proposed = CGRect(
                            x: start.minX + value.translation.width,
                            y: start.minY + value.translation.height,
                            width: start.width,
                            height: start.height
                        )
                        floatingState.setFrame(
                            proposed,
                            in: availableBounds,
                            aspectRatio: playerViewModel.videoAspectRatio
                        )
                    }
                    .onEnded { _ in dragStartFrame = nil }
            )
    }

    private var resizeHandles: some View {
        ZStack {
            resizeHandle(.topLeading, alignment: .topLeading)
            resizeHandle(.topTrailing, alignment: .topTrailing)
            resizeHandle(.bottomLeading, alignment: .bottomLeading)
            resizeHandle(.bottomTrailing, alignment: .bottomTrailing)
        }
    }

    private var resetButton: some View {
        Button {
            floatingState.resetPlacement(
                in: availableBounds,
                inlineWidth: inlineWidth,
                aspectRatio: playerViewModel.videoAspectRatio
            )
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(18)
        .keyboardShortcut("0", modifiers: [.command, .option])
        .accessibilityLabel("Reset floating video position")
    }

    private func resizeHandle(_ handle: VideoResizeHandle, alignment: Alignment) -> some View {
        Circle()
            .fill(.white)
            .overlay {
                Circle().stroke(.black.opacity(0.35), lineWidth: 1)
            }
            .frame(width: 12, height: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(4)
            .contentShape(Rectangle().inset(by: -8))
            .accessibilityLabel("Resize floating video")
            .accessibilityAdjustableAction { direction in
                resizeWithAccessibility(handle, direction: direction)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = resizeStartFrames[handle] ?? floatingState.frame
                        resizeStartFrames[handle] = start
                        floatingState.resize(
                            from: start,
                            handle: handle,
                            translation: value.translation,
                            in: availableBounds,
                            aspectRatio: playerViewModel.videoAspectRatio
                        )
                    }
                    .onEnded { _ in resizeStartFrames[handle] = nil }
            )
    }

    private func resizeWithAccessibility(
        _ handle: VideoResizeHandle,
        direction: AccessibilityAdjustmentDirection
    ) {
        let increasesTowardRight = handle == .topTrailing || handle == .bottomTrailing
        let magnitude: CGFloat
        switch direction {
        case .increment: magnitude = increasesTowardRight ? 10 : -10
        case .decrement: magnitude = increasesTowardRight ? -10 : 10
        @unknown default: return
        }
        floatingState.resize(
            from: floatingState.frame,
            handle: handle,
            translation: CGSize(width: magnitude, height: 0),
            in: availableBounds,
            aspectRatio: playerViewModel.videoAspectRatio
        )
    }

    private func moveWithKeyboard(_ direction: MoveCommandDirection) {
        let delta: CGSize
        switch direction {
        case .left: delta = CGSize(width: -10, height: 0)
        case .right: delta = CGSize(width: 10, height: 0)
        case .up: delta = CGSize(width: 0, height: -10)
        case .down: delta = CGSize(width: 0, height: 10)
        @unknown default: return
        }
        floatingState.move(
            by: delta,
            in: availableBounds,
            aspectRatio: playerViewModel.videoAspectRatio
        )
    }
}
#endif
```

- [ ] **Step 2: Register `FloatingVideoPane.swift` with the app target**

Edit `project.pbxproj` using the reserved IDs:

```text
PBXBuildFile:
F20A00000000000000000004 /* FloatingVideoPane.swift in Sources */ = {isa = PBXBuildFile; fileRef = F20A00000000000000000003 /* FloatingVideoPane.swift */; };

PBXFileReference:
F20A00000000000000000003 /* FloatingVideoPane.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FloatingVideoPane.swift; sourceTree = "<group>"; };

Components group children:
F20A00000000000000000003 /* FloatingVideoPane.swift */,

Pangolin Sources build phase:
F20A00000000000000000004 /* FloatingVideoPane.swift in Sources */,
```

- [ ] **Step 3: Lift the overlay above the inspector**

Apply the overlay to `baseNavigationSplitView` in `MainView`, after the `NavigationSplitView` has composed its detail and inspector:

```swift
private var baseNavigationSplitView: some View {
    NavigationSplitView(columnVisibility: splitViewColumnVisibility) {
        sidebarColumn
    } detail: {
        detailColumn
    }
    .navigationSplitViewStyle(.balanced)
    .overlay {
        #if os(macOS)
        GeometryReader { proxy in
            ZStack {
                if floatingVideoState.isFloating,
                   floatingVideoState.frame != .zero,
                   let video = folderStore.selectedVideo {
                    FloatingVideoPane(
                        video: video,
                        playerViewModel: videoPlayerViewModel,
                        floatingState: floatingVideoState,
                        availableBounds: CGRect(origin: .zero, size: proxy.size),
                        inlineWidth: videoInlineWidth
                    )
                    .zIndex(100)
                }
            }
            .task(id: floatingVideoState.isFloating) {
                guard floatingVideoState.isFloating else { return }
                floatingVideoState.prepareDefaultFrame(
                    in: CGRect(origin: .zero, size: proxy.size),
                    inlineWidth: videoInlineWidth,
                    aspectRatio: videoPlayerViewModel.videoAspectRatio
                )
            }
            .onChange(of: proxy.size) { _, newSize in
                floatingVideoState.clamp(
                    to: CGRect(origin: .zero, size: newSize),
                    aspectRatio: videoPlayerViewModel.videoAspectRatio
                )
            }
        }
        .allowsHitTesting(floatingVideoState.isFloating)
        #endif
    }
}
```

Add `@State private var videoInlineWidth: CGFloat = VideoDetailLayout.contentMaxWidth` to `MainView`. Add an `onInlineWidthChange` closure to `DetailView` and update this state whenever the measured inline width changes. Because the overlay is on the split-view root, it can cover the detail content and inspector. Its geometry starts below the native toolbar, so clamping prevents toolbar overlap.

- [ ] **Step 4: Clamp when the window or inspector geometry changes**

Inside the root overlay `GeometryReader`, retain this geometry-change handler from the Step 3 structure:

```swift
.onChange(of: proxy.size) { _, newSize in
    floatingVideoState.clamp(
        to: CGRect(origin: .zero, size: newSize),
        aspectRatio: videoPlayerViewModel.videoAspectRatio
    )
}
```

On floating transition, call `prepareDefaultFrame` with the root overlay bounds, not the narrower transcript width. This ensures the default top-right placement is relative to the whole below-toolbar Pangolin content region and may overlap the inspector.

- [ ] **Step 5: Build and perform the focused interaction pass**

Run the macOS build command, then verify manually:

1. Scroll until 25 percent or less of the player remains; the floating pane appears top-right.
2. Confirm time and play/pause state do not change.
3. Drag using the grab handle over transcript and inspector.
4. Resize from all four corners; ratio stays constant.
5. Enlarge until the physical window bounds limit it; no artificial maximum appears.
6. Use arrow keys while focused; movement is 10 points.
7. Scroll back until 60 percent is visible; the player docks without reloading.
8. Float again; the current video's custom frame is restored.
9. Switch videos; placement resets.
10. Resize the window and toggle the inspector; the pane remains reachable and below the toolbar.

- [ ] **Step 6: Commit floating interaction**

```bash
git add Pangolin/Views/Components/FloatingVideoPane.swift Pangolin/Views/MainView.swift Pangolin/Views/DetailView.swift Pangolin.xcodeproj/project.pbxproj
git commit -m "Add in-window floating video player"
```

### Task 7: Full Verification and Polish

**Files:**
- Verify: all modified production, test, and project files

- [ ] **Step 1: Run formatting and project-integrity checks**

Run:

```bash
git diff --check
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -showBuildSettings >/dev/null
```

Expected: both commands exit 0 with no malformed-project error.

- [ ] **Step 2: Run all macOS unit tests**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests test
```

Expected: exit code 0 and zero failed tests in the result bundle.

- [ ] **Step 3: Run macOS and iOS compilation checks**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-FloatingVideo-iOS build
```

Expected: both commands exit 0. The floating pane is macOS-only; shared `DetailView` and transcript/summary changes must still compile for iOS.

- [ ] **Step 4: Complete the macOS visual matrix**

Verify each combination with a populated video:

```text
Appearance: light, dark
Window: narrow, wide, maximized
Inspector: closed, open
Tab: Transcript, Summary
Playback: playing, paused
Player: inline, floating, dragged, enlarged
```

Confirm one scrollbar, adaptive grey header, standard text surface, uninterrupted playback, inspector overlap, no toolbar overlap, correct hysteresis, search navigation, keyboard movement, VoiceOver labels, and reset on video change.

- [ ] **Step 5: Review the final diff against the approved spec**

Read:

```bash
git diff HEAD~6 -- Pangolin PangolinTests Pangolin.xcodeproj docs/superpowers/specs/2026-07-17-scrollable-video-detail-floating-player-design.md
```

Confirm every spec requirement maps to the implementation and there is no system PiP, external window, cross-video geometry persistence, fixed player height, nested transcript/summary scrollbar, or artificial maximum floating size.

- [ ] **Step 6: Commit any verification-only polish**

If verification required source changes, rerun Steps 1-4 and then commit only those reviewed changes:

```bash
git add Pangolin PangolinTests Pangolin.xcodeproj
git commit -m "Polish floating video interactions"
```

If no source changes were needed, do not create an empty commit.
