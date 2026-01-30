//
//  BufferManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 4/20/25.
//
//  PURPOSE:
//  Manages a circular buffer of video segments using multiple AVCompositions to enable
//  backward scrubbing without playback glitches. The buffer stores video segments in memory
//  and creates multiple compositions at different "anchor" points to avoid truncation flashes.
//
//  ARCHITECTURE:
//  - Circular buffer: 45 slots (configurable via maxBufferSize)
//  - Multiple compositions: One per "offset" (every compositionSpacing slots: 0, 10, 20, 30, 40)
//  - Each composition grows continuously until buffer wraps, then resets
//  - Compositions are copied to create immutable snapshots for AVPlayerItem
//
//  THREAD SAFETY:
//  All state mutations happen on a single serial queue (accessQueue) to prevent race conditions.
//  Read-only access can happen from any thread via thread-safe getters.
//
//  MEMORY MANAGEMENT:
//  - MP4 segments stored in memory via InMemoryMP4ResourceLoader
//  - Compositions reference assets (don't duplicate data)
//  - Old compositions released when buffer wraps
//  - Explicit cleanup in resetBuffer() to prevent leaks
//
//  AI NOTES FOR FUTURE MODIFICATIONS:
//  - All state mutations MUST happen on accessQueue - use accessQueue.async/sync
//  - Never access playerItemBuffer, timingBuffer, or runningComposition directly from outside
//  - Use thread-safe getters (accessQueue.sync) for read access from other threads
//  - When adding new state, ensure it's accessed only on accessQueue
//  - Error handling: All AVFoundation operations can fail - handle gracefully
//  - Composition copying is expensive - consider optimizing for long buffers
//  - bufferTimeOffset is accessed from LiveReplayApp.swift - must use thread-safe access
//

import AVKit
import Combine

final class BufferManager: ObservableObject {
    static let shared = BufferManager()
    
    // MARK: - Configuration Constants
    
    /// Total number of slots in the circular buffer.
    /// Each slot represents one video segment (~1 second).
    /// For 30 seconds of scrubbable video: 30 segments
    /// For 5 minutes: 300 segments
    /// For 30 minutes: 1800 segments
    ///
    /// AI NOTE: This should be made configurable based on target buffer duration and available memory.
    /// Consider: maxBufferSize = targetDurationSeconds / segmentDurationSeconds
    let maxBufferSize = 45
    
    /// Spacing between composition "anchor" points in the circular buffer.
    /// Creates compositions at indices: 0, spacing, 2*spacing, 3*spacing, etc.
    /// With spacing=10 and maxBufferSize=45: compositions at 0, 10, 20, 30, 40 (5 total)
    ///
    /// TRADEOFFS:
    /// - Smaller spacing = more compositions = more CPU overhead (more copies per segment)
    /// - Larger spacing = fewer compositions = less CPU overhead but larger seeks within compositions
    ///
    /// AI NOTE: For long buffers (5-30 minutes), consider making this dynamic:
    /// compositionSpacing = max(10, maxBufferSize / targetCompositionCount)
    /// This keeps composition count bounded (e.g., 20-50) regardless of buffer size.
    let compositionSpacing = 10
    
    // MARK: - Buffer State (All accessed only on accessQueue)
    
    /// Composition anchor offsets in the circular buffer.
    /// Example with spacing=10: [0, 10, 20, 30, 40]
    /// These are the indices where we maintain separate AVCompositions.
    ///
    /// AI NOTE: This is computed once in init() and doesn't change. If you make
    /// compositionSpacing dynamic, you'll need to recompute this.
    private let offsets: [Int]
    
    /// Mutable compositions being built for each anchor offset.
    /// Key = offset index (0, 10, 20, 30, 40)
    /// Value = AVMutableComposition that's continuously being appended to
    ///
    /// LIFECYCLE:
    /// - Created when buffer wraps to that offset (bufferIndex == offset)
    /// - Grows as segments are appended
    /// - Reset (replaced) when buffer wraps again
    ///
    /// AI NOTE: Dictionary is efficient here because we only have 5 entries, not 45.
    /// Never iterate over all possible indices - only access by offset keys.
    private var runningComposition: [Int: AVMutableComposition] = [:]
    
    /// Video tracks for each composition (currently unused but kept for potential audio support).
    /// AI NOTE: This is currently unused. Consider removing if audio isn't needed.
    private var runningTrack: [Int: AVMutableCompositionTrack] = [:]
    
    /// Immutable composition snapshots wrapped in AVPlayerItems, ready for playback.
    /// Array of 45 slots, but only slots at offset indices (0, 10, 20, 30, 40) are updated.
    /// Other slots remain nil or hold stale values.
    ///
    /// WHY ARRAY (not dictionary):
    /// - Need to iterate over all 45 slots to find earliest playback time (line 200+)
    /// - Circular buffer logic requires checking all slots in order
    /// - Fixed size matches circular buffer structure
    ///
    /// AI NOTE: Only update playerItemBuffer[offset] for offset in offsets.
    /// Other indices are not used. Consider documenting this more clearly or using
    /// a sparse structure if memory becomes a concern.
    private var playerItemBuffer: [AVPlayerItem?]
    
    /// Global start time for each segment in the buffer timeline.
    /// Index corresponds to buffer slot (0-44).
    /// Used to convert between local composition time and global buffer time.
    ///
    /// AI NOTE: This is updated for ALL segments (all 45 slots), unlike playerItemBuffer
    /// which only updates at offsets. This is needed for finding earliest playback time.
    private var timingBuffer: [CMTime?]
    
    /// Current segment index (increments forever, wraps via modulo).
    /// Used to calculate which buffer slot the current segment occupies.
    /// bufferIndex = segmentIndex % maxBufferSize
    ///
    /// AI NOTE: Private storage - use public computed property `segmentIndex` for thread-safe access.
    private var _segmentIndex = 0
    
    /// The global start time for the next segment to be added.
    /// Updated each time a segment is added: nextBufferStartTime += segment.duration
    /// Stored in timingBuffer[bufferIndex] when segment is added.
    ///
    /// AI NOTE: Private storage - use public computed property `nextBufferStartTime` for thread-safe access.
    private var _nextBufferStartTime: CMTime = .zero
    
    /// Offset to convert CACurrentMediaTime() to buffer timeline.
    /// Calculated as: nextBufferStartTime - CACurrentMediaTime()
    /// Used to map "now" (real time) to "now" (buffer time).
    ///
    /// AI NOTE: This is accessed from LiveReplayApp.swift without locking (line 40).
    /// Must use thread-safe access: bufferTimeOffset (getter) or accessQueue.sync
    private var _bufferTimeOffset: CMTime = .zero
    
    /// The earliest time in the buffer that's available for playback.
    /// Calculated by finding the oldest non-nil playerItemBuffer entry.
    /// Used to determine scrubbing window bounds.
    ///
    /// AI NOTE: Private storage - use public computed property `earliestPlaybackBufferTime` for thread-safe access.
    private var _earliestPlaybackBufferTime: CMTime = .zero
    
    // MARK: - Thread Safety
    
    /// Serial queue for all state mutations.
    /// All modifications to buffer state MUST happen on this queue.
    /// Read access from other threads should use thread-safe getters or accessQueue.sync.
    ///
    /// AI NOTE: Using serial queue instead of semaphore provides:
    /// - Clearer ownership model
    /// - Better debugging (can see queue in stack traces)
    /// - Prevents deadlocks from nested locks
    /// - Easier to reason about execution order
    private let accessQueue = DispatchQueue(
        label: "com.livereplay.buffer.access",
        qos: .userInitiated
    )
    
    // MARK: - Initialization
    
    init() {
        // Initialize arrays with nil values
        playerItemBuffer = Array(repeating: nil, count: maxBufferSize)
        timingBuffer = Array(repeating: nil, count: maxBufferSize)
        
        // Compute composition anchor offsets
        // stride(from: 0, to: 45, by: 10) = [0, 10, 20, 30, 40]
        offsets = Array(stride(from: 0, to: maxBufferSize, by: compositionSpacing))
        
        print("BufferManager initialized: maxBufferSize=\(maxBufferSize), compositionSpacing=\(compositionSpacing), offsets=\(offsets)")
    }
    
    // MARK: - Thread-Safe Getters
    
    /// Thread-safe access to bufferTimeOffset.
    /// Used by LiveReplayApp.swift to adjust timeline after backgrounding.
    ///
    /// AI NOTE: This is a computed property that reads from accessQueue.
    /// To modify, use the setter below or accessQueue.async directly.
    var bufferTimeOffset: CMTime {
        return accessQueue.sync { _bufferTimeOffset }
    }
    
    /// Thread-safe setter for bufferTimeOffset.
    /// Used by LiveReplayApp.swift to adjust timeline after backgrounding.
    ///
    /// AI NOTE: This must be used instead of direct assignment to ensure thread safety.
    /// All modifications to bufferTimeOffset must go through this setter or accessQueue.
    func setBufferTimeOffset(_ newValue: CMTime) {
        accessQueue.async { [weak self] in
            self?._bufferTimeOffset = newValue
        }
    }
    
    /// Thread-safe method to adjust bufferTimeOffset by a delta.
    /// Used by LiveReplayApp.swift to shift timeline after backgrounding.
    ///
    /// AI NOTE: This is more convenient than get + add + set for common use case.
    func adjustBufferTimeOffset(by delta: CMTime) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self._bufferTimeOffset = CMTimeAdd(self._bufferTimeOffset, delta)
        }
    }
    
    /// Thread-safe access to earliestPlaybackBufferTime.
    /// Used by PlaybackManager and ContentView to determine scrubbing bounds.
    var earliestPlaybackBufferTime: CMTime {
        return accessQueue.sync { _earliestPlaybackBufferTime }
    }
    
    /// Thread-safe access to segmentIndex.
    /// Used by PlaybackManager.jump() to find buffer slots.
    var segmentIndex: Int {
        return accessQueue.sync { _segmentIndex }
    }
    
    /// Thread-safe access to nextBufferStartTime.
    /// Used by CameraManager+AssetWriter.swift to set timing on playerItems before they're added to buffer.
    ///
    /// AI NOTE: This is accessed before addNewAsset() is called, so it represents the start time
    /// that will be assigned to the next segment when it's added to the buffer.
    var nextBufferStartTime: CMTime {
        return accessQueue.sync { _nextBufferStartTime }
    }
    
    // Note: maxBufferSize is a constant (let), so no computed property needed.
    // Access it directly: bufferManager.maxBufferSize
    
    /// Thread-safe access to playerItemBuffer at a specific index.
    /// Used by PlaybackManager.jump() to find the right composition for scrubbing.
    ///
    /// AI NOTE: Returns a copy of the AVPlayerItem reference. The item itself is immutable
    /// (backed by an immutable AVComposition), so this is safe.
    func getPlayerItem(at index: Int) -> AVPlayerItem? {
        return accessQueue.sync {
            guard index >= 0 && index < playerItemBuffer.count else { return nil }
            return playerItemBuffer[index]
        }
    }
    
    /// Thread-safe access to timingBuffer at a specific index.
    /// Used by PlaybackManager.jump() to convert global time to local composition time.
    func getTiming(at index: Int) -> CMTime? {
        return accessQueue.sync {
            guard index >= 0 && index < timingBuffer.count else { return nil }
            return timingBuffer[index]
        }
    }
    
    /// Thread-safe access to both playerItem and timing at a specific index.
    /// Used by PlaybackManager.jump() to find the right buffer slot for scrubbing.
    ///
    /// Returns a tuple with both values, or nil if index is invalid or item doesn't exist.
    /// This is more efficient than calling getPlayerItem() and getTiming() separately.
    func getPlayerItemAndTiming(at index: Int) -> (item: AVPlayerItem, timing: CMTime)? {
        return accessQueue.sync {
            guard index >= 0 && index < playerItemBuffer.count,
                  let item = playerItemBuffer[index],
                  let timing = timingBuffer[index] else {
                return nil
            }
            return (item, timing)
        }
    }
    
    /// Thread-safe snapshot of buffer state for iteration.
    /// Returns copies of arrays that can be safely iterated outside accessQueue.
    ///
    /// AI NOTE: This creates copies, so it's more expensive than direct access.
    /// Use this when you need to iterate over the entire buffer from another thread.
    /// For single-item access, use getPlayerItemAndTiming() instead.
    func getBufferSnapshot() -> (segmentIndex: Int, maxBufferSize: Int) {
        return accessQueue.sync {
            return (segmentIndex: _segmentIndex, maxBufferSize: maxBufferSize)
        }
    }
    
    // MARK: - Public Methods
    
    /// Adds a new video segment asset to the buffer.
    ///
    /// This is the main entry point for adding segments. It:
    /// 1. Updates timing information for the current buffer slot
    /// 2. Appends the asset to all active compositions (at offset anchors)
    /// 3. Creates immutable snapshots (copies) for playback
    /// 4. Updates earliestPlaybackBufferTime
    ///
    /// THREAD SAFETY: All state mutations happen on accessQueue.
    ///
    /// - Parameter asset: The AVAsset (MP4 segment) to add. Must have at least one video track.
    /// - Important: This method can be called from any thread. All work happens on accessQueue.
    ///
    /// AI NOTES FOR FUTURE MODIFICATIONS:
    /// - If you need to add audio support, uncomment the audioTrack code and handle errors
    /// - Composition copying (line 250+) is expensive - consider optimizing for long buffers
    /// - Error handling: Currently logs errors and continues. Consider propagating errors or
    ///   using a completion handler for critical failures.
    /// - If asset validation fails, the segment is skipped. This might cause gaps in playback.
    ///   Consider whether this is acceptable or if you need to handle it differently.
    func addNewAsset(asset: AVAsset) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self._addNewAssetSync(asset: asset)
        }
    }
    
    /// Resets the entire buffer, clearing all compositions and player items.
    ///
    /// THREAD SAFETY: All state mutations happen on accessQueue.
    /// Also resets the AVQueuePlayer on the main thread.
    ///
    /// AI NOTES FOR FUTURE MODIFICATIONS:
    /// - This is called when camera switches, format changes, or app resets
    /// - Consider adding a completion handler if callers need to know when reset is complete
    /// - The PlaybackManager reset happens on main thread - ensure this is still appropriate
    ///   if you change the architecture
    func resetBuffer() {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self._resetBufferSync()
        }
    }
    
    // MARK: - Private Implementation (Runs on accessQueue)
    
    /// Internal implementation of addNewAsset. Must be called on accessQueue.
    ///
    /// AI NOTE: This is separated from the public method to allow synchronous execution
    /// within accessQueue (avoiding nested async calls).
    private func _addNewAssetSync(asset: AVAsset) {
        // Calculate which buffer slot this segment occupies
        let bufferIndex = _segmentIndex % maxBufferSize
        
        // Store the global start time for this segment
        // This will be used later to convert local composition time to global buffer time
        timingBuffer[bufferIndex] = _nextBufferStartTime
        
        // Update nextBufferStartTime for the next segment
        // This creates a continuous timeline: each segment starts where the previous ended
        let assetDuration = asset.duration
        guard CMTimeCompare(assetDuration, .zero) > 0 else {
            print("⚠️ [BufferManager] Asset has zero or invalid duration, skipping")
            return
        }
        
        _nextBufferStartTime = CMTimeAdd(_nextBufferStartTime, assetDuration)
        
        // Update bufferTimeOffset: maps real-time to buffer-time
        // Formula: bufferTime = CACurrentMediaTime() + bufferTimeOffset
        // This allows us to know "where we are" in the buffer timeline
        let currentRealTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        _bufferTimeOffset = CMTimeSubtract(_nextBufferStartTime, currentRealTime)
        
        // Add this asset to all active compositions (at offset anchors)
        // Each composition represents a "chunk" of the buffer for scrubbing
        for offset in offsets {
            // Only add to compositions that have "started" (_segmentIndex >= offset)
            // For example, composition at offset 10 only starts receiving segments when _segmentIndex >= 10
            guard _segmentIndex >= offset else { continue }
            
            // Check if we need to reset this composition (buffer wrapped back to this anchor)
            if bufferIndex == offset {
                // Buffer has wrapped - reset this composition and start fresh
                // This prevents compositions from growing forever
                // The old composition will be released when nothing references it
                _resetComposition(at: offset)
            }
            
            // Append the new asset to this composition
            // This modifies the mutable composition in place
            do {
                try _appendAssetToComposition(asset: asset, at: offset)
            } catch {
                print("❌ [BufferManager] Failed to append asset to composition at offset \(offset): \(error)")
                // Continue with other compositions even if one fails
                continue
            }
            
            // Create an immutable snapshot for playback
            // This copy is safe for AVPlayerItem (immutable, won't change during playback)
            do {
                try _updatePlayerItemBuffer(at: offset)
            } catch {
                print("❌ [BufferManager] Failed to update playerItemBuffer at offset \(offset): \(error)")
                // Continue with other compositions even if one fails
                continue
            }
        }
        
        // Increment segment index (this happens after all compositions are updated)
        _segmentIndex += 1
        
        // Update earliestPlaybackBufferTime: find the oldest segment still in buffer
        // This is used to determine the scrubbing window bounds
        _updateEarliestPlaybackBufferTime()
    }
    
    /// Resets a single composition at the given offset.
    /// Creates a new empty AVMutableComposition and track.
    ///
    /// AI NOTE: The old composition is released when nothing references it.
    /// If AVPlayerItems are still holding references, the old composition (and its assets)
    /// won't be released until those items are released. Consider explicitly releasing
    /// playerItemBuffer[offset] before resetting if memory is tight.
    private func _resetComposition(at offset: Int) {
        // Release old playerItem before creating new composition
        // This helps ensure old composition can be released promptly
        playerItemBuffer[offset] = nil
        
        // Create new empty composition
        let newComposition = AVMutableComposition()
        
        // Add a video track to the composition
        // We use kCMPersistentTrackID_Invalid to let AVFoundation assign an ID
        guard let videoTrack = newComposition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("❌ [BufferManager] Failed to create video track for composition at offset \(offset)")
            return
        }
        
        runningComposition[offset] = newComposition
        runningTrack[offset] = videoTrack
        
        print("🔄 [BufferManager] Reset composition at offset \(offset)")
    }
    
    /// Appends an asset to the composition at the given offset.
    ///
    /// AI NOTE: This modifies the mutable composition in place. The composition will be
    /// copied later to create an immutable snapshot for playback.
    ///
    /// - Throws: Error if composition doesn't exist, asset has no video track, or insertion fails
    private func _appendAssetToComposition(asset: AVAsset, at offset: Int) throws {
        // Get the composition (should exist if we got here)
        guard let composition = runningComposition[offset] else {
            throw BufferError.compositionNotFound(offset: offset)
        }
        
        // Get the video track from the composition
        guard let videoTrack = composition.tracks(withMediaType: .video).first else {
            throw BufferError.noVideoTrack(offset: offset)
        }
        
        // Get the video track from the asset
        guard let assetVideoTrack = asset.tracks(withMediaType: .video).first else {
            throw BufferError.assetHasNoVideoTrack
        }
        
        // Calculate where to insert: at the end of the current composition
        let insertionTime = composition.duration
        
        // Insert the entire asset (full time range)
        let fullRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        // Insert the time range into the composition track
        // This adds the asset's video to the composition
        do {
            try videoTrack.insertTimeRange(fullRange, of: assetVideoTrack, at: insertionTime)
        } catch {
            throw BufferError.insertionFailed(offset: offset, error: error)
        }
        
        // AI NOTE: Audio support would go here:
        // if let audioTrack = composition.tracks(withMediaType: .audio).first,
        //    let assetAudioTrack = asset.tracks(withMediaType: .audio).first {
        //     try audioTrack.insertTimeRange(fullRange, of: assetAudioTrack, at: insertionTime)
        // }
    }
    
    /// Creates an immutable snapshot of the composition and stores it in playerItemBuffer.
    ///
    /// This is called every time a segment is added. The copy creates an immutable snapshot
    /// that's safe for AVPlayerItem (won't change while player is using it).
    ///
    /// AI NOTE: This copying is expensive, especially with many compositions. For long buffers,
    /// consider optimizing by:
    /// - Only copying when composition actually changes significantly
    /// - Copying on-demand when scrubbing (lazy evaluation)
    /// - Using a more efficient snapshot mechanism
    ///
    /// - Throws: Error if composition doesn't exist, copy fails, or associated object setup fails
    private func _updatePlayerItemBuffer(at offset: Int) throws {
        // Get the composition (should exist if we got here)
        guard let composition = runningComposition[offset] else {
            throw BufferError.compositionNotFound(offset: offset)
        }
        
        // Copy the mutable composition to create an immutable snapshot
        // This is necessary because:
        // 1. AVPlayerItem requires an immutable AVAsset
        // 2. The mutable composition is still being modified (new segments added)
        // 3. We need a frozen snapshot that won't change during playback
        guard let copiedComposition = composition.copy() as? AVComposition else {
            throw BufferError.copyFailed(offset: offset)
        }
        
        // Create an AVPlayerItem from the immutable composition
        let playerItem = AVPlayerItem(asset: copiedComposition)
        
        // Store the global start time for this composition
        // This allows us to convert between local composition time and global buffer time
        // Example: If composition starts at global time 10.0s, and player is at local time 2.5s,
        //          the global time is 12.5s
        let startTime = timingBuffer[offset] ?? .zero
        objc_setAssociatedObject(
            playerItem,
            &PlaybackManager.shared.playerItemStartTimeKey,
            NSValue(time: startTime),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        
        // Replace the old playerItem with the new one
        // The old one will be released when nothing references it
        // This happens every time a segment is added, so we're constantly updating the snapshot
        playerItemBuffer[offset] = playerItem
        
        printBug(.bugPlayerItemObserver, "✅ [BufferManager] Updated playerItemBuffer[\(offset)] with start time \(startTime.seconds)s")
    }
    
    /// Updates earliestPlaybackBufferTime by finding the oldest segment still in buffer.
    ///
    /// This iterates through all buffer slots (circularly) to find the first non-nil playerItem.
    /// The timingBuffer entry for that slot gives us the global start time.
    ///
    /// AI NOTE: This is why playerItemBuffer is an array (not dictionary) - we need to iterate
    /// over all slots. However, only slots at offsets have non-nil values. Consider optimizing
    /// by tracking this incrementally instead of searching every time.
    private func _updateEarliestPlaybackBufferTime() {
        // Start searching from the oldest slot (_segmentIndex + 1)
        // _segmentIndex was just incremented, so _segmentIndex + 1 is the oldest slot
        // We search circularly through all slots to find the first non-nil entry
        for i in 0..<maxBufferSize {
            let bufferIndex = (_segmentIndex + 1 + i) % maxBufferSize
            
            // Found the oldest segment still in buffer
            if playerItemBuffer[bufferIndex] != nil {
                _earliestPlaybackBufferTime = timingBuffer[bufferIndex] ?? .zero
                return
            }
        }
        
        // If we get here, buffer is empty (shouldn't happen in normal operation)
        _earliestPlaybackBufferTime = .zero
    }
    
    /// Internal implementation of resetBuffer. Must be called on accessQueue.
    ///
    /// AI NOTE: This is separated from the public method to allow synchronous execution
    /// within accessQueue (avoiding nested async calls).
    private func _resetBufferSync() {
        print("🔄 [BufferManager] Resetting buffer")
        
        // Reset all compositions at anchor offsets
        // Create new empty compositions for each offset
        for offset in offsets {
            _resetComposition(at: offset)
        }
        
        // Clear all buffer slots
        for i in 0..<maxBufferSize {
            playerItemBuffer[i] = nil
            timingBuffer[i] = nil
        }
        
        // Reset segment index and timing
        _segmentIndex = 0
        _nextBufferStartTime = .zero
        _bufferTimeOffset = .zero
        _earliestPlaybackBufferTime = .zero
        
        // Reset AVQueuePlayer on main thread (UI operations must be on main)
        DispatchQueue.main.async {
            let pm = PlaybackManager.shared
            pm.playerConstant.pause()
            pm.playerConstant.removeAllItems()
            pm.playbackState = .unknown
            pm.delayTime = .zero  // Clear pinned delay so UI doesn't show stale value
        }
        
        print("✅ [BufferManager] Buffer reset complete")
    }
}

// MARK: - Error Types

/// Errors that can occur during buffer operations.
///
/// AI NOTE: Consider adding more specific error types or error codes if you need
/// more granular error handling in the future.
enum BufferError: Error, LocalizedError {
    case compositionNotFound(offset: Int)
    case noVideoTrack(offset: Int)
    case assetHasNoVideoTrack
    case insertionFailed(offset: Int, error: Error)
    case copyFailed(offset: Int)
    
    var errorDescription: String? {
        switch self {
        case .compositionNotFound(let offset):
            return "Composition not found at offset \(offset)"
        case .noVideoTrack(let offset):
            return "Composition at offset \(offset) has no video track"
        case .assetHasNoVideoTrack:
            return "Asset has no video track"
        case .insertionFailed(let offset, let error):
            return "Failed to insert asset into composition at offset \(offset): \(error.localizedDescription)"
        case .copyFailed(let offset):
            return "Failed to copy composition at offset \(offset)"
        }
    }
}
