# PlaybackManager Code Review

Review of `PlaybackManager.swift` and its interaction with `PlayerSeeker.swift`, focusing on playback state, seeking, jumping, rewind/forward, and related behavior.

**Implemented in code (this session):**
- **advanceToNextItemWithSnapshot:** Removed `|| true`; behavior is now “if nextItemIsSeeking → snapshotHandler, else → advanceToNextItem”.
- **jump(to:):** Replaced dead `queueItems.contains(targetItem) && false` with real logic: insert only when `!queueItems.contains(targetItem)`, else skip insert (still advance and prune).
- **jump(to:):** Guard on `item.duration.isValid` and `item.duration.isNumeric` before using duration in the slot-finding loop.
- **scrub(to:allowSeekOnly:):** Guard on `currentItem.duration.isValid` / `isNumeric`; if invalid, call `jump(to:)` instead of building an invalid range. Removed debug prints (“target time”, “currently playing”, “itemlocalrange”).

Other suggestions (threading for rewind/forward, remove “x” versions, set/remove currentPlayingAsset, deinit, etc.) remain as recommendations in the sections below.

---

## 1. Architecture & Responsibilities

**Summary:** PlaybackManager is a singleton that owns the `AVQueuePlayer`, maintains “live” time (`currentTime`, `delayTime`), and coordinates scrubbing (in-item seek vs cross-item jump), rewind/forward, ping-pong, and loop. It uses `BufferManager` for thread-safe buffer lookups when jumping. `PlayerSeeker` handles smooth per-item seeks (QA1820-style) and is used when the target time lies inside the current item.

**Good:**
- Clear use of BufferManager’s thread-safe API (`getBufferSnapshot()`, `getPlayerItemAndTiming(at:)`) in `jump(to:)`.
- Jump is serialized with `isJumping` to avoid overlapping queue mutations.
- Main-thread sequencing for seek → insert → advance → prune in `jump(to:)`.
- Rewind/forward clamp delay to buffer and min/max delay; `rewind10Seconds()` / `forward10Seconds()` use a consistent timescale (600) and clamping.

---

## 2. Critical Issues

### 2.1 `advanceToNextItemWithSnapshot` — condition always true

**Location:** Lines 415–424.

```swift
func advanceToNextItemWithSnapshot() {
    DispatchQueue.main.async {
        if self.nextItemIsSeeking || true {   // ← always true
            printBug(.bugSnapshot, "snapshot handler")
            self.snapshotHandler?()
        } else {
            printBug(.bugSnapshot, "advance")
            self.playerConstant.advanceToNextItem()
        }
    }
}
```

**Problem:** `nextItemIsSeeking || true` is always true, so `advanceToNextItem()` is never called from this path. Callers that expect “advance to next item, and if we’re seeking show a snapshot” will only ever get the snapshot and never the advance.

**Suggestion:** Decide intended behavior:
- If “when seeking, show snapshot; otherwise advance”: use `if self.nextItemIsSeeking { self.snapshotHandler?() } else { self.playerConstant.advanceToNextItem() }`.
- If this is only used when a snapshot is wanted and advance is done elsewhere, remove the `else` branch or rename the function and document it.

**Note:** No call sites were found for `advanceToNextItemWithSnapshot` in the repo; it may be dead or called from another target/extension. If dead, remove or mark as unused.

---

### 2.2 `jump(to:)` — dead condition “already in queue”

**Location:** Lines 498–505.

```swift
if queueItems.contains(targetItem) && false {
    printBug(..., "⚠️ targetItem already in queue—skipping insert")
} else {
    ...
    self.playerConstant.insert(targetItem, after: currentItem)
}
```

**Problem:** `&& false` makes the condition always false, so we always insert. The “already in queue—skipping insert” path is dead. Either the intent was to skip insert when the item is already in the queue (to avoid duplicates or reordering issues), or the `&& false` was a temporary disable; as written it’s misleading.

**Suggestion:** If you want to skip insert when the item is already in the queue: use `if queueItems.contains(targetItem) { ... skip insert ... } else { ... insert ... }` and then still advance/prune as needed (e.g. advance to that item if it’s not current). If you always want to insert (e.g. after a fresh seek), remove the dead branch and the `&& false`.

---

### 2.3 `item.duration` / `currentItem.duration` validity in jump and scrub

**Location:** `jump(to:)` line 476; `scrub(to:allowSeekOnly:)` line 533.

- In `jump(to:)`: `CMTimeAdd(startTime, item.duration) > absoluteTime` — `AVPlayerItem.duration` can be `.invalid` or `.indefinite` until the item is loaded. For segments that are already in the buffer and have been played, duration is usually valid; for a newly created item it might not be.
- In `scrub(to:allowSeekOnly:)`: `itemLocalRange` uses `currentItem.duration`; `CMTimeRange.containsTime(targetTime)` with an invalid duration can give wrong results.

**Suggestion:** When using `item.duration` for range checks, guard on validity, e.g. `guard item.duration.isValid, item.duration.isNumeric else { continue }` in the loop, or use a fallback (e.g. assume segment length from BufferManager if available). In scrub, if `currentItem.duration` is not yet valid, treat as “outside current item” and call `jump(to:)` instead of in-item seek.

---

### 2.4 Reading `currentTime` / `delayTime` from a background queue

**Location:** `rewind10Seconds()`, `forward10Seconds()`, `rewind10Secondsx()`, `forward10Secondsx()`.

These methods do `DispatchQueue.global(qos: .userInitiated).async { ... }` and inside the block they read `currentTime`, `getCurrentPlayingTime()`, `delayTime`, and call `scrub(to:...)`. `currentTime` is written only on the main queue (from CameraManager). Reading it from a global queue is a data race (even if often “benign” in practice).

**Suggestion:** Either:
- Run the whole rewind/forward logic on the main queue (e.g. `DispatchQueue.main.async { ... }`), or
- Capture the values you need on the main queue and pass them into the async block:  
  `let now = currentTime; let delay = delayTime; DispatchQueue.global(...).async { ... use now, delay ... }`.

Prefer main if the work is quick (pause, scrub, play); use background only if you have heavy work and then dispatch back to main for player/state updates.

---

## 3. Seeking and Jumping — Design and Edge Cases

### 3.1 Flow summary

- **scrub(to: allowSeekOnly:)**  
  - If there is no `currentItem`, return.  
  - Build the current item’s absolute range with `currentlyPlayingPlayerItemStartTime` and `currentItem.duration`.  
  - If `allowSeekOnly` and `targetTime` is inside that range → **in-item seek** via `seeker?.smoothlySeek(to: localSeekTime)`.  
  - Otherwise → **cross-item jump** via `jump(to: targetTime)`.

- **jump(to:)**  
  - Serialize with `isJumping`; get buffer snapshot and find the buffer slot that contains `absoluteTime` (using `getPlayerItemAndTiming` and `startTime + item.duration`).  
  - Seek the target item to the local offset, then on main: insert after current item, advance to next (the newly inserted item), remove all other items, clear `isJumping`.

This design is sound: in-item seeks avoid queue thrashing; cross-item jumps rebuild the queue around the target segment.

### 3.2 Possible improvement: “already current item” in jump

If the slot that contains `absoluteTime` is already the `currentItem`, you could avoid seek/insert/advance/prune and only seek within the item. That would simplify the common case of “scrub still within current segment but `allowSeekOnly` was false” (e.g. from rewind/forward). Optional refinement.

### 3.3 PlayerSeeker and main-thread usage

`PlayerSeeker.smoothlySeek(to:)` sets `nextSeek` and, if not already seeking, calls `startNextSeek()`, which does `DispatchQueue.main.async { self.player.seek(to: next) { ... } }`. So the actual seek runs on main. Callers (e.g. `scrub(to: allowSeekOnly:)`) should ideally be on main when they call `seeker?.smoothlySeek(...)` so that state and UI stay consistent. Currently scrub can be called from a global queue (rewind/forward). Prefer calling scrub from main, or ensure scrub only reads state that is main-written after capturing it on main.

---

## 4. Design & Consistency

### 4.1 Duplicate rewind/forward implementations

- **rewind10Secondsx()** / **forward10Secondsx()** — older logic (target time + delay, then `scrub(to: targetTime)`), with commented-out `seeker?.smoothlyJump` and a global queue.
- **rewind10Seconds()** / **forward10Seconds()** — newer logic (delay-based clamping with timescale 600, `scrub(to: targetAbs, allowSeekOnly: true)`), also on a global queue.

The UI (ContentView) uses `rewind10Seconds` and `forward10Seconds`. The “x” versions appear unused and add noise.

**Suggestion:** Remove `rewind10Secondsx` and `forward10Secondsx` if nothing calls them; otherwise mark as deprecated and route callers to the non-x versions.

---

### 4.2 `currentPlayingAsset` never set

**Location:** Line 36 — `var currentPlayingAsset: AVAsset?`  
**Observation:** `playerItemDidChange(to:)` sets `currentlyPlayingPlayerItemStartTime` from the associated object but does not set `currentPlayingAsset`. So `currentPlayingAsset` is never assigned and is effectively dead (or set elsewhere not visible in this file).

**Suggestion:** Either set it in `playerItemDidChange` from `newItem?.asset`, or remove the property if it’s unused.

---

### 4.3 Commented-out code and debug prints

**Locations:** Multiple (playbackEffectTimer, wasPlayingBefore, resumeNormalPlayback, step(byCount), “target time”, “currently playing”, “itemlocalrange”, etc.).

**Suggestion:** Remove commented-out code or move to a debug-only path. Prefer `printBug` (or similar) for any remaining logs so they can be toggled.

---

### 4.4 deinit and orientation observer

**Location:** Lines 553–556.

```swift
deinit {
    NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    print("Removed orientation observer.")
}
```

**Observation:** PlaybackManager does not add this observer in the reviewed code. If it’s added in an extension or another file, the remove is correct. If not, the remove is a no-op and the print is misleading. Singleton also rarely deinits.

**Suggestion:** If PlaybackManager never adds this observer, remove the deinit block or document that it’s for symmetry with another component. If the observer is added elsewhere (e.g. CameraManager), consider removing it from PlaybackManager to avoid confusion.

---

### 4.5 `startLoop()` and main queue

**Location:** Lines 364–388.

`startLoop()` calls `playerConstant.addBoundaryTimeObserver(...)` and `playerConstant.seek(...)`. These are AVPlayer APIs that should be used on the main thread. `loop()` is likely invoked from the UI (main); if `startLoop()` can ever be called from a background queue, it should dispatch to main.

**Suggestion:** If in doubt, wrap the body of `startLoop()` in `DispatchQueue.main.async { ... }` (or ensure all callers call it on main).

---

## 5. Minor / Cleanup

### 5.1 Magic numbers

- `maxScrubbingDelay = CMTimeMake(value: 30, timescale: 1)` (30 s)  
- `minScrubbingDelay = CMTimeMake(value: 20, timescale: 10)` (2 s)  
- `playbackLoopWindowDuration = CMTime(seconds: 2, preferredTimescale: 600)`  
- Rewind/forward step: 10 seconds (in rewind10Seconds, forward10Seconds and the “x” versions).

Consider named constants (e.g. `maxScrubbingDelaySeconds`, `rewindForwardStepSeconds`) for clarity and tuning.

### 5.2 `configureLoopWindow` and `configureLoopWindow(around:)`

`configureLoopWindow(around:)` (private) sets `playbackLoopStart` / `playbackLoopEnd` and prints. The other `configureLoopWindow` (lines 266–271) is private and takes no parameters and is unused in the snippet; if it’s dead, remove it. (Actually in the file there’s only one `configureLoopWindow(around:)` at 266; the “private func configureLoopWindow(around time: CMTime)” is the only one. So no duplicate.)

### 5.3 Ping-pong vs loop boundary observer

Both `pingPong()` and `loop()` call `removePlaybackBoundaryObserver()` then add a new observer. That’s correct. `startBoundaryObserver()` (ping-pong) uses two boundaries (start and end) and flips direction; `startLoop()` uses one boundary (loopEnd) and seeks back to start. Clear separation.

---

## 6. Summary of Suggested Changes (by priority)

| Priority | Item | Action |
|----------|------|--------|
| P0 | advanceToNextItemWithSnapshot | Fix or remove `\|\| true`; ensure advance/snapshot behavior is correct; remove if dead |
| P0 | jump() “already in queue” | Fix or remove `&& false`; implement real “skip insert if already in queue” or delete dead branch |
| P1 | item.duration validity | Guard or fallback in jump() and scrub() when using duration for range checks |
| P1 | currentTime/delayTime from background | Run rewind/forward on main or capture state on main before async |
| P2 | rewind10Secondsx / forward10Secondsx | Remove if unused, or deprecate |
| P2 | currentPlayingAsset | Set in playerItemDidChange or remove |
| P2 | Commented-out code, debug prints | Remove or gate behind debug flag |
| P2 | deinit orientation observer | Remove or document if observer is never added here |
| P2 | startLoop() thread | Ensure called on main or wrap in main async |

---

## 7. Seeking and Jumping — Quick Reference

| Entry point | Behavior |
|-------------|----------|
| **scrub(to: allowSeekOnly: true)** | If target in current item range → `seeker?.smoothlySeek(to: localTime)`; else `jump(to:)`. |
| **scrub(to: allowSeekOnly: false)** | Always `jump(to:)` (used by ping-pong/loop to “sync” to current time). |
| **jump(to:)** | Find buffer slot for time → seek target item to local offset → on main: insert after current, advance, prune others. |
| **rewind10Seconds() / forward10Seconds()** | Clamp delay, set `delayTime`, compute `targetAbs = now - delay`, then `scrub(to: targetAbs, allowSeekOnly: true)` on a global queue. |

Fixing the P0 items and tightening threading and duration handling will make seeking and jumping more predictable and easier to maintain.
