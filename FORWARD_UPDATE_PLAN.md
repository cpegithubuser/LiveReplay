# Forward Update Plan (after revert)

**Revert completed.** Forward updates below are for when you say go.

**Important:** The "jump to 3 fingers then back" / wrong first frame on auto-start is **pre-existing** in the code (present before any PlaybackManager refactor). Fixes we had implemented targeted this bug; when we re-apply forward, we will address it again.

---

Use this as a checklist when re-applying improvements.

---

## 1. PlaybackManager refactor (thread safety, error handling)

- **Thread safety**: Replace `DispatchSemaphore` with a `DispatchQueue` (or keep existing sync) for all shared state; ensure public properties (`bufferTimeOffset`, `segmentIndex`, `earliestPlaybackBufferTime`, `nextBufferStartTime`, etc.) are accessed only via thread-safe API.
- **Error handling**: Replace `try!` with `do/catch`; replace force unwraps with `guard let` where appropriate; introduce a small `BufferError` (or similar) if needed.
- **Integration**: Update `LiveReplayApp.swift`, `PlaybackManager.swift`, `CameraManager+CaptureOutput.swift`, `CameraManager+AssetWriter.swift` to use the new BufferManager API (any renamed or refactored methods/properties).
- **Docs**: See `BufferManager_CODE_REVIEW.md` for original review and P0 items.

---

## 2. BufferManager integration (if reverted)

- Ensure `BufferManager.shared` is used consistently.
- Restore thread-safe accessors if reverted: `bufferTimeOffset`, `earliestPlaybackBufferTime`, `nextBufferStartTime`, `segmentIndex`, `adjustBufferTimeOffset(by:)`, etc.
- Restore any `accessQueue.sync` (or equivalent) usage for mutable state.

---

## 3. CameraManager refactor (if reverted)

- **Crash risk**: Make `assetWriter`, `videoInput`, `startTime` optional; use `do/catch` for `AVAssetWriter` creation; expose `cameraError: Error?`; remove `assert(success)` in favor of error handling.
- **Data races**: Synchronize `droppedFrames` (e.g. `NSLock`); ensure `PlaybackManager.currentTime` is only written on main thread from capture output.
- **Bounds**: Guard `selectedFormatIndex` in `didSet` and in `createCaptureSession()` / `createAssetWriter()`.
- **Docs**: See `CameraManager_CODE_REVIEW.md` and `CameraManager_CHANGES.md` if present.

---

## 4. Playback / auto-start behavior (ContentView + PlaybackManager)

- **At 2s buffer**: Seek to buffer start (`earliest`), pause, then reveal player only after seek completes (and optionally after playhead has “settled” for N ticks to avoid wrong first frame).
- **At 5s buffer**: Only call `playPlayer()`; no seek. Gate this on “2s seek completed” (e.g. `hasPausedAtMinDelayForAutoStart`) so playback never starts from wrong position.
- **Re-entrant 2s seek**: Use a flag (e.g. `isSeekingAtMinDelayForAutoStart`) so the timer doesn’t start multiple scrubs; set in scrub completion (and optionally “settle” before setting `hasPausedAtMinDelayForAutoStart`).
- **Placeholder**: Keep `PlayerView` in hierarchy and overlay black until ready (or swap view); avoid still-frame snapshot overlay for auto-start.
- **Snapshot overlay**: We disabled still-frame snapshot; advance always via `advanceToNextItem()` (no snapshot handler for transitions). Restore or keep disabled per product choice.

---

## 5. ContentView structure (braces)

- **Critical**: The `.overlay(...)` that contains the PiP `GeometryReader` must be closed with a `}` before `.background(Color.black)`. Do not remove that `        }` or the compiler will report “Extraneous '}' at top level” and cascade errors.
- **End of file**: Exactly one `}` must close `struct ContentView` (after `func VideoSeekerView` and before `func formatTimeDifference`). Do not add an extra `}` that closes ContentView earlier (e.g. right after the main body).

---

## 6. Debug overlay (optional)

- Auto-start debug overlay: `now`, `earliest`, `playhead`, `bufferedSpan`, `hasPausedAtMinDelayForAutoStart`, `isSeekingAtMinDelayForAutoStart`, `playbackState`, `segmentIndex`, queue count.
- Guard all displayed values (e.g. `play.seconds`, `now.seconds`) with `.isFinite` before formatting or `Int(...)` to avoid NaN/infinite crashes.
- DEBUG button to toggle overlay; tap overlay to hide.

---

## 7. Rate adjustment jitter

- Widen dead zone in `adjustPlaybackSpeedToReachDelayTime()` (e.g. use 1.0 rate when within ±0.2 s of target; only use 0.9/1.1 when farther) to reduce oscillation.

---

## Order of application (when you say go)

1. BufferManager thread-safety and API (and any callers).
2. PlaybackManager changes that depend on BufferManager.
3. CameraManager crash/race/bounds fixes.
4. ContentView auto-start logic and placeholder/snapshot behavior.
5. ContentView brace/structure verification (no extra/missing `}`).
6. Debug overlay and rate-adjustment tweaks as desired.

---

*Prepared for forward update after revert. Do not apply until user confirms.*
