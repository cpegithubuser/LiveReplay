# Live Replay: Forward/Backward 10 Seconds and “Chase Delay”

This doc explains the time model for live replay, why ±10 seconds is tricky, how the current code handles it (x vs non-x), and how the “chase delay” (speed up/slow down to hit an exact delay) fits in.

**Implemented (this session):**
- **rewind10Seconds() / forward10Seconds():** All "now" and delay math runs on main; then we dispatch to a background queue only for pause → scrub(to: targetAbs, allowSeekOnly: true) → play. Scrubbing flow (in-item smoothlySeek or jump) is unchanged.
- **Removed rewind10Secondsx() / forward10Secondsx()** (unused, target-time–based).
- **currentPlayingAsset:** Set in playerItemDidChange(to:) from newItem?.asset so the property is meaningful.
- **Commented-out code:** Removed large blocks (playbackEffectTimer, wasPlayingBefore, resumeNormalPlayback, itemPlayerUntilEndObserver in init).
- **startLoop():** Wrapped in DispatchQueue.main.async so AVPlayer calls run on main.
- **deinit:** Removed no-op removeObserver (PlaybackManager doesn't add orientation observer); left comment.
- **Chase delay:** ContentView timer now calls adjustPlaybackSpeedToReachDelayTime() when !isScrubbing && delayTime != .zero so we don't chase while the user is scrubbing (smooth experience preserved).

---

## 0. Delay meaning and auto-start (design)

**Delay = how far behind live we are.**  
“X seconds ago” / “−X seconds” = we show the frame that was captured X seconds before “now” (live). So:

- **2 seconds ago** (2s delay) = we show the frame at buffer time **(now − 2s)** = start of the 2s buffer.
- **5 seconds ago** (5s delay) = we show the frame at buffer time **(now − 5s)**.

We **cannot scrub from 0–2s** by design (min delay = 2s). When the knob is at 2s we see a **paused** frame from 2 seconds ago (oldest frame in the buffer). As the knob moves toward 5s the video stays still — we’re still showing that same “2 seconds ago” frame; as “now” advances we’re effectively 2s, then 3s, then 4s, then 5s ago. At 5s we **auto-play**: no seek, just play from where we are (start of buffer). We stay “at 5 seconds ago” while the video plays forward (delay remains 5s).

**Auto-start flow:**  
0–2s: blank (no 0–2s scrub). At 2s: seek to (now − 2s), pause, show player. 2s–5s: still paused at that frame. At 5s: set delayTime = 5s, play (no seek). Video plays 0 → 1 → 2 → 3 → 4 → 5 smoothly; we remain at 5s delay.

---

## 1. The core issue: time keeps moving

In **pre-recorded** video:

- Timeline is fixed. “Go back 10 seconds” = playhead − 10s. “Now” doesn’t move.
- Seek is to an absolute position; no ambiguity.

In **live replay**:

- **“Now” (currentTime)** is the live edge of the buffer. It advances continuously as new segments are written.
- **Playhead (getCurrentPlayingTime())** is where we’re watching. It also moves when playing.
- So there is **no fixed timeline**: both “now” and “playhead” are moving. “Go back 10 seconds” has to be defined in terms of what we care about: **delay behind live**.

User mental model: *“I want to be X seconds behind live.”* So the right concept is **delay**, not “absolute time minus 10 seconds” in isolation.

---

## 2. Imprecision

- **currentTime** is updated from the camera/writer pipeline (writerQueue → main). There’s a small, variable latency: a frame is written, then we compute “now” and publish. So “now” is always a bit behind real time and can jitter.
- **getCurrentPlayingTime()** is from AVPlayer; it’s sample-accurate for what’s playing but “now” isn’t. So **measured delay** = currentTime − getCurrentPlayingTime() is slightly fuzzy.
- When we **seek**, we ask for “buffer time T”. By the time the seek completes, “now” has moved. So we rarely land at an exactly round delay (e.g. exactly 15.0s). We might land at 14.8s or 15.2s.

So: **we can’t guarantee exact delay from a single seek.** We can either accept a small error or “chase” the target delay by adjusting playback rate.

---

## 3. Two approaches in the code: “x” vs non-x

### 3.1 “x” versions: **target time** then derive delay

- **rewind10Secondsx / forward10Secondsx**
- Idea: compute a **target playhead time** (e.g. playhead − 10s for rewind), clamp it to the buffer, then **scrub(to: targetTime)**. After that, set `delayTime` from the resulting delay (currentTime − playhead).
- So: “move playhead by 10 seconds (in buffer time), then pin delay to whatever we got.”

**Issue:** “Now” and “playhead” are both moving. If we compute targetTime from “current playhead − 10s” and then async scrub, by the time we scrub “now” has moved, so the **resulting delay** isn’t necessarily “previous delay + 10”. It’s “whatever delay we land at.” So the user’s “I want 10 more seconds of delay” is only approximately satisfied, and the pinned delay is “what we got” not “what we asked for.”

### 3.2 Non-x versions: **target delay** then seek

- **rewind10Seconds() / forward10Seconds()**
- Idea: treat **delay** as the thing we control. We have a **pinned target delay** (`delayTime`). Rewind = “I want 10 more seconds of delay” → requestedDelay = currentDelay + 10. Forward = requestedDelay − 10. Clamp to [minD, upperSec] (respecting buffer). Then:
  - Set **delayTime** = clamped delay (this is what the UI shows and what “chase” would target).
  - Compute **targetAbs = now − delayTime** (absolute buffer time that corresponds to that delay).
  - **scrub(to: targetAbs, allowSeekOnly: true)** so we seek to the position that *should* give that delay.

**Why this is better:** We define the user action in **delay space** (“10 more seconds behind live” / “10 seconds closer to live”). We pin the desired delay first, then seek to the place that achieves it. So:
- UI and chase logic have a single number to target: **delayTime**.
- We still don’t land exactly (because “now” moves and there’s jitter), but we’re “close”; optional rate adjustment can then chase the exact delay.

---

## 4. Chase delay: speed up / slow down to hit exact delay

The idea:

- After a seek (or during normal playback), **actual delay** = currentTime − getCurrentPlayingTime() might be 14.8s while **delayTime** (target) is 15.0s.
- We can **adjust playback rate** so that actual delay drifts toward delayTime:
  - **Actual delay > target** (we’re too far behind) → play **faster** (e.g. 1.1x, 2.0x) to catch up.
  - **Actual delay < target** (we’re too close to live) → play **slower** (e.g. 0.9x, 0.5x) to fall back.
  - When we’re within a small band (e.g. ±0.01s), set rate back to 1.0.

Where it lives:

- **ContentView:** `adjustPlaybackSpeedToReachDelayTime()` implements this (compare `delayTime` vs current delay; set rate to 2.0 / 0.5 / 1.1 / 0.9 / 1.0 with thresholds).
- It’s **currently disabled**: the only call site is commented out (“no adjust yet”).

So: the **design** is “seek to approximate delay, then optionally chase with rate”; the chase part is implemented but not active.

---

## 5. Recommended model (single, clear approach)

### 5.1 Concept

- **User-facing quantity:** **Delay behind live** (seconds). UI and ±10s buttons operate on this.
- **Internal:** We maintain a **pinned target delay** `delayTime`. “Rewind 10s” = increase target delay by 10 (clamped); “Forward 10s” = decrease by 10 (clamped).
- **Seek:** When we need to move the playhead:
  1. Capture **now** and **buffer bounds** once (on main, so currentTime/delayTime are consistent).
  2. **targetAbs = now − delayTime** (the buffer time that corresponds to that delay).
  3. **scrub(to: targetAbs, allowSeekOnly: true)** so we seek to that position. Accept that we’ll land “close” but not exact.
- **Optional chase:** A timer or display-link callback:
  - Measure actual delay = currentTime − getCurrentPlayingTime().
  - If |actual − delayTime| &gt; small threshold, nudge rate (e.g. 1.1x / 0.9x or 2.0x / 0.5x for bigger error) so actual delay drifts toward delayTime; when within band, set rate = 1.0.

This matches what the **non-x** rewind/forward already do (delay-based, pin delay, seek to now − delay). The x versions (target-time first, then set delay from result) are redundant and more confusing; they can be removed.

### 5.2 Practical details

- **Capture “now” once:** Do all of “read currentTime, getCurrentPlayingTime(), earliestPlaybackBufferTime, compute targetAbs” on the **main thread** (or a single serial queue) so you’re not mixing with the writer updating currentTime. Then you can dispatch the actual scrub to a queue if needed, passing the already-computed targetAbs.
- **Thresholds for chase:** Use something like ±0.05s for “close enough” to avoid jitter (rate flipping 1.0 ↔ 1.1). The existing `epsTiny = 0.05`, `epsBig = 0.5` in `adjustPlaybackSpeedToReachDelayTime()` are in that spirit.
- **When to chase:** Only when playing (rate ≠ 0) and when delayTime is set. Paused or “live” (no pinned delay) → no rate adjustment.

### 5.3 Summary

| Aspect | Recommendation |
|--------|----------------|
| **User action** | “Rewind/forward 10 seconds” = change **target delay** by ±10s (clamped). |
| **Storage** | **delayTime** = pinned target delay (what UI shows; what chase targets). |
| **Seek** | targetAbs = now − delayTime; scrub(to: targetAbs). Use one consistent “now” (main thread). |
| **Imprecision** | Accept small error from seek; optionally **chase** with playback rate (already implemented in ContentView, currently off). |
| **x vs non-x** | Use **non-x** (delay-based) only; remove or deprecate x versions. |

So: yes, the issue is that time keeps moving and there’s imprecision; the best way is to treat **delay** as the single source of truth, seek to (now − delay), and optionally use the existing “chase delay” logic (rate adjustment) to get to the best version of the exact delay. The current non-x rewind/forward already follow that model; the chase is the missing piece if you want it to feel exact.
