//
//  BufferManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 4/20/25.
//

import AVKit
import Combine
import AVFoundation

final class BufferManager: ObservableObject {
    static let shared = BufferManager()

    /// Total number of slots in the buffer
    let maxBufferSize = 45

    /// Create AVCompositions every this many buffers.
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
    }

    /// The next asset to be added's start time. Save for next.
    var nextBufferStartTime: CMTime = .zero
    /// The time to add to current time to get to relative buffer time
    var bufferTimeOffset: CMTime = .zero
    var earliestPlaybackBufferTime: CMTime = .zero

    let lock = DispatchSemaphore(value: 1)

    func addNewAsset(asset: AVAsset) {
        lock.wait()
        defer { lock.signal() }

        let bufferIndex = segmentIndex % self.maxBufferSize

        self.timingBuffer[bufferIndex] = self.nextBufferStartTime
        self.nextBufferStartTime = CMTimeAdd(self.nextBufferStartTime, asset.duration)

        self.bufferTimeOffset = CMTimeSubtract(
            self.nextBufferStartTime,
            CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        )

        for offset in offsets {
            guard segmentIndex >= offset else { continue }

            // If we've wrapped back to this offset, throw it away and start fresh
            if bufferIndex == offset {
                let comp = AVMutableComposition()
                guard let track = comp.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    continue
                }
                runningComposition[offset] = comp
                runningTrack[offset] = track
            }

            guard let comp = runningComposition[offset],
                  let videoTrack = runningTrack[offset],
                  let srcTrack = asset.tracks(withMediaType: .video).first else {
                continue
            }

            let insertionTime = comp.duration
            let fullRange = CMTimeRange(start: .zero, duration: asset.duration)

            do {
                try videoTrack.insertTimeRange(fullRange, of: srcTrack, at: insertionTime)
            } catch {
                print("⚠️ insertTimeRange failed:", error)
                continue
            }

            if let copiedComposition = comp.copy() as? AVComposition {
                let item = AVPlayerItem(asset: copiedComposition)
                self.playerItemBuffer[offset] = item
                objc_setAssociatedObject(
                    item,
                    &PlaybackManager.shared.playerItemStartTimeKey,
                    NSValue(time: self.timingBuffer[offset] ?? .zero),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )

                let ptr = Unmanaged.passUnretained(item).toOpaque()
                printBug(.bugPlayerItemObserver, "🤖 setting assoc on composition item @ \(ptr) start: \(self.timingBuffer[offset] ?? .zero)")
            } else {
                print("❌ Could not cast runningComposition.copy() to AVComposition.")
            }
        }

        segmentIndex += 1

        // earliestPlaybackBufferTime
        for i in 0..<self.maxBufferSize {
            let idx = (segmentIndex + 1 + i) % self.maxBufferSize
            if self.playerItemBuffer[idx] != nil {
                self.earliestPlaybackBufferTime = self.timingBuffer[idx] ?? .zero
                break
            }
        }

        if doBug(.bugTimingBuffer) {
            for i in 0..<self.maxBufferSize {
                print("time: ", i, self.timingBuffer[i] as Any)
            }
        }
    }

    /// Blank out all running compositions and buffers
    func resetBuffer() {
        lock.wait()
        defer { lock.signal() }

        print("resetting buffer")

        // reset compositions + tracks
        runningComposition.removeAll()
        runningTrack.removeAll()
        for offset in offsets {
            let comp = AVMutableComposition()
            if let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                runningComposition[offset] = comp
                runningTrack[offset] = track
            }
            playerItemBuffer[offset] = nil
            timingBuffer[offset] = nil
        }

        // clear buffers
        for i in 0..<maxBufferSize {
            playerItemBuffer[i] = nil
            timingBuffer[i]     = nil
        }

        segmentIndex = 0
        nextBufferStartTime = .zero

        bufferTimeOffset = .zero
        earliestPlaybackBufferTime = .zero
    }
}
