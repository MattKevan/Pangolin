# Stable Cross-Platform Video Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the persistent video with its inline slot, eliminate dock/undock judder, provide route-owned sidebar controls, and support floating playback across macOS, iPad, and iPhone without changing phone stack navigation.

**Architecture:** Move the player overlay to a shared host above the selected navigation shell, while each shell supplies its own usable bounds and toolbar behavior. Convert inline geometry into host-local coordinates through a pure policy, drive the player rectangle through a small explicit presentation controller, and keep one `VideoPlayerWithPosterView` alive across docked and floating states. macOS and iPad retain `NavigationSplitView`; iPhone retains `NavigationStack` but receives the same persistent floating player through the shared host.

**Tech Stack:** Swift 6 language mode, SwiftUI, AVKit-backed existing player view, Swift Testing, Xcode macOS and iOS Simulator builds.

---

## File Structure

- Modify `Pangolin/Views/Components/VideoFloatingLayout.swift`: add coordinate conversion, host layout, and toolbar visibility policies; retain pure floating geometry.
- Create `Pangolin/Views/Components/VideoPresentationFrameController.swift`: own the displayed frame and explicit dock/undock transition phase without owning playback.
- Modify `Pangolin/Views/Components/FloatingVideoPane.swift`: consume a host-local docked frame and presentation controller on every platform; isolate macOS keyboard affordances.
- Create `Pangolin/Views/Components/VideoPresentationHost.swift`: provide one cross-platform overlay host and convert reported inline geometry into its local coordinate system.
- Modify `Pangolin/Views/MainView.swift`: mount the shared host above split or stack navigation, own route-driven workspace toolbar controls, and remove the macOS-only overlay.
- Modify `Pangolin/Views/DetailView.swift`: continue reporting inline geometry from both navigation architectures without rendering a second player.
- Modify `PangolinTests/PangolinTests.swift`: cover coordinate conversion, toolbar policy, frame-update decisions, lifecycle cancellation, and existing layout behavior.

### Task 1: Define Host-Local Geometry and Toolbar Policy

**Files:**
- Modify: `Pangolin/Views/Components/VideoFloatingLayout.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing coordinate-conversion and toolbar-policy tests**

Extend `VideoPlayerPresentationPolicyTests` and add `VideoToolbarPolicyTests`:

```swift
@Test("Root geometry converts into overlay-local coordinates")
func convertsToOverlayCoordinates() {
    let rootFrame = CGRect(x: 120, y: 180, width: 800, height: 450)
    let overlayFrame = CGRect(x: 0, y: 58, width: 1200, height: 742)

    #expect(VideoPlayerPresentationPolicy.overlayLocalFrame(
        rootFrame,
        overlayFrameInRoot: overlayFrame
    ) == CGRect(x: 120, y: 122, width: 800, height: 450))
}

@Test("Invalid root or overlay geometry is rejected")
func rejectsInvalidCoordinateConversion() {
    #expect(VideoPlayerPresentationPolicy.overlayLocalFrame(
        .zero,
        overlayFrameInRoot: CGRect(x: 0, y: 58, width: 1200, height: 742)
    ) == nil)
    #expect(VideoPlayerPresentationPolicy.overlayLocalFrame(
        CGRect(x: 120, y: 180, width: 800, height: 450),
        overlayFrameInRoot: .zero
    ) == nil)
}

@Suite("Video toolbar policy")
struct VideoToolbarPolicyTests {
    @Test("Workspace routes own a restorable sidebar control")
    func ordinaryWorkspace() {
        #expect(VideoToolbarPolicy.showsSidebarButton(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: true
        ))
    }

    @Test("Video detail replaces the sidebar control with Back")
    func workspaceVideoDetail() {
        #expect(!VideoToolbarPolicy.showsSidebarButton(
            shell: .workspace,
            isVideoDetail: true,
            supportsAppOwnedSidebarButton: true
        ))
        #expect(VideoToolbarPolicy.showsVideoBackButton(
            shell: .workspace,
            isVideoDetail: true
        ))
    }

    @Test("Phone uses native stack navigation controls")
    func phoneVideoDetail() {
        #expect(!VideoToolbarPolicy.showsSidebarButton(
            shell: .phone,
            isVideoDetail: true,
            supportsAppOwnedSidebarButton: false
        ))
        #expect(!VideoToolbarPolicy.showsVideoBackButton(
            shell: .phone,
            isVideoDetail: true
        ))
    }
}
```

- [ ] **Step 2: Run the focused suites and verify RED**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPlayerPresentationPolicyTests -only-testing:PangolinTests/VideoToolbarPolicyTests
```

Expected: compilation fails because `overlayLocalFrame`, `VideoNavigationShell`, and `VideoToolbarPolicy` do not exist.

- [ ] **Step 3: Implement the pure coordinate and toolbar policies**

Add to `VideoFloatingLayout.swift`:

```swift
enum VideoNavigationShell: Equatable {
    case workspace
    case phone
}

enum VideoToolbarPolicy {
    static func showsSidebarButton(
        shell: VideoNavigationShell,
        isVideoDetail: Bool,
        supportsAppOwnedSidebarButton: Bool
    ) -> Bool {
        shell == .workspace
            && supportsAppOwnedSidebarButton
            && !isVideoDetail
    }

    static func showsVideoBackButton(
        shell: VideoNavigationShell,
        isVideoDetail: Bool
    ) -> Bool {
        shell == .workspace && isVideoDetail
    }
}
```

Make `VideoPlayerPresentationPolicy.isValid(_:)` internal to the type's methods and add:

```swift
static func overlayLocalFrame(
    _ rootFrame: CGRect,
    overlayFrameInRoot: CGRect
) -> CGRect? {
    guard isValid(rootFrame), isValid(overlayFrameInRoot) else { return nil }
    return rootFrame.offsetBy(
        dx: -overlayFrameInRoot.minX,
        dy: -overlayFrameInRoot.minY
    )
}
```

- [ ] **Step 4: Run the focused suites and verify GREEN**

Run the Task 1 test command again.

Expected: both suites pass with zero failures.

- [ ] **Step 5: Commit Task 1**

```bash
git add Pangolin/Views/Components/VideoFloatingLayout.swift PangolinTests/PangolinTests.swift
git commit -m "Define video host geometry policy"
```

### Task 2: Introduce an Explicit Presentation-Frame Controller

**Files:**
- Create: `Pangolin/Views/Components/VideoPresentationFrameController.swift`
- Modify: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Write failing tests for update decisions and lifecycle reset**

Add these pure-policy tests before the observable controller is introduced:

```swift
@Suite("Video presentation frame updates")
struct VideoPresentationFrameUpdatePolicyTests {
    private let inline = CGRect(x: 100, y: 100, width: 800, height: 450)
    private let floating = CGRect(x: 700, y: 80, width: 400, height: 225)

    @Test("Initial and steady docked geometry apply directly")
    func directDockedUpdates() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: nil,
            newMode: .docked,
            hasPresentedFrame: false
        ) == .direct)
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .docked,
            newMode: .docked,
            hasPresentedFrame: true
        ) == .direct)
    }

    @Test("Mode changes and transition retargets animate")
    func animatedTransitions() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .docked,
            newMode: .floating,
            hasPresentedFrame: true,
            isTransitioning: false
        ) == .animated)
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .floating,
            newMode: .docked,
            hasPresentedFrame: true,
            isTransitioning: false
        ) == .animated)
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .docked,
            newMode: .docked,
            hasPresentedFrame: true,
            isTransitioning: true
        ) == .animated)
    }

    @Test("Floating gesture previews bypass animation")
    func directInteractionPreview() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .floating,
            newMode: .floating,
            hasPresentedFrame: true,
            isTransitioning: false,
            isInteracting: true
        ) == .direct)
    }

    @Test("Controller reset removes stale video geometry")
    @MainActor
    func reset() {
        let controller = VideoPresentationFrameController()
        controller.apply(destination: inline, mode: .docked, animated: false)
        controller.reset()
        #expect(controller.frame == nil)
        #expect(controller.mode == nil)
    }
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPresentationFrameUpdatePolicyTests
```

Expected: compilation fails because the presentation mode, update decision, policy, and controller are missing.

- [ ] **Step 3: Add the pure update policy and observable controller**

Create `VideoPresentationFrameController.swift` with:

```swift
import SwiftUI

enum VideoPresentationMode: Equatable {
    case docked
    case floating
}

enum VideoPresentationFrameUpdateDecision: Equatable {
    case direct
    case animated
}

enum VideoPresentationFrameUpdatePolicy {
    static func decision(
        previousMode: VideoPresentationMode?,
        newMode: VideoPresentationMode,
        hasPresentedFrame: Bool,
        isTransitioning: Bool = false,
        isInteracting: Bool = false
    ) -> VideoPresentationFrameUpdateDecision {
        guard hasPresentedFrame, !isInteracting else { return .direct }
        return previousMode != newMode || isTransitioning ? .animated : .direct
    }
}

@MainActor
final class VideoPresentationFrameController: ObservableObject {
    static let transitionDuration = 0.25

    @Published private(set) var frame: CGRect?
    @Published private(set) var mode: VideoPresentationMode?
    @Published private(set) var isTransitioning = false
    private var transitionTask: Task<Void, Never>?

    func apply(
        destination: CGRect,
        mode newMode: VideoPresentationMode,
        animated: Bool
    ) {
        let updates = {
            self.frame = destination
            self.mode = newMode
        }
        if animated {
            transitionTask?.cancel()
            isTransitioning = true
            withAnimation(.smooth(duration: Self.transitionDuration)) {
                updates()
            }
            transitionTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.transitionDuration))
                guard !Task.isCancelled else { return }
                isTransitioning = false
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                updates()
            }
        }
    }

    func reset() {
        transitionTask?.cancel()
        transitionTask = nil
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            frame = nil
            mode = nil
            isTransitioning = false
        }
    }
}
```

The controller intentionally stores only presentation geometry. `VideoPlayerViewModel` remains the sole playback owner.

- [ ] **Step 4: Run the focused suite and verify GREEN**

Run the Task 2 test command again.

Expected: the suite passes with zero failures.

- [ ] **Step 5: Commit Task 2**

```bash
git add Pangolin/Views/Components/VideoPresentationFrameController.swift PangolinTests/PangolinTests.swift
git commit -m "Add explicit video frame controller"
```

### Task 3: Make the Persistent Pane Cross-Platform and Animation-Safe

**Files:**
- Modify: `Pangolin/Views/Components/FloatingVideoPane.swift`
- Modify: `Pangolin/Views/Components/VideoFloatingLayout.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Add a failing test that previews override only floating presentation**

Extend `VideoPlayerPresentationPolicyTests`:

```swift
@Test("Interaction preview is ignored while docked on every platform")
func previewRequiresFloatingMode() {
    let preview = CGRect(x: 20, y: 30, width: 300, height: 168.75)
    #expect(VideoPlayerPresentationPolicy.renderedFrame(
        isFloating: false,
        baseFrame: inline,
        interactionPreviewFrame: preview
    ) == inline)
    #expect(VideoPlayerPresentationPolicy.renderedFrame(
        isFloating: true,
        baseFrame: floating,
        interactionPreviewFrame: preview
    ) == preview)
}
```

- [ ] **Step 2: Run the presentation-policy suite and verify the characterization test**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPlayerPresentationPolicyTests
```

Expected: the test passes against the existing pure rendering policy, protecting gesture behavior during the refactor.

- [ ] **Step 3: Refactor `FloatingVideoPane` around a host-local docked frame**

Remove the file-wide `#if os(macOS)` around `FloatingVideoPane`. Change its stored inputs to:

```swift
struct FloatingVideoPane: View {
    let video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject var floatingState: FloatingVideoState
    @ObservedObject var frameController: VideoPresentationFrameController
    let dockedFrame: CGRect
    let availableBounds: CGRect
```

Derive `mode`, `destination`, and the gesture preview separately:

```swift
private var mode: VideoPresentationMode {
    floatingState.isFloating ? .floating : .docked
}

private var destination: CGRect {
    floatingState.isFloating ? floatingState.frame : dockedFrame
}

private var renderedFrame: CGRect {
    let base = frameController.frame ?? destination
    return VideoPlayerPresentationPolicy.renderedFrame(
        isFloating: floatingState.isFloating,
        baseFrame: base,
        interactionPreviewFrame: interactionPreviewFrame
    )
}
```

Remove `.animation(.easeInOut(duration: 0.25), value: floatingState.isFloating)` from the player modifier chain. On initial appearance, mode changes, and destination changes, call one helper:

```swift
private func updatePresentation(isInteracting: Bool = false) {
    let decision = VideoPresentationFrameUpdatePolicy.decision(
        previousMode: frameController.mode,
        newMode: mode,
        hasPresentedFrame: frameController.frame != nil,
        isTransitioning: frameController.isTransitioning,
        isInteracting: isInteracting
    )
    frameController.apply(
        destination: destination,
        mode: mode,
        animated: decision == .animated
    )
}
```

Keep drag and resize previews in `@State`; they continue to bypass the shared controller until committed. Use conditional compilation only around `.onMoveCommand`, keyboard shortcuts, pointer help text, and `@FocusState` behavior. Keep touch gestures, drag handle, reset, and corner resize controls available on iOS with at least 44-point hit regions.

- [ ] **Step 4: Cancel stale presentation when pane identity changes**

Add `.id(video.id)` at the host call site in Task 4. In the pane's disappearance handler clear gesture state; let the host reset the controller when the selected video changes. Do not call `playerViewModel.loadVideo` from the pane.

- [ ] **Step 5: Run focused tests and build both platforms**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPlayerPresentationPolicyTests -only-testing:PangolinTests/VideoPresentationFrameUpdatePolicyTests
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator'
```

Expected: focused tests pass and both builds report `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit Task 3**

```bash
git add Pangolin/Views/Components/FloatingVideoPane.swift Pangolin/Views/Components/VideoFloatingLayout.swift PangolinTests/PangolinTests.swift
git commit -m "Make floating video pane cross-platform"
```

### Task 4: Mount One Player Host Above Split and Stack Navigation

**Files:**
- Create: `Pangolin/Views/Components/VideoPresentationHost.swift`
- Modify: `Pangolin/Views/MainView.swift`
- Modify: `Pangolin/Views/DetailView.swift`
- Modify: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Add failing host-layout tests for usable bounds**

Add:

```swift
@Suite("Video presentation host layout")
struct VideoPresentationHostLayoutTests {
    @Test("Host bounds exclude supplied navigation and safe-area insets")
    func insetBounds() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 390, height: 844),
            insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        ) == CGRect(x: 0, y: 59, width: 390, height: 751))
    }

    @Test("Oversized insets produce no usable host")
    func invalidBounds() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 100, height: 100),
            insets: EdgeInsets(top: 80, leading: 60, bottom: 30, trailing: 60)
        ) == .zero)
    }
}
```

- [ ] **Step 2: Run the host-layout suite and verify RED**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPresentationHostLayoutTests
```

Expected: compilation fails because `VideoPresentationHostLayout` is missing.

- [ ] **Step 3: Add the pure host-bounds policy**

In `VideoFloatingLayout.swift`, add:

```swift
enum VideoPresentationHostLayout {
    static func availableBounds(size: CGSize, insets: EdgeInsets) -> CGRect {
        let width = size.width - insets.leading - insets.trailing
        let height = size.height - insets.top - insets.bottom
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return .zero
        }
        return CGRect(
            x: insets.leading,
            y: insets.top,
            width: width,
            height: height
        )
    }
}
```

- [ ] **Step 4: Create the shared presentation host**

Create `VideoPresentationHost.swift` as a `GeometryReader`-backed overlay that accepts the selected video, route activity, `playerViewModel`, `floatingVideoState`, and `frameController`. Measure:

```swift
let overlayFrameInRoot = geometry.frame(
    in: .named(VideoFloatingCoordinateSpace.root)
)
let dockedFrame = VideoPlayerPresentationPolicy.overlayLocalFrame(
    floatingVideoState.inlineFrame,
    overlayFrameInRoot: overlayFrameInRoot
)
let availableBounds = VideoPresentationHostLayout.availableBounds(
    size: geometry.size,
    insets: geometry.safeAreaInsets
)
```

Render `FloatingVideoPane` only when the video ID matches the state and `dockedFrame` is valid. Pass the converted frame, not `floatingVideoState.inlineFrame`, and attach `.id(video.id)`. Prepare or clamp the floating destination when inline width, host size, safe-area insets, or aspect ratio changes. Reset `frameController` when the selected video ID changes or video detail becomes inactive.

The host uses `.clipped()` to remain in the Pangolin window. Its bounds exclude navigation chrome supplied through safe-area insets; it does not subtract inspector width, so the floating pane may overlap the inspector.

- [ ] **Step 5: Move the coordinate space and host above the shell switch**

In `MainView`, wrap the existing idiom switch in a `Group` and attach the named coordinate space and host once:

```swift
@ViewBuilder
private var rootShellView: some View {
    Group {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneRootView
        } else {
            rootNavigationSplitView
        }
        #else
        rootNavigationSplitView
        #endif
    }
    .coordinateSpace(name: VideoFloatingCoordinateSpace.root)
    .overlay {
        VideoPresentationHost(
            video: folderStore.selectedVideo,
            isVideoDetailActive: folderStore.currentDetailSurface == .videoDetail,
            playerViewModel: playerViewModel,
            floatingState: floatingVideoState,
            frameController: videoPresentationFrameController
        )
    }
}
```

Add `@StateObject private var videoPresentationFrameController = VideoPresentationFrameController()`. Remove the macOS-only player overlay, `shouldShowVideoPlayer`, `prepareFloatingVideo`, and `adjustFloatingVideo` from `MainView`. Keep `synchronizeVideoSelection()` as the only place that loads or clears playback.

Because both `DetailView` paths already report `geometry.frame(in: .named(VideoFloatingCoordinateSpace.root))`, retain that measurement and verify that the inline placeholder never conditionally creates its own `VideoPlayerWithPosterView`.

- [ ] **Step 6: Run host tests and platform builds**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoPresentationHostLayoutTests -only-testing:PangolinTests/VideoPlayerPresentationPolicyTests
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator'
```

Expected: tests pass and both builds report `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit Task 4**

```bash
git add Pangolin/Views/Components/VideoPresentationHost.swift Pangolin/Views/Components/VideoFloatingLayout.swift Pangolin/Views/MainView.swift Pangolin/Views/DetailView.swift PangolinTests/PangolinTests.swift
git commit -m "Host persistent video across navigation shells"
```

### Task 5: Own Workspace Sidebar and Back Controls Explicitly

**Files:**
- Modify: `Pangolin/Views/MainView.swift`
- Test: `PangolinTests/PangolinTests.swift`

- [ ] **Step 1: Extend the toolbar policy test for a collapsed ordinary sidebar**

Add a test documenting that the app-owned control remains available to restore the sidebar:

```swift
@Test("Sidebar control remains available on a collapsed ordinary workspace")
func collapsedWorkspace() {
    #expect(VideoToolbarPolicy.showsSidebarButton(
        shell: .workspace,
        isVideoDetail: false,
        supportsAppOwnedSidebarButton: true
    ))
}

@Test("iPad leaves ordinary sidebar restoration to NavigationSplitView")
func systemOwnedWorkspaceSidebar() {
    #expect(!VideoToolbarPolicy.showsSidebarButton(
        shell: .workspace,
        isVideoDetail: false,
        supportsAppOwnedSidebarButton: false
    ))
}
```

- [ ] **Step 2: Run the toolbar suite and verify the characterization test**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoToolbarPolicyTests
```

Expected: all policy tests pass; the remaining work is SwiftUI integration.

- [ ] **Step 3: Replace the automatic macOS item with an app-owned control**

Apply `.toolbar(removing: .sidebarToggle)` unconditionally to the macOS `NavigationSplitView` root. In the leading navigation toolbar group, use `VideoToolbarPolicy` to show this control only on ordinary workspace routes:

```swift
#if os(macOS)
if VideoToolbarPolicy.showsSidebarButton(
    shell: .workspace,
    isVideoDetail: folderStore.showsVideoBackButton,
    supportsAppOwnedSidebarButton: true
) {
    Button {
        standardColumnVisibility = standardColumnVisibility == .detailOnly
            ? .all
            : .detailOnly
    } label: {
        Image(systemName: "sidebar.left")
    }
    .help(standardColumnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
    .accessibilityLabel(standardColumnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
}
#endif
```

Keep the existing workspace video Back action, but gate it with `VideoToolbarPolicy.showsVideoBackButton(shell:isVideoDetail:)`. Do not add either control to `phoneRootView`; `NavigationStack` supplies native Back. On iPad, preserve the system split-view sidebar affordance on ordinary routes and confirm that `.detailOnly` video detail does not add Pangolin's workspace sidebar button beside Back.

- [ ] **Step 4: Run toolbar tests and both platform builds**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/VideoToolbarPolicyTests
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator'
```

Expected: the suite passes and both builds report `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit Task 5**

```bash
git add Pangolin/Views/MainView.swift PangolinTests/PangolinTests.swift
git commit -m "Own workspace sidebar toolbar controls"
```

### Task 6: Full Verification and Manual Platform Audit

**Files:**
- Modify only if verification exposes a requirement regression: files changed in Tasks 1–5

- [ ] **Step 1: Run the complete macOS unit suite**

Run:

```bash
xcodebuild test -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS'
```

Expected: all Pangolin unit tests pass with zero failures. If the UI-test runner is blocked by macOS system authentication, record that separately; do not treat it as an application test failure.

- [ ] **Step 2: Build the iOS target containing both idiom branches**

Run:

```bash
xcodebuild build -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator'
```

Expected: `** BUILD SUCCEEDED **`. This compiles the iPad split-view branch, iPhone stack branch, touch gestures, and shared host.

- [ ] **Step 3: Verify macOS behavior in the running application**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: Pangolin builds and launches. Confirm one loaded video while playing and paused:

1. The inline player exactly covers the full-width placeholder.
2. Slow and rapid threshold crossings animate without vertical jumps, flicker, or shaking.
3. Reversing mid-transition retargets smoothly.
4. Docked scrolling is immediate; floating drag and resize are immediate and preserve ratio.
5. The player stays below the toolbar, may overlap the inspector, and remains in the window.
6. Ordinary routes show the restorable sidebar control; video detail shows Back without the sidebar control.

- [ ] **Step 4: Verify iPad and iPhone navigation/presentation manually**

Launch the built app once on an available iPad simulator and once on an available iPhone simulator from Xcode. On iPad, confirm split-view navigation, focused video-detail Back behavior, touch drag/resize, and floating playback. On iPhone, confirm native pushed Back navigation, the hidden tab bar during detail, inline-to-floating transition, touch drag/resize, safe-area containment, and uninterrupted playback.

Expected: both idioms satisfy the same playback and motion rules while retaining their specified navigation shells.

- [ ] **Step 5: Inspect the final diff and working tree**

Run:

```bash
git diff --check
git status --short
```

Expected: `git diff --check` prints nothing. `git status --short` contains only intentional source, test, or plan changes; after task commits it should be empty.

- [ ] **Step 6: Commit any verification-only correction**

If Step 3 or 4 required a source correction, stage only those correction files and commit them:

```bash
git add Pangolin/Views/Components/VideoFloatingLayout.swift Pangolin/Views/Components/VideoPresentationFrameController.swift Pangolin/Views/Components/FloatingVideoPane.swift Pangolin/Views/Components/VideoPresentationHost.swift Pangolin/Views/MainView.swift Pangolin/Views/DetailView.swift PangolinTests/PangolinTests.swift
git commit -m "Harden cross-platform video presentation"
```

If no correction was required, do not create an empty commit.
