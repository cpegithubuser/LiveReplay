# CameraManager Code Review

Review of `CameraManager.swift`, `CameraManager+CaptureOutput.swift`, and `CameraManager+AssetWriter.swift` with comments and improvement suggestions.

**Implemented:** The improvements from this review have been applied and documented in **`CameraManager_CHANGES.md`**. That file describes each change (optionals, thread safety, error handling, orientation unity, cancel completion, bounds guards, delegate cleanup, and logging off the delegate queue).

---

## 1. Architecture & Responsibilities

**Summary:** CameraManager owns capture session setup, device/format/frame-rate selection, asset writer lifecycle, and delegates sample-buffer handling and segment output. It coordinates with `BufferManager` and `PlaybackManager` via singletons. Queue usage: `sessionQueue` (capture session), `writerQueue` (writing + capture callback work), `captureQueue` (sample buffer delegate queue).

**Good:**
- Clear separation into main file + CaptureOutput + AssetWriter extensions.
- Session and writer lifecycle isolated on dedicated queues.
- Thread-safe BufferManager API used correctly (e.g. `setBufferTimeOffset`, `getBufferSnapshot`).

---

## 2. Critical Issues

### 2.1 Force unwraps and `assert` — crash risk

**Location:** `CameraManager.swift` (assetWriter, videoInput, startTime); `CameraManager+CaptureOutput.swift` (assert(success)).

- `var assetWriter: AVAssetWriter!`  
- `var videoInput: AVAssetWriterInput!`  
- `var startTime: CMTime!`  
- `let success = assetWriter.startWriting()` then `assert(success)`

If `createAssetWriter()` fails (e.g. `try? AVAssetWriter(...)` returns nil), `assetWriter` and `videoInput` stay nil and later use can crash. `assert(success)` will crash in Debug and is a no-op in Release, so writer can be in a bad state without failing fast.

**Suggestions:**
- Make writer/input/startTime optional (`AVAssetWriter?`, etc.) and guard before use where they’re already checked (e.g. CaptureOutput already has `guard let writer = assetWriter`).
- In `createAssetWriter()`, if `AVAssetWriter(contentType:)` throws or returns nil, set `assetWriter = nil`, `videoInput = nil`, and either log and return or propagate an error (e.g. completion handler).
- Replace `assert(success)` with: if `!success` { log error; cancel writer / reset state; return } so failures are handled in all build configs.

### 2.2 `droppedFrames` — data race

**Location:** `CameraManager+CaptureOutput.swift` (read/write `droppedFrames`); `CameraManager.swift` (write in `initializeAssetWriter`).

- Capture callback runs on `captureQueue` and does `if droppedFrames < 3 { droppedFrames += 1; return }`.
- `initializeAssetWriter()` runs on `writerQueue` and does `self.droppedFrames = 0`.

Two queues mutate/read the same Int without synchronization → data race and undefined behavior.

**Suggestion:** Protect with a serial queue or lock, or make “drop first N frames” a single atomic (e.g. use a small wrapper that’s only ever read/written on one queue, or `OSAllocatedUnfairLock`/`NSLock` around read-modify-write and reset).

### 2.3 `PlaybackManager.currentTime` — written from background queue

**Location:** `CameraManager+CaptureOutput.swift`: `playbackManager.currentTime = CMTimeAdd(...)` inside `writerQueue.async`.

If `PlaybackManager.currentTime` is a plain `var` and read on main (e.g. UI), writing it from `writerQueue` is a data race.

**Suggestion:** Either:
- Publish `currentTime` on main (e.g. `DispatchQueue.main.async { self.currentTime = ... }`), or
- Make `currentTime` thread-safe (e.g. protected by a queue/lock or atomic-style access) and document the threading model.

### 2.4 `selectedFormatIndex` didSet — possible index out of range

**Location:** `CameraManager.swift` lines 99–116.

In `selectedFormatIndex`’s `didSet` you use `availableFormats[selectedFormatIndex]` and `availableFormats[selectedFormatIndex].videoSupportedFrameRateRanges`. If `selectedFormatIndex` was set to a value ≥ `availableFormats.count` (e.g. after device/format list changed), this will crash.

**Suggestion:** At the start of `didSet`, guard:  
`guard availableFormats.indices.contains(selectedFormatIndex) else { return }`  
(or clamp and re-assign), then use the index. Same pattern is used later in `updateAvailableFormats()`; centralize bounds checks when setting format/FPS.

### 2.5 `createAssetWriter()` — silent failure and index safety

**Location:** `CameraManager.swift` ~395–420.

- `assetWriter = try? AVAssetWriter(...)` swallows errors; caller has no way to know the writer failed.
- `let fmt = availableFormats[selectedFormatIndex]` can crash if `selectedFormatIndex` is out of bounds (e.g. format list changed before writer init).

**Suggestions:**
- Use `do { assetWriter = try AVAssetWriter(...) } catch { ...; return }` and log; optionally notify (e.g. completion or published error state) so UI can show “recording failed to start”.
- Before using `selectedFormatIndex`, clamp:  
  `let idx = min(max(0, selectedFormatIndex), availableFormats.count - 1)`  
  and use `availableFormats[idx]` (and consider syncing `selectedFormatIndex` with that if you want consistent state).

---

## 3. Design & Consistency

### 3.1 Two orientation properties

**Location:** `CameraManager.swift`: `captureVideoOrientation` and `selectedVideoOrientation`.

- `captureVideoOrientation`’s `didSet` forces the connection to `.landscapeRight` (line 233), so the stored value is effectively ignored for the live connection.
- `selectedVideoOrientation` actually drives the connection and `initializeAssetWriter()`.

Having two properties is confusing; one is effectively overridden.

**Suggestion:** Use a single source of truth (e.g. `selectedVideoOrientation`) for both the live preview connection and the asset writer. Remove or repurpose `captureVideoOrientation` so the naming and behavior match.

### 3.2 Redundant fallback

**Location:** `CameraManager.swift` line 199.

`selectedFrameRate = availableFrameRates.first ?? availableFrameRates.first ?? 30` — the second `availableFrameRates.first` is redundant.

**Suggestion:** `availableFrameRates.first ?? 30`.

### 3.3 Unused `delegate` property

**Location:** `CameraManager.swift` line 39.

`var delegate: AVCaptureVideoDataOutputSampleBufferDelegate?` is unused; the output uses `self` as the sample buffer delegate.

**Suggestion:** Remove it, or document and use it (e.g. forward callbacks); otherwise it’s dead code.

### 3.4 Redundant block in capture callback

**Location:** `CameraManager+CaptureOutput.swift` lines 61–66.

After handling `writer.status == .unknown` you set `startTime`, start the session, and set buffer time offset. The block `if startTime == nil { ... startWriting(); startTime = ... }` is redundant for the `.unknown` path and can leave duplicate start logic.

**Suggestion:** Treat “writer not yet started” once: e.g. if `writer.status == .unknown`, start writing, set `startTime`, set buffer offset, then fall through; remove the separate `if startTime == nil` block or fold its logic into the same branch so you don’t double-start.

---

## 4. Error Handling & Observability

### 4.1 Print vs structured handling

**Locations:** Various `print("…")` and `print("⚠️ …")` for errors (e.g. createCaptureSession, createAssetWriter, “Could not access pixel buffer”).

**Suggestion:** Prefer a single logging/error path (e.g. `os.log` or a small `Logger` / error callback) and, for user-facing failures (e.g. “recording couldn’t start”), expose an `@Published` error or completion so the UI can react.

### 4.2 Asset creation failure in delegate

**Location:** `CameraManager+AssetWriter.swift`: `guard let asset = AVURLAsset(mp4Data: mp4Data) else { return }`.

Segment is dropped silently when asset creation fails.

**Suggestion:** Log (with segment identifier/size) and optionally increment a “failed segment” counter or set an error state so you can detect and alert on repeated failures.

---

## 5. Minor / Cleanup

### 5.1 Commented-out code and debug prints

**Locations:** Multiple commented blocks and print statements (e.g. orientation, frame dimensions, PTS).

**Suggestion:** Remove commented-out code or move to a debug-only path; keep only intentional logs behind a debug flag or `printBug`-style API.

### 5.2 Magic numbers

- `droppedFrames < 3` — consider a named constant (e.g. `private let initialFramesToDrop = 3`).
- `assetWriterInterval: Double = 1.0` is already named; segment duration derived from it is clear.

### 5.3 `cancelAssetWriter` / `cancelCaptureSession` — no completion

Both use `queue.async { ... }` and don’t notify when teardown is done. Callers that need to “cancel then start again” may race.

**Suggestion:** Add an optional completion (e.g. `cancelAssetWriter(completion: (() -> Void)? = nil)`) and call it at the end of the async block so `initializeAssetWriter` or app lifecycle can wait for cancel to finish before reinitializing if needed.

### 5.4 Heavy work on delegate queue (AssetWriter)

**Location:** `CameraManager+AssetWriter.swift`: `printPlayerItemBuffer()`, `printPlayerQueueWithAssets()` and multiple `printBug` calls from the asset writer delegate.

The delegate may be called on an internal AVFoundation queue. Doing heavy or synchronous work (or calling back into BufferManager/PlaybackManager) can stall the writer.

**Suggestion:** Keep delegate work minimal: capture what you need, then `DispatchQueue.main.async` (or a dedicated queue) for logging and UI updates. Already using main for `insert(playerItem, after: nil)` which is good.

---

## 6. Summary of Suggested Changes (by priority)

| Priority | Item | Action |
|----------|------|--------|
| P0 | Force unwraps / assert | Make writer/input/startTime optional; handle creation failure; replace assert with error handling |
| P0 | droppedFrames race | Synchronize access (queue or lock) |
| P0 | currentTime race | Publish on main or make access thread-safe |
| P0 | selectedFormatIndex bounds | Guard or clamp in didSet and in createAssetWriter |
| P1 | createAssetWriter failure | Log and optionally expose error state |
| P1 | Single orientation source | Unify captureVideoOrientation / selectedVideoOrientation |
| P1 | Redundant start block | Simplify “start writing” logic in CaptureOutput |
| P2 | Unused delegate, redundant first ?? | Remove or use; fix fallback |
| P2 | Silent asset failure | Log and optionally track failed segments |
| P2 | cancel completion | Optional completion for cancel methods |
| P2 | Delegate workload | Move logging off delegate queue |

If you want, the next step can be concrete patches for P0 items (optionals, synchronization, bounds checks, and currentTime publishing) in the relevant files.
