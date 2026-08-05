# SpeechTranscriptionService Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `SpeechTranscriptionService.swift` (2261 lines) into focused extension files using the same verified pattern applied to FolderNavigationStore and ProcessingQueueManager (extract cohesive method clusters into `extension SpeechTranscriptionService` files; widen private→internal; build-gate each task).

**Architecture:** The class keeps its state, the four public flow methods (`transcribeVideo`/`translateVideo`/`summarizeVideo`/`generateFlashcards`), the flow gate, model-prep cache helpers, and the MainActor UI helpers. Six cohesive helper clusters move to extension files, one per task. Behavior-neutral: methods move verbatim; only access levels change (`private` → internal).

**Tech Stack:** Swift, AVFoundation/Speech (audio + recognition), Translation/FoundationModels (Apple Intelligence), CoreData (Video persistence), os.Logger.

## Global Constraints

- **Behavior preservation is the contract.** The service runs the transcription/translation/summarization/flashcards pipelines; the split must not alter order of operations, timeout math, retry schedules, or the single-active-flow gate (C1 fix from `4181744`). Nothing but access levels changes.
- The flow-gate semantics (`claimFlow`/`releaseFlow`/`activeFlow`, `isTranscribing`/`isSummarizing`) must remain exactly as-is.
- No force casts/`try!` (CI gate). `@State` stays `private`.
- Blanket-widen `private func`/`private var`/`private let`/`private struct` → internal in the moved files AND in the class file where the moved code references them (the established pattern: module-internal helpers; the class is only used via its public surface). Watch `@Published private(set) var` (needs `@Published var` when cross-file writes exist) and `private(set) var contentRevision`-style setters.
- Each task ends with: build succeeds, `xcodegen generate` after creating files, 275/275 unit tests pass (the suite does NOT cover the service internals — only 2 static token helpers — so verification is build + full-suite + flow behavior; the app smoke pass remains a manual step).
- Keep `import os` in every file (Logger calls) plus the framework imports each cluster needs (see per-task file headers).
- Commit after every task.

---

### Task 1: Extract types

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+Types.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove lines 10–111)

**Interfaces:**

- Consumes: nothing.
- Produces: `TranscriptionError`, `TranscriptionOutput`, `TranslationOutput`, `TranscriptionFlowKind`, `TranscriptionFlowClaimPolicy` at file scope (unchanged names/signatures — all already internal).

- [ ] **Step 1: Move lines 10–111 to the new file**

Header: `import Foundation` (+ `import os` if Logger is referenced; it is not in the types). Content: `TranscriptionError` (10–83), `TranscriptionOutput` (84–88), `TranslationOutput` (89–94), `TranscriptionFlowKind` (95–102), `TranscriptionFlowClaimPolicy` (103–111).

- [ ] **Step 2: Build**

Run: `cd /Users/mattkevan/Dev/Pangolin && xcodegen generate && xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full unit suite**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing:PangolinTests`
Expected: 275 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService types into their own file"
```

---

### Task 2: Extract the translation cluster

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+Translation.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove `computeTranslation`…`translateSentenceChunks` + related, current lines ~603–753)

**Interfaces:**

- Consumes: `TranscriptionError`, `setStatus`, `getProgressOnMain` (kept in class — widen as needed), the class's `preparedLocales`/locks if referenced.
- Produces: `computeTranslation`, `translateSentenceChunks`, and their private helpers as internal methods on `SpeechTranscriptionService`.

- [ ] **Step 1: Extract the cluster**

Header: `import os`, `import Foundation`, `import Translation`, `import CoreData` (Video fetch), `import SwiftUI` (Locale APIs). Widen `private func` → `func` for the moved methods and for any kept-class private helper they call (`setStatus`, `setProgress`, `setErrorMessage`, `getProgressOnMain`, `fetchVideo`, `userVisibleMessage`, `mapTranslationError` if referenced).

- [ ] **Step 2: Build + fix widenings**

Run the Task 1 build command; iterate on any `inaccessible due to 'private' protection level` errors by widening the named member in its file. Do not change method bodies.

- [ ] **Step 3: Run the full unit suite** (Task 1 command). Expected: 275 pass.

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService translation cluster"
```

---

### Task 3: Extract the flashcards cluster

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+Flashcards.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove `resolveFlashcardsSource`…`extractAllJSONObjectStrings`, current lines ~754–1163)

**Interfaces:**

- Consumes: `FlashcardDeck`/`Flashcard` (Models), `TimedTranslation` (Models), `setStatus`/`setProgress` (kept), `preparedLocales` locks if referenced.
- Produces: the flashcard source resolution + candidate generation + JSON decoding helpers as internal methods.

- [ ] **Step 1: Extract** — header `import os`, `import Foundation`, `import SwiftUI`, `import CoreData`. Widen moved + cross-referenced privates.

- [ ] **Step 2: Build + fix widenings**

- [ ] **Step 3: Run the full unit suite**

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService flashcards cluster"
```

---

### Task 4: Extract the audio cluster

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+Audio.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove `requestSpeechRecognitionPermission`…`formatsMatch`, current lines ~1212–1499)

**Interfaces:**

- Consumes: `TranscriptionError`, `getShouldPreferAssetPipelineTranscode`/`setShouldPreferAssetPipelineTranscode` + `transcodePreferenceLock` (kept in class — widen), `shouldPreferAssetPipelineTranscode` state, `SpeechTranscriber` (Services).
- Produces: the permission + audio-extraction + transcoding helpers as internal methods.

- [ ] **Step 1: Extract** — header `import os`, `import Foundation`, `import Speech`, `import AVFoundation`, `import AudioToolbox`, `import CoreData`. Widen moved + cross-referenced privates (incl. `shouldPreferAssetPipelineTranscode`/`transcodePreferenceLock`).

- [ ] **Step 2: Build + fix widenings**

- [ ] **Step 3: Run the full unit suite**

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService audio cluster"
```

---

### Task 5: Extract the language-detection cluster

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+LanguageDetection.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove `detectLanguage`…`containsRecognizableSpeech`, current lines ~1500–1624)

**Interfaces:**

- Consumes: `transcriber(for:)`/`localeKey`/`preparedLocales` + lock (kept — widen), `extractAudio` (moved in Task 4), `setStatus`/`setProgress`, `SpeechTranscriber`.
- Produces: `detectLanguage`, `languageProbeResult`, `containsRecognizableSpeech` as internal methods.

- [ ] **Step 1: Extract** — header `import os`, `import Foundation`, `import Speech`, `import AVFoundation`, `import NaturalLanguage`, `import CoreData`.

- [ ] **Step 2: Build + fix widenings**

- [ ] **Step 3: Run the full unit suite**

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService language-detection cluster"
```

---

### Task 6: Extract the transcription engine + translation error mapping

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+Transcription.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove `performTranscription`…`analyzeSequenceWithTimeout` + `cancelCurrentTranscription` + `mapTranslationError`, current lines ~1625–1962)

**Interfaces:**

- Consumes: `speechAnalyzer` (kept private state — widen), `SpeechAnalyzer`, `SpeechTranscriber`, `TimedTranscript`/`TimedWord` (Models), `setStatus`/`setProgress`/`setErrorMessage` (kept), `TranscriptionError`, `TranslationError` (FoundationModels).
- Produces: the retry loop, result collection, timeout helpers, cancel, and translation error mapping as internal methods.

- [ ] **Step 1: Extract** — header `import os`, `import Foundation`, `import Speech`, `import AVFoundation`, `import Translation`, `import FoundationModels`, `import CoreData`. Widen moved + cross-referenced privates (incl. `speechAnalyzer`).

- [ ] **Step 2: Build + fix widenings**

- [ ] **Step 3: Run the full unit suite**

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService transcription engine"
```

---

### Task 7: Extract the summarization cluster + LLM session wrapper

**Files:**

- Create: `Pangolin/Services/SpeechTranscriptionService+Summarization.swift`
- Modify: `Pangolin/Services/SpeechTranscriptionService.swift` (remove `estimateTokens`…end of file, current lines ~1972–2260; the class's closing brace stays)

**Interfaces:**

- Consumes: `setStatus`/`setProgress` (kept), `SystemLanguageModel` (FoundationModels), `TranscriptionError`.
- Produces: the chunking helpers, `summarizeChunk`, `reduceSummaries`, and the LLM session wrapper as internal methods.

- [ ] **Step 1: Extract** — header `import os`, `import Foundation`, `import NaturalLanguage`, `import FoundationModels`, `import SwiftUI`. Keep the class's final `}` in the class file.

- [ ] **Step 2: Build + fix widenings**

- [ ] **Step 3: Run the full unit suite**

- [ ] **Step 4: Commit**

```bash
git add Pangolin/Services/ && git commit -m "refactor: extract SpeechTranscriptionService summarization cluster"
```

---

### Task 8: Final verification

- [ ] **Step 1: Full suite + UI target**

Run: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test`
Expected: PangolinTests 275/275, PangolinUITests 4/4.

- [ ] **Step 2: LSP diagnostics**

Run `lsp_diagnostics` over `Pangolin/Services/` — expect zero errors.

- [ ] **Step 3: Manual smoke (human)**

The transcription pipeline has no unit coverage; after the split, the user should run a transcription, a translation, and a summary in the app to confirm the flows still work end-to-end.

- [ ] **Step 4: Commit any stragglers; update `docs/follow-ups.md`** (mark the SpeechTranscriptionService god-file item complete; note remaining: merge-policy follow-ups, CI test job, iPadOS multi-select, double-click-rename runtime check).

---

## Self-Review

- **Spec coverage:** Every region of the 2261-line file maps to Tasks 1–7 (types, translation, flashcards, audio, language detection, transcription engine, summarization); Task 8 gates the whole split. The four public flow methods and the flow gate stay untouched in the class file.
- **Placeholder scan:** Each task has concrete extraction ranges (line numbers verified against the current file), file headers with the required framework imports, exact build/test commands, and commit messages. No TBDs. Widenings are stated generically ("widen moved + cross-referenced privates") because the exact set is only determinable at build time — the same reality as the FolderNavigationStore/ProcessingQueueManager splits, where the build named the members.
- **Type consistency:** Method names/signatures are unchanged across tasks; the extension files all target `SpeechTranscriptionService`; the `TranscriptionFlowKind`/`TranscriptionFlowClaimPolicy` types extracted in Task 1 are referenced by Tasks 6's cancel path and the kept flow gate with identical names.
- **Known risk (flagged):** the transcription pipeline has no unit tests, so Tasks 2–7's "tests pass" gates only prove compilation + no regression in the 275-suite; the end-to-end flow check is Task 8 Step 3 (manual). This is inherent to the current test coverage, not the split.
