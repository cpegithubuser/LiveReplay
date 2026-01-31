# CameraManager – Changes and Improvements

This document summarizes the updates made to `CameraManager.swift`, `CameraManager+CaptureOutput.swift`, and `CameraManager+AssetWriter.swift` following the code review in `CameraManager_CODE_REVIEW.md`. The goal was to improve thread safety, error handling, consistency, and maintainability.

---

## Overview

| Area | Change |
|------|--------|
| **P0 – Crash risk** | Writer/input/startTime made optional; writer creation uses `do/catch`; `assert(success)` replaced with error handling |
| **P0 – Data races** | `droppedFrames` synchronized with lock; `currentTime` written on main only |
| **P0 – Bounds** | Guards on `selectedFormatIndex` in `didSet` and in `createAssetWriter()` / `createCaptureSession()` |
| **P1 – Failure visibility** | `cameraError: Error?` published when writer creation fails; asset creation failure logged |
| **P1 – Orientation** | Single source of truth: `captureVideoOrientation` forwards to `selectedVideoOrientation` |
| **P1 – Start logic** | Single “start writing” path in capture callback; redundant `startTime == nil` block removed |
| **P2 – Cleanup** | Unused `delegate` removed; redundant fallback fixed; cancel methods take optional completion; heavy logging moved off delegate queue |

---

## 1. CameraManager.swift

### 1.1 Imports

**Added:** `import AVFoundation` and `import Foundation` (for `NSLock`, `AVCaptureSession` types used alongside `AVKit`).

---

### 1.2 Drop-frame count (thread safety)

**Before:**
```swift
var droppedFrames: Int = 0
```
- Read/written from `captureQueue` (delegate) and `writerQueue` (reset in `initializeAssetWriter`) with no synchronization → data race.

**After:**
```swift
private static let initialFramesToDrop = 3
private let droppedFramesLock = NSLock()
private var _droppedFramesCount: Int = 0

func shouldDropFrame() -> Bool {
    droppedFramesLock.lock()
    defer { droppedFramesLock.unlock() }
    if _droppedFramesCount < Self.initialFramesToDrop {
        _droppedFramesCount += 1
        return true
    }
    return false
}

func resetDroppedFrames() {
    droppedFramesLock.lock()
    defer { droppedFramesLock.unlock() }
    _droppedFramesCount = 0
}
```

**Rationale:** All access goes through the lock; capture callback uses `shouldDropFrame()`, writer init uses `resetDroppedFrames()`. Magic number `3` is now a named constant.

---

### 1.3 Unused delegate removed

**Before:** `var delegate: AVCaptureVideoDataOutputSampleBufferDelegate?`  
**After:** Removed. The sample buffer delegate is `self`; the property was never used.

---

### 1.4 Asset writer and input optional; startTime optional

**Before:**
```swift
var assetWriter: AVAssetWriter!
var videoInput: AVAssetWriterInput!
var startTime: CMTime!
```

**After:**
```swift
var assetWriter: AVAssetWriter?
var videoInput: AVAssetWriterInput?
var startTime: CMTime?
```

**Rationale:** Avoids force-unwrap crashes when writer creation fails. Call sites already use `guard let writer = assetWriter, let input = videoInput` (e.g. in CaptureOutput); `LiveReplayApp` already uses `assetWriter?.cancelWriting()`.

---

### 1.5 Writer creation failure handling and cameraError

**Before:**
```swift
assetWriter = try? AVAssetWriter(contentType: .mpeg4Movie)
assetWriter?.outputFileTypeProfile = ...
videoInput = AVAssetWriterInput(...)
if let w = assetWriter, w.canAdd(videoInput) { w.add(videoInput) }
```
- Failures were silent; `videoInput` could be created even when `assetWriter` was nil.

**After:**
```swift
do {
    let writer = try AVAssetWriter(contentType: .mpeg4Movie)
    // ... configure writer and input ...
    writer.add(newInput)
    assetWriter = writer
    videoInput = newInput
    DispatchQueue.main.async { self.cameraError = nil }
    print("📝 AssetWriter initialized ...")
} catch {
    assetWriter = nil
    videoInput = nil
    let wrapped = CameraError.writerCreationFailed(error)
    DispatchQueue.main.async { self.cameraError = wrapped }
    print("⚠️ createAssetWriter failed:", error)
}
```

**Added:** `enum CameraError: Error { ... writerCreationFailed(Error) }` and `@Published var cameraError: Error?`. UI can observe `cameraError` to show “recording failed to start”.

---

### 1.6 Orientation: single source of truth

**Before:** Two stored properties: `captureVideoOrientation` (with `didSet` that forced `.landscapeRight` on the connection) and `selectedVideoOrientation` (drove connection and writer). Redundant and confusing.

**After:**
- `captureVideoOrientation` is a computed property that gets/sets `selectedVideoOrientation`.
- `selectedVideoOrientation` remains `@Published` and its `didSet` updates the live connection and calls `initializeAssetWriter()`.
- `createCaptureSession()` and `handleDeviceOrientationChange()` use `selectedVideoOrientation` (or `captureVideoOrientation`, which forwards).

**Rationale:** One source of truth for orientation; no duplicate state.

---

### 1.7 mirroredReplay didSet

**Before:** `if mirroredReplay == true { connection.isVideoMirrored = true } else { connection.isVideoMirrored = false }`  
**After:** `connection.isVideoMirrored = mirroredReplay`

---

### 1.8 handleDeviceOrientationChange

**Before:** Commented-out cases and `print("Updated video orientation ...")`; set `captureVideoOrientation`.  
**After:** Simplified switch; set `selectedVideoOrientation`; removed debug print.

---

### 1.9 selectedFormatIndex didSet – bounds guard

**Before:** Direct use of `availableFormats[selectedFormatIndex]`; crash if index out of range (e.g. after device/format list change).  
**After:** `guard availableFormats.indices.contains(selectedFormatIndex) else { return }` at the start of `didSet`.

---

### 1.10 updateAvailableFormats – dead code removed

**Before:** After clamping with `safeIndex`, a second check `if selectedFormatIndex >= availableFormats.count { selectedFormatIndex = 0 }` (unreachable after clamp).  
**After:** Only the safe-index clamp remains.

---

### 1.11 createCaptureSession – empty formats guard

**Before:** `let idx = min(selectedFormatIndex, availableFormats.count - 1)` with no check for empty `availableFormats` (could yield `idx == -1`).  
**After:** `guard !availableFormats.isEmpty else { return }` before computing `idx`. Connection uses `selectedVideoOrientation` instead of `captureVideoOrientation` (same value, clearer name at call site).

---

### 1.12 cancelCaptureSession / cancelAssetWriter – completion

**Before:** `func cancelCaptureSession()` and `func cancelAssetWriter()` with no way to know when teardown finished.  
**After:**  
- `cancelCaptureSession(completion: (() -> Void)? = nil)` — completion is called on the main queue after session is nil (or immediately on main if there was no session).  
- `cancelAssetWriter(completion: (() -> Void)? = nil)` — completion is called on the main queue at the end of the async block.

**Rationale:** Callers can “cancel then reinitialize” and optionally wait for completion to avoid races.

---

### 1.13 initializeAssetWriter – reset drop count

**Before:** `self.droppedFrames = 0` (and `droppedFrames` was removed).  
**After:** `self.resetDroppedFrames()` so the writer queue uses the thread-safe reset.

---

### 1.14 createAssetWriter – format index guard

**Before:** `let fmt = availableFormats[selectedFormatIndex]` with no guard (could crash if format list changed).  
**After:** `guard !availableFormats.isEmpty, availableFormats.indices.contains(selectedFormatIndex) else { ... return }` and a clear print when deferred.

---

### 1.15 Removed commented / unused code

- Removed commented `@Published var cameraLocation: AVCaptureDevice.Position` block.
- Removed `writerStarted` (unused).
- Removed redundant `availableFrameRates.first ?? availableFrameRates.first ?? 30` → `availableFrameRates.first ?? 30` (already applied earlier).

---

## 2. CameraManager+CaptureOutput.swift

### 2.1 Drop-frame check – use synchronized API

**Before:**  
- `if droppedFrames < 3 { droppedFrames += 1; return }` on the capture (delegate) queue.  
- `self.droppedFrames = 0` on the writer queue in `initializeAssetWriter`.  
- Data race between the two queues.

**After:** `if shouldDropFrame() { return }` at the top of the delegate. No direct access to `droppedFrames`; all access is through `shouldDropFrame()` and `resetDroppedFrames()`.

---

### 2.2 currentTime – write on main only

**Before:** `playbackManager.currentTime = CMTimeAdd(currentMediaTime, bufferManager.bufferTimeOffset)` inside `writerQueue.async`.  
- `PlaybackManager.currentTime` is a plain `var` read on main (e.g. UI); writing from `writerQueue` is a data race.

**After:**  
- Compute the new value on the writer queue.  
- `DispatchQueue.main.async { self.playbackManager.currentTime = newCurrentTime }` so the write happens on the main thread.

---

### 2.3 Start-writing logic – single path, no assert

**Before:**  
- `if writer.status == .unknown { let success = assetWriter.startWriting(); assert(success); startTime = ...; startSession(...); setBufferTimeOffset(...) }`  
- Then a separate `if startTime == nil { ... startWriting(); startTime = ...; startSession(...) }` (redundant after the first branch).  
- `assert(success)` crashes in Debug and is a no-op in Release.

**After:**  
- Single `switch writer.status { case .unknown: guard writer.startWriting() else { print(...); return }; startTime = pts; startSession(atSourceTime: pts); setBufferTimeOffset(...); case .writing: break; default: print(...); return }`.  
- No second “start” block.  
- `guard writer.startWriting() else { ... return }` so Release builds don’t continue after failure.

---

### 2.4 Removed noisy / commented code

- Removed the “Print the width and height of the frame” block and the “Could not access pixel buffer” print from the hot path.  
- Removed commented `print(sampleBuffer.presentationTimeStamp)`.

---

## 3. CameraManager+AssetWriter.swift

### 3.1 Asset creation failure – log and return

**Before:** `guard let asset = AVURLAsset(mp4Data: mp4Data) else { return }` with no log.  
**After:**  
- `guard let asset = AVURLAsset(mp4Data: mp4Data) else { print("⚠️ AVURLAsset(mp4Data:) failed for segment \(segmentNum), size \(mp4Data.count)"); return }`  
- Makes segment failures visible and debuggable.

---

### 3.2 Heavy work off delegate queue

**Before:**  
- Multiple `printBug` calls and `playbackManager.printPlayerItemBuffer()` / `printPlayerQueueWithAssets()` ran on the asset writer delegate (internal AVFoundation queue).  
- Could stall the writer and cause backpressure.

**After:**  
- Delegate only: create asset, create player item, associate start time, then `DispatchQueue.main.async { insert(playerItem, ...); printPlayerItemBuffer(); printPlayerQueueWithAssets() }`.  
- `bufferManager.addNewAsset(asset:)` remains on the delegate (required for ordering); one `printBug` for “segment added” stays on delegate (lightweight).  
- All UI and buffer-printing work runs on main.

---

### 3.3 Commented / redundant code removed

- Removed commented segment name, tracks, PTS, and pointer logs.  
- Kept a single concise `printBug(.bugAssetWriter, "segment:", segmentNum, "size:", segmentData.count, "✅ [AVPlayer] Added player item.")`.

---

## 4. Call sites (no API change required)

- **LiveReplayApp:** Already uses `CameraManager.shared.assetWriter?.cancelWriting()`; optional works.  
- **PlaybackManager:** No change; it only reads `currentTime` (now updated only on main).  
- **ContentView / others:** No changes required; they use existing APIs.

---

## 5. Summary table

| File | Section | Change |
|------|---------|--------|
| CameraManager | Drop frames | Lock-protected `_droppedFramesCount`; `shouldDropFrame()` / `resetDroppedFrames()` |
| CameraManager | Writer/input/startTime | Optional types; creation in `do/catch` with `cameraError` |
| CameraManager | Orientation | `captureVideoOrientation` forwards to `selectedVideoOrientation` |
| CameraManager | Cancel | Optional completion; completion invoked on main |
| CameraManager | Bounds | Guards in `selectedFormatIndex` didSet, `createCaptureSession`, `createAssetWriter` |
| CameraManager | Other | Removed unused delegate, writerStarted; simplified mirroredReplay, updateAvailableFormats |
| CaptureOutput | Drop / currentTime / start | `shouldDropFrame()`; currentTime on main; single start path, no assert |
| AssetWriter | Failure / queue | Log when asset is nil; buffer print and insert on main |

These updates align with the priorities and suggestions in `CameraManager_CODE_REVIEW.md` and keep behavior the same while improving safety and observability.
