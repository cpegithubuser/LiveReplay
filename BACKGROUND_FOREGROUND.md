# Background / Foreground Lifecycle — How It Works

> Last updated: January 30, 2026

This document describes **how LiveReplay handles the app moving to the background and
returning to the foreground**, including the problems the original implementation had, the
changes that were made, and a full walkthrough of the current design.

---

## Table of Contents

1. [Key Concepts](#1-key-concepts)
2. [How It Used to Work (Original Implementation)](#2-how-it-used-to-work-original-implementation)
3. [Problems with the Original Implementation](#3-problems-with-the-original-implementation)
4. [What Changed (Summary of Fixes)](#4-what-changed-summary-of-fixes)
5. [How It Works Now (Full Walkthrough)](#5-how-it-works-now-full-walkthrough)
6. [File-by-File Reference](#6-file-by-file-reference)

---

## 1. Key Concepts

### The Buffer Timeline vs. Wall Clock

LiveReplay records video into a circular buffer of ~1-second segments. Each segment has a
**buffer time** — a logical timestamp that starts at 0 on launch and increases as segments
are added. The variable `nextBufferStartTime` always holds the buffer time where the next
segment will begin.

The real-world clock (`CACurrentMediaTime()`) is a monotonic wall clock that always advances,
even when the app is in the background.

`bufferTimeOffset` is the bridge between the two:

```
currentTime = CACurrentMediaTime() + bufferTimeOffset
```

`currentTime` represents "now" in buffer time — the live edge. The scrub bar's position is
derived from the **delay**: `delay = currentTime − playerPosition`.

### Why the Offset Matters

- If `bufferTimeOffset` is correct, `currentTime` tracks the live edge of the buffer.
- If `bufferTimeOffset` is wrong (e.g., after the app was backgrounded and the wall clock
  jumped forward while recording stopped), `currentTime` jumps, and the scrub bar jumps.

### Key Variables

| Variable | Location | Description |
|---|---|---|
| `bufferTimeOffset` | `BufferManager` | Maps wall clock → buffer time |
| `nextBufferStartTime` | `BufferManager` | Buffer time where next segment will start |
| `currentTime` | `PlaybackManager` | "Live edge" in buffer time; set every frame |
| `segmentIndex` | `BufferManager` | Count of segments added so far |
| `backgroundTime` | `LiveReplayApp` | Wall clock snapshot when app went to background |
| `wasPlaying` | `LiveReplayApp` | Whether the player was playing before backgrounding |
| `resumePlaybackOnFirstFrame` | `CameraManager` | Deferred-resume flag |

---

## 2. How It Used to Work (Original Implementation)

The original code (before our changes) had this in `LiveReplayApp.swift`:

```swift
case .background:
    backgroundTime = CACurrentMediaTime()
    wasPlaying = PlaybackManager.shared.playerConstant.rate > 0
    PlaybackManager.shared.pausePlayer()
    CameraManager.shared.assetWriter?.cancelWriting()   // cancel writer directly

case .active:
    let delta = CACurrentMediaTime() - backgroundTime
    let deltaCM = CMTime(seconds: delta, preferredTimescale: 600)
    // ADD delta to offset
    BufferManager.shared.bufferTimeOffset = CMTimeAdd(
        BufferManager.shared.bufferTimeOffset, deltaCM
    )
    CameraManager.shared.initializeCaptureSession()
    CameraManager.shared.initializeAssetWriter()        // resetBuffer defaults to true
    if wasPlaying {
        PlaybackManager.shared.playerConstant.play()
        PlaybackManager.shared.playbackState = .playing
    }
```

And in `BufferManager.addNewAsset`, the offset was unconditionally recalculated every segment:

```swift
self.bufferTimeOffset = CMTimeSubtract(
    self.nextBufferStartTime,
    CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
)
```

---

## 3. Problems with the Original Implementation

### Problem A — `initializeAssetWriter()` called `resetBuffer()`

The default `initializeAssetWriter()` always called `resetBuffer()`, which:
- Set `segmentIndex = 0`, `nextBufferStartTime = .zero`, `bufferTimeOffset = .zero`
- Cleared all compositions, player items, and timing entries
- Paused and cleared the AVQueuePlayer

**Result**: On returning from background, the entire buffer was wiped. The user lost all
recorded video. The scrub bar went blank (all crosshatch). The player showed nothing.

### Problem B — `addNewAsset` hard-reset `bufferTimeOffset` every segment

Every time a new 1-second segment was added, `addNewAsset` recalculated:

```swift
bufferTimeOffset = nextBufferStartTime − CACurrentMediaTime()
```

During normal operation, this correction is tiny (a few milliseconds of jitter). But after
returning from background with a manually-adjusted offset, the correction is large
(~0.5–1.0 seconds). This caused the scrub knob to jump rightward as the first new segments
completed.

### Problem C — Player resumed before frames arrived

In `.active`, the player was resumed immediately via `.play()`. But the camera takes ~0.3–0.5
seconds to start delivering frames. During this gap:
- The player's position advanced (it was playing)
- `currentTime` was stale (no frames → no update)
- `delay = currentTime − playerPosition` shrank
- The scrub knob drifted **rightward** (toward live)

### Problem D — Camera startup gap inflated `currentTime`

When the first frame finally arrived after background, `currentTime` jumped forward by the
startup time (~0.3–0.5 sec). The player hadn't caught up yet → delay was briefly inflated
→ the scrub knob jumped **leftward** for a fraction of a second.

### Observable Symptoms

The user saw, on returning from background:
1. Knob moves **left** (delay inflates — Problem D)
2. Knob moves **right** (addNewAsset recalculates offset — Problem B + C)
3. Or the buffer was completely wiped (Problem A)

---

## 4. What Changed (Summary of Fixes)

Four changes across four files. Each fix targets one of the problems above.

### Fix 1 — `initializeAssetWriter(resetBuffer: false)` (Problems A)

**File**: `CameraManager.swift` — `initializeAssetWriter` gained a `resetBuffer` parameter.
**File**: `LiveReplayApp.swift` — `.active` calls `initializeAssetWriter(resetBuffer: false)`.
**File**: `CameraManager+CaptureOutput.swift` — fallback also passes `resetBuffer: false`.

When resuming from background, the existing buffer, compositions, segment index, and timeline
are preserved. Only a fresh `AVAssetWriter` is created to begin recording new segments.

### Fix 2 — Guarded offset re-sync in `addNewAsset` (Problem B)

**File**: `BufferManager.swift` — `addNewAsset`

Instead of unconditionally recalculating `bufferTimeOffset`, the correction is checked:

```swift
let correction = CMTimeSubtract(newOffset, self.bufferTimeOffset).seconds
if segmentIndex == 0 || abs(correction) < 0.1 {
    self.bufferTimeOffset = newOffset
}
```

- `segmentIndex == 0`: First segment after cold start or `resetBuffer()` — always apply
  (the offset was `.zero` and needs to be initialized).
- `abs(correction) < 0.1`: Normal jitter (~few ms) — apply to prevent long-term drift.
- After background, the correction is ~0.5–1.0 sec — **blocked**, so the scrub bar stays put.

### Fix 3 — Deferred player resume (Problem C)

**File**: `CameraManager.swift` — added `resumePlaybackOnFirstFrame: Bool` property.
**File**: `LiveReplayApp.swift` — `.active` sets the flag instead of calling `.play()`.
**File**: `CameraManager+CaptureOutput.swift` — on the first non-dropped frame, the flag is
checked, cleared, and the player is resumed on the main queue.

This ensures the player and `currentTime` start advancing at the same instant. No gap where
the player advances while `currentTime` is stale.

### Fix 4 — Startup-gap absorption (Problem D)

**File**: `CameraManager+CaptureOutput.swift` — on the resume frame:

```swift
let targetCurrentTime = playbackManager.currentTime   // set in .active
bufferManager.bufferTimeOffset = CMTimeSubtract(targetCurrentTime, currentMediaTime)
```

This re-adjusts the offset so that `wallClock + offset = targetCurrentTime` (the value
`.active` placed). The camera-startup gap (time between `.active` and first frame) is
absorbed into the offset. `currentTime` never jumps forward, so the delay never inflates,
and the scrub knob never moves left.

---

## 5. How It Works Now (Full Walkthrough)

### Normal Operation (No Background)

```
captureOutput fires at ~30fps
  └─ currentTime = CACurrentMediaTime() + bufferTimeOffset
  └─ frame is written to AVAssetWriter
  └─ every ~1 sec, segment finishes:
       └─ addNewAsset() called
            └─ nextBufferStartTime += segment.duration
            └─ offset re-synced (correction ~few ms, passes threshold)
            └─ segment added to compositions → AVPlayerItem created → enqueued
```

`currentTime` advances smoothly with the wall clock. The offset re-sync corrects tiny
per-segment jitter. The scrub bar is stable.

### Going to Background

**`LiveReplayApp.swift` — `.background` handler:**

```
1. backgroundTime = CACurrentMediaTime()          ← snapshot wall clock
2. wasPlaying = player.rate > 0                   ← remember playback state
3. PlaybackManager.pausePlayer()                  ← pause AVQueuePlayer
4. CameraManager.cancelCaptureSession()           ← tear down AVCaptureSession
5. CameraManager.cancelAssetWriter()              ← cancel AVAssetWriter, nil refs
```

At this point:
- Recording has stopped. No new frames or segments.
- `currentTime` is frozen at its last value (stored property, not computed).
- `bufferTimeOffset`, `nextBufferStartTime`, and all buffer data are preserved.
- The player is paused; its position is frozen.

### Returning to Foreground

**`LiveReplayApp.swift` — `.active` handler:**

```
1. delta = CACurrentMediaTime() - backgroundTime
      (how long we were away — e.g., 5 seconds)

2. bufferTimeOffset -= delta
      (subtract the gap so that wallClock + offset still equals the
       pre-background currentTime value)

3. currentTime = CACurrentMediaTime() + bufferTimeOffset
      (eagerly update so the UI doesn't show a stale value)

4. initializeCaptureSession()     ← rebuild AVCaptureSession (async)
5. initializeAssetWriter(resetBuffer: false)
      (create fresh AVAssetWriter; do NOT wipe the buffer)

6. resumePlaybackOnFirstFrame = wasPlaying
      (defer .play() until frames arrive)
```

After step 3, `currentTime` = pre-background value (approximately). The scrub bar renders
at the same position as before. The player is still paused — no drift.

### Camera Startup (~0.3–0.5 sec later)

The capture session starts delivering frames. The first 3 are dropped (dark frames from
camera warm-up). On the 4th frame:

```
CaptureOutput:
  1. currentMediaTime = CACurrentMediaTime()
  2. resumePlaybackOnFirstFrame is true →
       a. targetCurrentTime = playbackManager.currentTime   (the .active value)
       b. bufferTimeOffset = targetCurrentTime - currentMediaTime
            → absorbs the startup gap into the offset
       c. resumePlaybackOnFirstFrame = false
       d. dispatch to main: player.play()
  3. currentTime = currentMediaTime + bufferTimeOffset = targetCurrentTime
       → no change! The knob doesn't move.
```

From this point on, `currentTime` advances with the wall clock, and the player also advances.
They start at the same instant, so `delay = currentTime − playerPosition` is constant.

### First New Segment Completes (~1 sec later)

```
addNewAsset:
  1. nextBufferStartTime += segment.duration
  2. newOffset = nextBufferStartTime - CACurrentMediaTime()
  3. correction = newOffset - bufferTimeOffset
       → This is ~0.5–1.0 sec (the "gap" baked into the offset by the startup absorption)
       → abs(correction) > 0.1 → BLOCKED
  4. bufferTimeOffset stays as-is. Scrub bar stays put.
```

Subsequent `addNewAsset` calls also have the same-magnitude correction → also blocked.
During normal operation (no background involved), the correction is ~2–5 ms → passes.
This way, normal jitter correction continues working while post-background jumps are prevented.

### Timeline Diagram

```
Wall clock:  ────T_bg──────────────T_active───T_frame1────T_seg1────▶
                 │    (background)    │         │            │
                 │    delta = 5 sec   │  startup │  ~1 sec    │
                 │                    │  ~0.3 sec│            │

Buffer time: ────N+gap───(frozen)────N+gap──────N+gap────────N+gap──▶
                                     ▲          ▲            ▲
                                     │          │            │
                                  offset     offset       addNewAsset
                                  adjusted   re-adjusted   correction
                                  (−delta)   (absorb       BLOCKED
                                              startup)

Player pos:  ────P───────(frozen)────P──────────P────────────P+dt───▶
                                                ▲
                                                │
                                             .play() here
```

---

## 6. File-by-File Reference

### `LiveReplayApp.swift`

The **only** place that handles `scenePhase` changes. Contains the `.background` and
`.active` handlers.

| Line(s) | Purpose |
|---------|---------|
| 15–16 | `@State` vars: `backgroundTime`, `wasPlaying` |
| 24–29 | `.background`: snapshot clock, pause player, tear down capture + writer |
| 31–49 | `.active`: adjust offset, update currentTime, restart capture + writer, defer resume |

### `CameraManager.swift`

| Item | Purpose |
|------|---------|
| `resumePlaybackOnFirstFrame: Bool` | Flag set by `.active`, cleared by first frame |
| `cancelCaptureSession()` | Tears down AVCaptureSession cleanly |
| `cancelAssetWriter()` | Cancels writer, nils out `assetWriter`, `videoInput`, `startTime` |
| `initializeAssetWriter(resetBuffer:)` | Creates fresh writer; `resetBuffer: false` preserves buffer |

### `CameraManager+CaptureOutput.swift`

The frame-level delegate. On each frame (after 3 dropped):

| Line(s) | Purpose |
|---------|---------|
| 29–38 | Check `resumePlaybackOnFirstFrame`: absorb startup gap into offset, resume player |
| 40 | Update `currentTime = wallClock + offset` |
| 52–56 | Guard writer/input; fallback to `initializeAssetWriter(resetBuffer: false)` |
| 58–63 | Start writer session on first frame |
| 77–78 | Append sample buffer to writer |

### `BufferManager.swift`

| Item | Purpose |
|------|---------|
| `bufferTimeOffset` | The wall-clock → buffer-time mapping |
| `nextBufferStartTime` | Buffer time for next segment |
| `addNewAsset(asset:)` | Adds segment to compositions; guarded offset re-sync |
| `resetBuffer()` | Full wipe — only called on cold start / camera switch, **not** on background return |

**Guarded re-sync in `addNewAsset`** (lines 69–80):
```swift
let correction = CMTimeSubtract(newOffset, self.bufferTimeOffset).seconds
if segmentIndex == 0 || abs(correction) < 0.1 {
    self.bufferTimeOffset = newOffset
}
```
- `segmentIndex == 0` → first segment ever (or after `resetBuffer`) → always apply
- `< 0.1` → normal per-segment jitter → apply
- `> 0.1` → post-background correction → block
