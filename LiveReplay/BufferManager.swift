//
//  BufferManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 4/20/25.
//

import AVKit
import Combine

final class BufferManager: ObservableObject {
    static let shared = BufferManager()
    
    //var runningComposition = AVMutableComposition()
    //var runningTrack: AVMutableCompositionTrack
    
    /// Total number of slots in the buffer
    let maxBufferSize = 45
    
    /// Create AVCompositions every this many buffers. We don't just have one running AVComposition because truncating it causes a flash in playback. So we create multiple running compositions, throwing away oldest ones. Not 100% sure how to optimize. The smaller the spacing, the more the compositions and the less extra space we use for buffers.
    let compositionSpacing = 10
    
    /// These are the offsets in buffer for each AVComposition. Values set in init()
    var offsets: StrideTo<Int>
    
    /// The running composition and track for each of the offsets
    var runningComposition: [Int: AVMutableComposition] = [:]
    var runningTrack: [Int: AVMutableCompositionTrack] = [:]
    
    var playerItemBuffer: [AVPlayerItem?]
    var timingBuffer:     [CMTime?]
    
    var segmentIndex = 0

    init() {
        playerItemBuffer = Array(repeating: nil, count: maxBufferSize)
        timingBuffer     = Array(repeating: nil, count: maxBufferSize)
        
        offsets = stride(from: 0, to: maxBufferSize, by: compositionSpacing)
//        resetBuffer()
    }

    /// The next asset to be added's start time. Save for next.
    var nextBufferStartTime: CMTime = .zero
    /// The time to add to current time to get to relative buffer time
    var bufferTimeOffset: CMTime = .zero
    var earliestPlaybackBufferTime: CMTime = .zero
    
    private let compositionQueue = DispatchQueue(
        label: "com.myapp.buffer.compositionQueue",
        qos: .userInitiated
 //       qos: .utility
    )
    
    func addNewAsset(asset: AVAsset) {
        compositionQueue.async { [weak self] in
            guard let self = self else { return }

            /// Current buffer index
            let bufferIndex = self.segmentIndex % self.maxBufferSize

            /// Add start time, calculated from last cycle
            self.timingBuffer[bufferIndex] = self.nextBufferStartTime

            /// Add new asset's duration for next
            self.nextBufferStartTime = CMTimeAdd(self.nextBufferStartTime, asset.duration)

            /// Update bufferTimeOffset so PlaybackManager.currentTime stays aligned to content time
            self.bufferTimeOffset = CMTimeSubtract(
                self.nextBufferStartTime,
                CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
            )

            /// Loop through all offsets and append the new asset to each running composition
            for offset in self.offsets {
                guard self.segmentIndex >= offset else { continue }

                // If we've wrapped back to this offset, throw it away and start fresh
                if bufferIndex == offset {
                    let newComp = AVMutableComposition()
                    let newTrack = newComp.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                    self.runningComposition[offset] = newComp
                    if let newTrack {
                        self.runningTrack[offset] = newTrack
                    } else {
                        self.runningTrack[offset] = nil
                    }
                }

                // Append the new asset to that composition (safely)
                guard let comp = self.runningComposition[offset] else {
                    print("⚠️ Missing runningComposition for offset \(offset)")
                    continue
                }

                // Ensure we have a destination track
                let destTrack: AVMutableCompositionTrack
                if let existing = self.runningTrack[offset] {
                    destTrack = existing
                } else if let created = comp.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    self.runningTrack[offset] = created
                    destTrack = created
                } else {
                    print("⚠️ Could not create destination track for offset \(offset)")
                    continue
                }

                // Ensure the incoming asset has a video track
                guard let srcTrack = asset.tracks(withMediaType: .video).first else {
                    print("⚠️ Incoming asset has no video track; skipping append")
                    continue
                }

                // Skip obviously-invalid durations
                let dur = asset.duration
                guard dur.isNumeric, dur > .zero else {
                    print("⚠️ Incoming asset has invalid duration \(dur); skipping append")
                    continue
                }

                let insertionTime = comp.duration
                let fullRange = CMTimeRange(start: .zero, duration: dur)

                do {
                    try destTrack.insertTimeRange(fullRange, of: srcTrack, at: insertionTime)
                } catch {
                    print("⚠️ insertTimeRange failed at offset \(offset): \(error)")
                    continue
                }

                if let copiedComposition = comp.copy() as? AVComposition {
                    self.playerItemBuffer[offset] = AVPlayerItem(asset: copiedComposition)
                    if let item = self.playerItemBuffer[offset] {
                        objc_setAssociatedObject(
                            item,
                            &PlaybackManager.shared.playerItemStartTimeKey,
                            NSValue(time: self.timingBuffer[offset] ?? .zero),
                            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                        )
                    }

                    if doBug(.bugPlayerItemObserver), let item = self.playerItemBuffer[offset] {
                        let ptr = Unmanaged.passUnretained(item).toOpaque()
                        printBug(.bugPlayerItemObserver, "🤖 setting assoc on composition item @ \(ptr) start: \(self.timingBuffer[offset] ?? .zero)")
                    }
                } else {
                    print("❌ Could not cast comp.copy() to AVComposition.")
                }
            }

            self.segmentIndex += 1

            /// Update earliestPlaybackBufferTime
            for i in 0..<self.maxBufferSize {
                let idx = (self.segmentIndex + 1 + i) % self.maxBufferSize
                if self.playerItemBuffer[idx] != nil {
                    self.earliestPlaybackBufferTime = self.timingBuffer[idx] ?? .zero
                    break
                }
            }

            if doBug(.bugTimingBuffer) {
                for i in 0..<self.maxBufferSize {
                    print("time: ", i, self.timingBuffer[i])
                }
            }
        }
    }

    /// Blank out all running compositions and buffers
    func resetBuffer() {
        compositionQueue.async { [weak self] in
            guard let self = self else { return }

            print("resetting buffer")

            // Clear any existing compositions/tracks first to avoid stale references
            self.runningComposition.removeAll(keepingCapacity: true)
            self.runningTrack.removeAll(keepingCapacity: true)

            for offset in self.offsets {
                let comp = AVMutableComposition()
                let track = comp.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                self.runningComposition[offset] = comp
                if let track {
                    self.runningTrack[offset] = track
                }
            }

            for i in 0..<self.maxBufferSize {
                self.playerItemBuffer[i] = nil
                self.timingBuffer[i]     = nil
            }

            // Start over at index 0
            self.segmentIndex = 0
            self.nextBufferStartTime = .zero

            // Make “now” undefined until first frame is captured again
            self.bufferTimeOffset = .zero
            self.earliestPlaybackBufferTime = .zero

            // Reset AVQueuePlayer on main
            print("resetting player")
            DispatchQueue.main.async {
                let pm = PlaybackManager.shared
                pm.playerConstant.pause()
                pm.playerConstant.removeAllItems()
                pm.playbackState = .unknown
                pm.delayTime = .zero
            }
        }
    }
    
}
