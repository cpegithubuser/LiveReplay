# Known issue: Auto-start shows 3 fingers then jumps back

**Status:** Pre-existing (present in code before PlaybackManager refactor; still present after revert).

**Behavior:** When auto-start runs (2s buffer → seek/pause, 5s buffer → play), the video briefly shows ~3 fingers, then jumps back to ~0–1 fingers and plays forward. Manual scrubbing afterward shows 0–5 fingers correctly.

**Observed:** The **reported** playhead (`getCurrentPlayingTime()`) is correct (0 until 5s, then 5s behind). The **displayed** frame (AVPlayerLayer) does not match—suggests decoder/render lag or wrong frame shown on first reveal.

**Causes we had identified (for forward fix):**
- Re-entrant 2s seek: timer fires every 0.05s so multiple scrubs could start with advancing `now`, last to complete ~3s.
- 5s “play” branch could run before 2s seek completed, so playback started from wrong position.
- Revealing the player (removing placeholder) as soon as seek completed; first drawn frame can be stale (3 fingers) before pipeline catches up.
- Using `now - 2` for seek target when `currentTime` can run ahead of buffer; using `earliest` (buffer start) is safer.

**Planned fixes (when updating forward):**
- Single 2s seek: guard with `isSeekingAtMinDelayForAutoStart` so only one scrub runs.
- Gate 5s “just play” on `hasPausedAtMinDelayForAutoStart` so we never play before 2s seek completes.
- Seek to `earliest` (buffer start) for 2s, not `now - 2`.
- Optional: “Settle” before revealing—only set `hasPausedAtMinDelayForAutoStart` after playhead has stayed at `earliest` for N ticks.
- Optional: Keep `PlayerView` in hierarchy and overlay black until ready (avoid swapping view so layer can render correct frame before reveal).
