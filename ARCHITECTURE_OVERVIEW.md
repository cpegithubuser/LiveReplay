# LiveReplay - Architecture Overview

## Purpose
LiveReplay is an iOS app that allows users to view and scrub through video that is still being recorded live on the device. Users can watch a delayed recording and scrub through it as if it were previously recorded, but it's still being captured in real-time.

## Core Architecture

### Main Components

1. **CameraManager** - Handles camera capture and video encoding
2. **BufferManager** - Manages the circular buffer of video segments
3. **PlaybackManager** - Controls AVQueuePlayer and playback logic
4. **ContentView** - Main UI with scrubbing controls and video player

### Data Flow

```
Camera → AVAssetWriter → MP4 Segments → BufferManager → AVQueuePlayer → UI
```

## Key Components Deep Dive

### 1. CameraManager (`CameraManager.swift`)

**Responsibilities:**
- Camera session setup and management
- Video format selection (720p, 1080p, 4K)
- Frame rate selection (30/60/120/240 fps)
- Camera switching (front/back, different lenses)
- Video orientation handling
- Asset writer initialization

**Key Properties:**
- `cameraSession: AVCaptureSession?` - The active capture session
- `assetWriter: AVAssetWriter!` - Writes video segments
- `videoInput: AVAssetWriterInput!` - Video input for writer
- `cameraLocation: CameraPosition` - Front or back camera
- `selectedFormatIndex: Int` - Current video format
- `selectedFrameRate: Double` - Current frame rate

**Important Methods:**
- `initializeCaptureSession()` - Sets up camera with selected format/FPS
- `initializeAssetWriter()` - Creates new AVAssetWriter for segments
- `cancelAssetWriter()` - Cancels current writer

**Segment Writing:**
- Uses `AVAssetWriter` with `.mpeg4AppleHLS` profile
- Segments are ~1 second long (`assetWriterInterval = 1.0`)
- GOP (Group of Pictures) set to ~1 second for better seeking
- No B-frames to avoid reordering issues at segment boundaries

### 2. CameraManager Extensions

#### `CameraManager+CaptureOutput.swift`
- Implements `AVCaptureVideoDataOutputSampleBufferDelegate`
- Receives frames from camera
- Drops first 3 frames (often dark from camera startup)
- Appends frames to `AVAssetWriterInput`
- Updates `PlaybackManager.currentTime` with buffer offset

#### `CameraManager+AssetWriter.swift`
- Implements `AVAssetWriterDelegate`
- Receives completed MP4 segments from writer
- Creates `AVURLAsset` from in-memory MP4 data
- Creates `AVPlayerItem` and adds to `AVQueuePlayer`
- Calls `BufferManager.addNewAsset()` to add to buffer

### 3. BufferManager (`BufferManager.swift`)

**Purpose:** Manages a circular buffer of video segments for scrubbing

**Key Properties:**
- `maxBufferSize = 45` - Total buffer slots
- `compositionSpacing = 10` - Create new AVComposition every 10 segments
- `segmentIndex` - Current segment counter (increments forever)
- `playerItemBuffer: [AVPlayerItem?]` - Circular buffer of player items
- `timingBuffer: [CMTime?]` - Start times for each segment in global timeline
- `nextBufferStartTime: CMTime` - When next segment starts
- `bufferTimeOffset: CMTime` - Offset to convert CACurrentMediaTime to buffer time
- `earliestPlaybackBufferTime: CMTime` - Oldest available segment time

**Why Multiple Compositions:**
- Truncating a single `AVMutableComposition` causes playback flashes
- Solution: Create multiple compositions at intervals
- Each composition spans multiple segments
- Old compositions are discarded when buffer wraps

**Key Methods:**
- `addNewAsset(asset:)` - Adds new segment to buffer
  - Updates timing buffer with start time
  - Adds to all active compositions
  - Updates `earliestPlaybackBufferTime`
- `resetBuffer()` - Clears all buffers and resets state

### 4. PlaybackManager (`PlaybackManager.swift`)

**Purpose:** Manages video playback and scrubbing

**Key Properties:**
- `playerConstant: AVQueuePlayer` - The main player
- `currentTime: CMTime` - Current "now" time in buffer timeline
- `delayTime: CMTime` - Target delay behind live (pinned when scrubbing)
- `maxScrubbingDelay = 30s` - Maximum delay window
- `minScrubbingDelay = 2s` - Minimum delay (can't get closer to live)
- `currentlyPlayingPlayerItemStartTime: CMTime` - Global start time of current item
- `playbackState: PlaybackState` - `.unknown`, `.paused`, or `.playing`

**Key Methods:**
- `scrub(to: CMTime)` - Seeks to absolute time in buffer
  - If time is in current item: seeks within item
  - Otherwise: jumps to different buffer slot
- `scrub(delay: CMTime)` - Seeks by delay (converts to absolute time)
- `rewind10Seconds()` / `forward10Seconds()` - Adjusts delay by ±10s
- `getCurrentPlayingTime() -> CMTime` - Returns absolute time of playhead
- `jump(to: CMTime)` - Finds buffer slot and switches to it

**Playback States:**
- `.unknown` - Just started, waiting for buffer
- `.paused` - User paused
- `.playing` - Actively playing

### 5. ContentView (`ContentView.swift`)

**Main UI Components:**
- `PlayerView` - Displays video with zoom support
- `VideoSeekerView` - Custom scrubber bar
- Playback controls (rewind 10s, play/pause, forward 10s)
- Picture-in-Picture (PiP) live camera preview
- Settings button

**Scrubbing Logic:**
- `leftBound` / `rightBound` - Scrubbable window bounds
- `progress` - Current playhead position (0-1)
- `markerProgress` - Bookmark marker position
- `bookmarkedDelay` - Default delay (5s) shown as marker

**Key Features:**
- Auto-start playback when buffer is ready
- Snapshot overlay during item transitions (prevents flash)
- Delay display ("X.Xs ago" or "LIVE")
- Draggable bookmark marker
- Flip video horizontally
- Grid overlay (commented out)

**Timer:**
- `playbackUpdateTimer` - Updates UI every 0.05s
- Calls `updatePlaybackProgressTick()` and `autoStartPlaybackIfNeeded()`

### 6. Supporting Components

#### `PlayerView.swift`
- Wraps `AVPlayerLayer` in `UIScrollView` for zoom
- Supports horizontal flip transform
- Tagged with `999` for snapshot overlay

#### `PlayerSeeker.swift`
- Smooth seeking implementation (QA1820 pattern)
- Queues seeks to avoid conflicts
- Used by `PlaybackManager` for in-item seeks

#### `InMemoryMP4ResourceLoader.swift`
- Custom `AVAssetResourceLoaderDelegate`
- Serves MP4 data from memory (not disk)
- Uses custom URL scheme: `inmemory-mp4://`
- Prevents disk I/O for segments

#### `SettingsManager.swift`
- Simple settings storage
- Properties: `showPose`, `voiceOn`, `autoShowReplay`, etc.

#### `SettingsView.swift`
- Settings UI
- Camera/lens selection
- Format/FPS pickers
- Various toggles

## Critical Timing System

### Buffer Time Offset
The app maintains a global timeline that maps real-time to buffer time:

1. **First Frame Capture:**
   - When first frame arrives, `bufferTimeOffset` is set
   - `bufferTimeOffset = 0 - CACurrentMediaTime()`
   - This makes the first frame = time 0 in buffer timeline

2. **Current Time Calculation:**
   ```swift
   currentTime = CACurrentMediaTime() + bufferTimeOffset
   ```

3. **Background Handling:**
   - When app backgrounds: pause player, cancel writer
   - When app returns: adjust `bufferTimeOffset` by time away
   - This keeps timeline continuous despite backgrounding

### Segment Timing
- Each segment has a `timingBuffer[index]` entry
- `nextBufferStartTime` tracks where next segment starts
- When segment completes, it's assigned `nextBufferStartTime`
- Then `nextBufferStartTime` is incremented by segment duration

## Key Features

### 1. Live Scrubbing
- User can drag scrubber to any point in buffer
- Scrubber shows:
  - Gray area = available buffer
  - Red area = already played portion
  - White area = scrubbable window (between min/max delay)

### 2. Auto-Start Playback
- When buffer has enough data (≥ bookmark delay), starts playing
- If paused and reaches max delay, auto-resumes

### 3. Snapshot Overlay
- During item transitions, shows snapshot to prevent flash
- Snapshot is removed when new item is ready

### 4. Bookmark Marker
- Draggable marker on scrubber
- "Go to Fixed Delay" button jumps to marker position
- Default is 5 seconds

### 5. Picture-in-Picture
- Small live camera preview overlay
- Draggable around screen
- Can be hidden/shown

## Potential Issues / Areas for Review

### 1. Memory Management
- **45 buffer slots** × **multiple compositions** = potential memory pressure
- Compositions are copied when creating player items
- Consider: Is 45 slots too many? Is composition spacing optimal?

### 2. Background Handling
- Writer is cancelled on background (prevents orphaned files)
- Timeline offset is adjusted on return
- **Potential issue:** If backgrounded for long time, buffer may be stale

### 3. Segment Boundaries
- GOP set to 1 second to match segments
- No B-frames to avoid reordering
- **Potential issue:** Seeking near segment boundaries might still cause issues

### 4. Thread Safety
- `BufferManager.addNewAsset()` uses semaphore lock
- Most operations on main queue
- **Check:** Are there any race conditions?

### 5. Error Handling
- Some `try!` force unwraps in `BufferManager`
- Asset writer errors might not be fully handled
- **Review:** Add proper error handling for production

### 6. Performance
- Snapshot overlay might cause frame drops
- Multiple compositions being updated could be expensive
- **Profile:** Check for performance bottlenecks

### 7. Debugging System
- `PrintBug.swift` provides categorized logging
- Many categories disabled by default
- Enable `BugSettings.isLoggingEnabled = true` to debug

## Code Quality Notes

### Good Practices
- ✅ Singleton pattern for managers
- ✅ Separation of concerns (Camera/Playback/Buffer)
- ✅ Custom resource loader for in-memory playback
- ✅ Smooth seeking implementation

### Areas to Improve
- ⚠️ Some commented-out code (ping-pong, loop features)
- ⚠️ Hardcoded values (maxBufferSize, compositionSpacing)
- ⚠️ Some force unwraps (`try!`, `!`)
- ⚠️ Magic numbers (3 dropped frames, 0.05s timer interval)

## Testing Checklist for First Release

- [ ] Test scrubbing at various delays
- [ ] Test backgrounding/foregrounding
- [ ] Test camera switching
- [ ] Test format/FPS changes
- [ ] Test memory pressure scenarios
- [ ] Test long recording sessions
- [ ] Test seeking near segment boundaries
- [ ] Test with different device orientations
- [ ] Test PiP dragging and hiding
- [ ] Test bookmark marker functionality
- [ ] Test ±10 second buttons
- [ ] Test auto-start playback
- [ ] Verify no memory leaks
- [ ] Test on different iOS devices
- [ ] Test with different camera formats

## Next Steps

1. **Code Review:** Go through each component systematically
2. **Testing:** Run through test checklist
3. **Performance Profiling:** Use Instruments to check memory/CPU
4. **Error Handling:** Add proper error handling
5. **Code Cleanup:** Remove commented code, extract magic numbers
6. **Documentation:** Add inline comments for complex logic
