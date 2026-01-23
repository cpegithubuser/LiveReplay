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
    
    let lock = DispatchSemaphore(value: 1)
    
    private let compositionQueue = DispatchQueue(
        label: "com.myapp.buffer.compositionQueue",
        qos: .userInitiated
 //       qos: .utility
    )
    
    func addNewAsset(asset: AVAsset) {
   //     compositionQueue.async {
        lock.wait()
            /// Current buffer index
            let bufferIndex = segmentIndex % self.maxBufferSize
            
            /// Add start time, calculated from last cycle
            self.timingBuffer[bufferIndex] = self.nextBufferStartTime
            
            /// Add new asset's duration for next next
            self.nextBufferStartTime = CMTimeAdd(self.nextBufferStartTime, asset.duration)
            
            self.bufferTimeOffset = CMTimeSubtract(self.nextBufferStartTime, CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
            /// use compostiions
            
            /// We're going to loop through all of the offsets and add the AVAsset to the running AVComposition
            for offset in offsets {
                
                if segmentIndex >= offset {
                    
                    // If we've wrapped back to this offset, throw it away and start fresh
                    if bufferIndex == offset {
                        runningComposition[offset] = AVMutableComposition()
                        runningTrack[offset] = runningComposition[offset]!.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                        
                    }
                    
                    // Append the new asset to that composition
                    let comp = runningComposition[offset]!
                    let videoTrack = comp.tracks(withMediaType: .video).first!
                    //let audioTrack = comp.tracks(withMediaType: .audio).first!
                    
                    let insertionTime = comp.duration
                    let fullRange = CMTimeRange(start: .zero, duration: asset.duration)
                    
                    try! videoTrack.insertTimeRange(fullRange,
                                                    of: asset.tracks(withMediaType: .video).first!,
                                                    at: insertionTime)
                    //  try! audioTrack.insertTimeRange(fullRange,
                    //                                  of: asset.tracks(withMediaType: .audio).first!,
                    //                                 at: insertionTime)
                    
                    
                    if let copiedComposition = self.runningComposition[offset]!.copy() as? AVComposition {
                        self.playerItemBuffer[offset] = AVPlayerItem(asset: copiedComposition)
                        objc_setAssociatedObject(self.playerItemBuffer[offset], &PlaybackManager.shared.playerItemStartTimeKey, NSValue(time: self.timingBuffer[offset] ?? .zero), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        
                        let ptr = Unmanaged.passUnretained(self.playerItemBuffer[offset]!).toOpaque()
                        printBug(.bugPlayerItemObserver, "🤖 setting assoc on composition item @ \(ptr) start: \(self.timingBuffer[offset] ?? .zero)")
                        //   self.playerItemBuffer[compositionIndex]?.preferredForwardBufferDuration = 5
                        /// blank out the previous composition
                        //  self.playerItemBuffer[bufferIndex] = nil
                    } else {
                        print("❌ Could not cast runningComposition.copy() to AVComposition.")
                    }
                    
                }
                
            }
        
        
            segmentIndex += 1
        
            
            /// This is checking what earliestPlaybackBufferTime is
            for i in 0..<self.maxBufferSize {
                /// Start and the oldest one (1 + current one)
                let bufferIndex = (segmentIndex + 1 + i) % self.maxBufferSize
                if self.playerItemBuffer[bufferIndex] != nil {
                    self.earliestPlaybackBufferTime = self.timingBuffer[bufferIndex] ?? .zero
                    break
                }
            }
            
            if doBug(.bugTimingBuffer) {
                for i in 0..<self.maxBufferSize {
                    print("time: ", i, self.timingBuffer[i])
                }
            }

     //   }
        lock.signal()
    }

    /// Blank out all running compositions and buffers
    func resetBuffer() {
        print("resetting buffer")
        for offset in offsets {
            self.runningComposition[offset] = AVMutableComposition()
            self.runningComposition[offset]!.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        }
        for i in 0..<maxBufferSize {
            playerItemBuffer[i] = nil
            timingBuffer[i]     = nil
        }
        /// Start over at index 0
        segmentIndex = 0
        /// start time start over
        nextBufferStartTime = .zero
        
        // Make “now” undefined until first frame is captured again
        bufferTimeOffset = .zero
        earliestPlaybackBufferTime = .zero

        /// reset AVQueuePlayer
        print("resetting player")
        DispatchQueue.main.async {
            let pm = PlaybackManager.shared
            pm.playerConstant.pause()
            pm.playerConstant.removeAllItems()
            pm.playbackState = .unknown
            pm.delayTime = .zero            // ← clear the pinned target so UI won’t show “5s ago”
        }
    }
    
}
