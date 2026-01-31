# BufferManager: Why Copy Compositions, Associated Objects, and playerItemBuffer

## 1. Why Copy Compositions? (Line 100)

### The Problem: Mutable vs Immutable

```swift
runningComposition[offset] = AVMutableComposition()  // MUTABLE - being modified
// ... keep appending segments to it ...

// Then:
if let copiedComposition = self.runningComposition[offset]!.copy() as? AVComposition {
    self.playerItemBuffer[offset] = AVPlayerItem(asset: copiedComposition)
}
```

**Why copy?**

1. **AVPlayerItem requires immutable assets**
   - `AVPlayerItem(asset:)` expects an `AVAsset` (immutable)
   - `AVMutableComposition` is mutable and can't be used directly
   - `copy()` creates an immutable `AVComposition` snapshot

2. **Prevent modification during playback**
   - `runningComposition[offset]` is **continuously being modified** (new segments appended)
   - If you gave the mutable composition directly to the player, modifying it while playing could cause:
     - Crashes
     - Playback glitches
     - Race conditions
   - The copy creates a **snapshot** that won't change

3. **Thread safety**
   - The mutable composition is being modified on one thread
   - The player might be reading from it on another thread
   - Copying creates a safe, immutable snapshot

**Analogy:** It's like taking a photo of a moving object. The photo (copy) is frozen in time, while the object (mutable composition) keeps moving.

---

## 2. Associated Object - Timing Lookup (Line 102)

### The Problem: Local Time vs Global Time

Each `AVComposition` has its own **local timeline** that starts at 0:
- Composition at offset 0: local time 0.0s = first segment
- Composition at offset 10: local time 0.0s = segment 10

But you need to know where each composition fits in the **global buffer timeline**:
- Composition at offset 0: global time 0.0s = first segment
- Composition at offset 10: global time 10.0s = segment 10

### The Solution: Store Global Start Time

```swift
// Line 102: Store the global start time with the AVPlayerItem
objc_setAssociatedObject(
    self.playerItemBuffer[offset], 
    &PlaybackManager.shared.playerItemStartTimeKey, 
    NSValue(time: self.timingBuffer[offset] ?? .zero), 
    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
)
```

**What this does:**
- Attaches the **global start time** to the `AVPlayerItem`
- Uses Objective-C's `objc_setAssociatedObject` to store metadata
- `playerItemStartTimeKey` is a unique key to retrieve it later

### How It's Used (PlaybackManager.swift lines 406-407, 429-430)

```swift
// When player switches to a new item, look up its start time:
if let startTime = objc_getAssociatedObject(item, &playerItemStartTimeKey) as? NSValue {
    currentlyPlayingPlayerItemStartTime = startTime.timeValue  // Store it
}

// Later, convert local time to global time:
func getCurrentPlayingTime() -> CMTime {
    return currentlyPlayingPlayerItemStartTime + playerConstant.currentTime()
    //      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //      Global start time of this item        Local time within the item
}
```

**Why this is needed:**
- When scrubbing, you need to know: "What global time does this local time represent?"
- Example: If composition starts at global time 10.0s, and player is at local time 2.5s, the global time is 12.5s
- Without the associated object, you'd have no way to know where the composition starts in the global timeline

**Analogy:** Like a map - each composition is a "map tile" with local coordinates (0,0) at its top-left. The associated object tells you where that tile's (0,0) is on the "world map" (global timeline).

---

## 3. playerItemBuffer vs runningComposition

### runningComposition[offset]
- **Type:** `AVMutableComposition` (mutable, being modified)
- **Purpose:** The "work in progress" - continuously appending new segments
- **Lifecycle:** 
  - Created when buffer wraps to that offset
  - Grows as segments are added
  - Reset when buffer wraps again
- **Used for:** Building the composition

### playerItemBuffer[offset]
- **Type:** `AVPlayerItem?` (immutable snapshot, ready for playback)
- **Purpose:** The "finished product" - immutable snapshot wrapped in AVPlayerItem
- **Lifecycle:**
  - Created by copying `runningComposition[offset]` each time a segment is added
  - Updated every time a new segment is added (new copy created)
  - Used by AVQueuePlayer for playback
- **Used for:** Playback and scrubbing

### The Relationship

```
runningComposition[0] (mutable, growing)
    ↓ (copy on each segment addition)
playerItemBuffer[0] (immutable snapshot)
    ↓ (used by)
AVQueuePlayer (for playback)
```

**Example Timeline:**

1. **Segment 0 added:**
   - `runningComposition[0]` = [segment 0]
   - Copy → `playerItemBuffer[0]` = AVPlayerItem([segment 0])

2. **Segment 1 added:**
   - `runningComposition[0]` = [segment 0, segment 1] ← modified
   - Copy → `playerItemBuffer[0]` = AVPlayerItem([segment 0, segment 1]) ← new snapshot

3. **Segment 2 added:**
   - `runningComposition[0]` = [segment 0, segment 1, segment 2] ← modified
   - Copy → `playerItemBuffer[0]` = AVPlayerItem([segment 0, segment 1, segment 2]) ← new snapshot

**Key Point:** `playerItemBuffer[offset]` is **replaced** each time, not modified. The old AVPlayerItem is released, and a new one is created with the updated composition.

---

## Why This Architecture?

### The Two-Stage Process

1. **Building Stage** (`runningComposition`):
   - Continuously modified
   - Can't be used by player (mutable)
   - Efficient (no copying overhead during building)

2. **Playback Stage** (`playerItemBuffer`):
   - Immutable snapshot
   - Safe for player to use
   - Created only when needed (when segment added)

### Benefits

- ✅ **Safety:** Player never sees a mutable composition being modified
- ✅ **Performance:** Only copy when needed (when segment added), not continuously
- ✅ **Simplicity:** Clear separation between "building" and "playing"

---

## Summary

1. **Copy compositions:** Because `AVMutableComposition` is mutable and being modified. The player needs an immutable snapshot, so you copy it.

2. **Associated object:** Stores the global start time of each composition so you can convert between local time (within composition) and global time (in buffer timeline).

3. **playerItemBuffer vs runningComposition:** 
   - `runningComposition` = mutable work-in-progress (being built)
   - `playerItemBuffer` = immutable snapshot (ready for playback)
   - They're related: `playerItemBuffer` contains snapshots of `runningComposition` at different points in time
