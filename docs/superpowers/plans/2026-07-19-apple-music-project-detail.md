# Apple Music-Style Project Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS project overview's custom scroll-and-selection implementation with one Apple Music-style, continuously scrolling native list that retains module headings and gains native keyboard, highlight, and accessibility behavior.

**Architecture:** Keep the cross-platform `ProjectDetailView` and its existing store, but make the macOS branch a single `List(selection:)` whose first row is the hero, middle sections are tagged video rows, and final row is project totals. Add a small pure selection policy for filtered-selection reconciliation and Return activation, and adapt the existing private row component so iOS keeps its current manual edit-mode behavior while macOS delegates selection styling and input to `List`.

**Tech Stack:** SwiftUI, Core Data models, Swift Testing, Xcode 26 macOS/iOS targets.

---

## File Map

- Modify `Pangolin/Views/ProjectsView.swift`: add the pure selection policy, replace the macOS scroll view with a native list, add album-style header/footer composition, and adapt row accessibility/styling.
- Modify `PangolinTests/ProjectsStoreTests.swift`: test selection reconciliation and Return activation without UI dependencies.

No new production file is required; the scoped policy and private presentation components belong with the only view that consumes them, avoiding project-file registration churn.

### Task 1: Selection Policy

**Files:**
- Modify: `PangolinTests/ProjectsStoreTests.swift`
- Modify: `Pangolin/Views/ProjectsView.swift`

- [ ] **Step 1: Write failing selection-policy tests**

Add these tests inside `ProjectsStoreTests`:

```swift
@Test("Project selection drops IDs hidden by filtering")
func projectSelectionReconcilesVisibleIDs() {
    let visible = UUID()
    let hidden = UUID()

    #expect(ProjectVideoSelectionPolicy.reconciledSelection(
        [visible, hidden],
        visibleIDs: [visible]
    ) == [visible])
}

@Test("Project Return activation requires exactly one selected visible video")
func projectReturnActivationRequiresSingleVisibleSelection() {
    let first = UUID()
    let second = UUID()

    #expect(ProjectVideoSelectionPolicy.activationID(
        selection: [first],
        visibleIDs: [first, second]
    ) == first)
    #expect(ProjectVideoSelectionPolicy.activationID(
        selection: [first, second],
        visibleIDs: [first, second]
    ) == nil)
    #expect(ProjectVideoSelectionPolicy.activationID(
        selection: [first],
        visibleIDs: [second]
    ) == nil)
}
```

- [ ] **Step 2: Run the tests and confirm the policy is missing**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/ProjectsStoreTests test
```

Expected: FAIL because `ProjectVideoSelectionPolicy` is not defined.

- [ ] **Step 3: Add the minimal pure policy**

Add near the top of `ProjectsView.swift`, after imports:

```swift
enum ProjectVideoSelectionPolicy {
    static func reconciledSelection(
        _ selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> Set<UUID> {
        selection.intersection(visibleIDs)
    }

    static func activationID(
        selection: Set<UUID>,
        visibleIDs: Set<UUID>
    ) -> UUID? {
        guard selection.count == 1,
              let selectedID = selection.first,
              visibleIDs.contains(selectedID) else {
            return nil
        }
        return selectedID
    }
}
```

- [ ] **Step 4: Run the policy tests**

Run the Task 1 test command again.

Expected: PASS.

- [ ] **Step 5: Commit the selection policy**

```bash
git add Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "test: define project video selection policy"
```

### Task 2: One Continuously Scrolling Native List

**Files:**
- Modify: `Pangolin/Views/ProjectsView.swift`

- [ ] **Step 1: Add visible-ID and filtered-empty helpers**

Add to `ProjectDetailView`:

```swift
private var displayedVideoIDs: Set<UUID> {
    Set(orderedDisplayedVideos.compactMap(\.id))
}

private var hasProjectSearch: Bool {
    !store.projectSearchQuery
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
}
```

- [ ] **Step 2: Replace only the macOS `ScrollView` branch**

Change `macProjectDetail` to one native list:

```swift
private var macProjectDetail: some View {
    List(selection: $store.selectedProjectVideoIDs) {
        macAlbumHero
            .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 28, trailing: 24))
            .listRowSeparator(.hidden)

        if sections.isEmpty {
            projectEmptyState
                .frame(maxWidth: .infinity, minHeight: 220)
                .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24))
                .listRowSeparator(.hidden)
        } else {
            ForEach(sections) { section in
                Section {
                    ForEach(Array(section.videos.enumerated()), id: \.element.objectID) { index, video in
                        if let videoID = video.id {
                            ProjectVideoRow(
                                video: video,
                                ordinal: index + 1,
                                isSelected: false,
                                showsSelectionAccessory: false,
                                usesNativeListStyling: true,
                                tapAction: nil,
                                doubleClickAction: {
                                    store.openProjectVideo(video, in: project)
                                }
                            )
                            .tag(videoID)
                            .accessibilityIdentifier("project-video-row-\(videoID.uuidString)")
                        }
                    }
                } header: {
                    ProjectAlbumSectionHeader(title: section.title)
                        .accessibilityIdentifier("project-section-\(section.id)")
                }
            }

            ProjectAlbumFooter(
                videoCount: totalVideoCount,
                duration: formattedProjectDuration(totalDuration)
            )
            .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 28, trailing: 24))
            .listRowSeparator(.hidden)
        }
    }
    .listStyle(.plain)
    .accessibilityIdentifier("project-video-list")
    .onChange(of: displayedVideoIDs) { _, visibleIDs in
        store.selectedProjectVideoIDs = ProjectVideoSelectionPolicy.reconciledSelection(
            store.selectedProjectVideoIDs,
            visibleIDs: visibleIDs
        )
    }
    .onKeyPress(.return) {
        openSelectedProjectVideo() ? .handled : .ignored
    }
    .navigationTitle(project.resolvedProjectTitle)
}
```

Define `projectEmptyState` so a nonempty query says `No matching videos`, while a genuinely empty project preserves `No videos in this project`. Define `openSelectedProjectVideo()` to resolve the policy's single ID against `orderedDisplayedVideos`, call `store.openProjectVideo`, and return whether it handled the key.

- [ ] **Step 3: Add the unselectable responsive hero row**

Add a macOS-only helper:

```swift
private var macAlbumHero: some View {
    ViewThatFits(in: .horizontal) {
        heroContent(isCompact: false)
            .frame(minWidth: 520, alignment: .leading)

        heroContent(isCompact: true)
    }
    .accessibilityElement(children: .contain)
}
```

Do not assign a selection tag to the hero.

- [ ] **Step 4: Compile the macOS list branch**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit the native list conversion**

```bash
git add Pangolin/Views/ProjectsView.swift
git commit -m "feat: use native project video list"
```

### Task 3: Apple Music-Style Sections, Footer, and Rows

**Files:**
- Modify: `Pangolin/Views/ProjectsView.swift`

- [ ] **Step 1: Add lightweight album section and footer components**

Add private components next to the existing project row types:

```swift
private struct ProjectAlbumSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ProjectAlbumFooter: View {
    let videoCount: Int
    let duration: String

    var body: some View {
        Text("\(videoCount) \(videoCount == 1 ? "video" : "videos"), \(duration)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Make `ProjectVideoRow` support native list styling**

Add:

```swift
let usesNativeListStyling: Bool
let tapAction: (() -> Void)?
```

Give `usesNativeListStyling` a default of `false` in an explicit initializer so existing iOS call sites preserve their appearance. Render the row content through a private `rowContent` property. Attach the single-tap gesture only when `tapAction` is nonnil. When `usesNativeListStyling` is true:

- Do not draw the rounded custom selection background.
- Do not draw the internal `Divider`; let `List` provide row separators.
- Retain the existing 10-point vertical and 12-point horizontal row padding.

For double-click, attach the existing action only when it is nonnil, without replacing native single-click selection.

- [ ] **Step 3: Improve control and watch-state accessibility**

Give the favourite button `Add to favourites` or `Remove from favourites` as both help and accessibility label. Give the status indicator an explicit label using `video.watchStatus.displayName`. Give the overflow menu the label `More actions for <resolved title>`. Keep the controls separately accessible; do not combine the whole row into one accessibility element.

- [ ] **Step 4: Verify macOS and iOS compilation**

Run:

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Pangolin-ProjectAlbum-iOS build
```

Expected: both builds succeed.

- [ ] **Step 5: Commit the album styling**

```bash
git add Pangolin/Views/ProjectsView.swift
git commit -m "feat: style project detail as an album"
```

### Task 4: Regression Verification

**Files:**
- Verify: `Pangolin/Views/ProjectsView.swift`
- Verify: `PangolinTests/ProjectsStoreTests.swift`

- [ ] **Step 1: Run focused project tests**

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' -only-testing:PangolinTests/ProjectsStoreTests -only-testing:PangolinTests/VideoNavigationSequenceTests test
```

Expected: PASS.

- [ ] **Step 2: Run the full macOS tests**

```bash
xcodebuild -quiet -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test
```

Expected: PASS.

- [ ] **Step 3: Run project-integrity checks**

```bash
git diff --check
plutil -lint Pangolin.xcodeproj/project.pbxproj
```

Expected: no whitespace errors and `OK` from `plutil`.

- [ ] **Step 4: Build and launch for visual verification**

```bash
./script/build_and_run.sh --verify
```

Expected: the Pangolin process remains running. In a project with multiple modules, verify that the hero, module sections, rows, and totals scroll together; native row highlight appears; arrow keys traverse across modules; Return and double-click open a video; and favourite/menu controls do not open it.

- [ ] **Step 5: Commit any verification-only corrections**

If verification required code corrections:

```bash
git add Pangolin/Views/ProjectsView.swift PangolinTests/ProjectsStoreTests.swift
git commit -m "fix: polish project album interactions"
```

If no correction was needed, leave the prior implementation commits unchanged.
