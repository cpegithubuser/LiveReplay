# BufferManager: Intent of Multiple AVCompositions and Offsets

## The Problem: Why Not One Big Composition?

If you used a **single** `AVMutableComposition` and kept appending new 1‑second segments to it:

- When the circular buffer wraps (after 45 segments), you’d need to **drop the oldest** segment so the buffer doesn’t grow forever.
- Truncating or removing the start of an `AVComposition` (or swapping to a new one that’s “cut back”) causes **playback glitches**: a visible **flash** or **stutter** when the player crosses that boundary.

So the goal is: **never truncate a composition the player is using**. Instead, use **multiple compositions** and **replace whole compositions** when they go out of range, so the player never sees a mid‑stream “cut.”

---

## The Idea: Several Compositions, Each a Chunk of the Ring

- **Circular buffer:** 45 logical “slots” (indices `0..<45`).  
  `segmentIndex` increases forever; the slot for the current segment is `bufferIndex = segmentIndex % 45`.

- **Offsets:**  
  `offsets = stride(from: 0, to: maxBufferSize, by: compositionSpacing)`  
  With `compositionSpacing = 10` that’s: **0, 10, 20, 30, 40**.

So you have **5 “anchor” indices** in the ring: 0, 10, 20, 30, 40.

- **One composition per anchor:**  
  For each of these 5 indices, the buffer keeps **one** `AVMutableComposition` (and its copy used for playback).  
  So there are **5 compositions**, not 45.

- **Each composition covers a contiguous span of segments:**
  - Composition at **offset 0** holds segments that map to slots **0, 1, 2, …, 9** (the first “decade” of the ring).
  - Composition at **offset 10** holds segments for slots **10..<20**.
  - Similarly for **20..<30**, **30..<40**, and **40..<45** (last one is 5 segments).

So:

- **Offsets** = which slots in the circular buffer are “composition anchors” (0, 10, 20, 30, 40).
- **Multiple compositions** = one composition per anchor, each representing a **fixed chunk** of the ring (about 10 segments, or 5 for the last).

---

## Lifecycle of One Composition (e.g. Offset 0)

1. **Start:** When `segmentIndex` first reaches a slot that equals that offset (e.g. `bufferIndex == 0`), the code **creates a new** `AVMutableComposition` for offset 0 and starts appending segments into it.
2. **Growth:** For each new segment that lands in slots 0–9 (`segmentIndex` 0,1,…,9 then 45,46,…,54, …), the **same** composition at offset 0 gets that segment **appended**.
3. **Wrap / reset:** When the ring wraps and `bufferIndex` is 0 again (e.g. `segmentIndex == 45`), the code **discards** the old composition at offset 0 and **creates a new one**, then keeps appending from there. So the **old** composition (with segments 0–9, 45–54, …) is no longer modified; the **new** one is used for the “current” window of segments at that anchor.
4. **Playback:** The player doesn’t see truncation; it just eventually plays from a **different** composition (the new one for that offset) when the playhead moves into the new chunk. You “throw away” a composition by **no longer using it**, not by editing it in place.

So:

- **Multiple compositions** = avoid editing/truncating a single composition (which causes flashes).
- **Different offsets** = which positions in the ring get their own composition; each of those compositions is a rolling “chunk” that gets **replaced as a whole** when the buffer wraps, instead of being truncated.

---

## How This Maps to the Code

- **`offsets`**  
  The anchor indices: `[0, 10, 20, 30, 40]`.

- **`runningComposition[offset]`**  
  The single “current” mutable composition for that anchor. It’s the one that’s being appended to for the current “cycle” of that part of the ring.

- **“If we've wrapped back to this offset, throw it away and start fresh”**  
  When `bufferIndex == offset`, you’re back at that anchor slot (e.g. segment 45 and slot 0). So you **replace** `runningComposition[offset]` with a new empty composition and start appending again. The old composition is no longer written to; it can be released when nothing holds it.

- **`playerItemBuffer[offset]`**  
  The code updates **only** the slots at `offset` (0, 10, 20, 30, 40). So you have **5** “active” player items, each backed by a composition that covers that anchor’s chunk of the ring.  
  Other indices in `playerItemBuffer` (e.g. 1–9, 11–19) may be unused or legacy; the **seek logic** in `PlaybackManager` uses the composition that **covers** the requested time (via timing + which chunk that time falls into).

- **`compositionSpacing = 10`**  
  Smaller spacing → more anchors → more compositions (e.g. 0, 5, 10, 15, …) → smaller chunks, less “wasted” old data per composition, but more compositions and more work. Larger spacing → fewer compositions, but each one spans more segments and uses more memory until it’s replaced.

---

## Short Summary

- **Intent of multiple AVCompositions:**  
  Avoid truncating one composition (which causes playback flashes). Instead, keep several compositions; when the circular buffer wraps past an anchor, **replace** that anchor’s composition with a new one and stop using the old one.

- **Intent of different offsets:**  
  Offsets (0, 10, 20, 30, 40) are the **anchor indices** in the 45‑slot ring. Each anchor has **one** composition that represents a contiguous chunk of segments (about 10 segments). That composition is reset when the ring wraps back to that anchor, so you get a clean “rolling window” per chunk without in‑place truncation.

So: **multiple compositions** = no truncation glitches; **offsets** = where in the ring each of those compositions is “anchored” and how big each chunk is (via `compositionSpacing`).
