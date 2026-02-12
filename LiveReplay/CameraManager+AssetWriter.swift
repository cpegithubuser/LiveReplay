//
//  CameraManager+AssetWriter.swift
//  LiveReplay
//
//  Created by Albert Soong on 8/1/25.
//

import Foundation
import AVFoundation

extension CameraManager: AVAssetWriterDelegate {
    
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        printBug(.bugAssetWriter, "segmentType: \(segmentType.rawValue) - size: \(segmentData.count)")
        
        // Ignore any late segment callbacks after we’ve reset for background/camera switch.
        // Also ensure this callback belongs to the *current* writer instance.
        guard !isBackgroundedOrShuttingDown else {
            printBug(.bugAssetWriter, "ignoring segment: backgrounded/shutting down")
            return
        }
        guard self.assetWriter === writer else {
            printBug(.bugAssetWriter, "ignoring segment: stale writer callback")
            return
        }

        switch segmentType {
        case .initialization:
            initializationData = segmentData
        case .separable:
            guard !initializationData.isEmpty else {
                printBug(.bugAssetWriter, "missing initialization segment; dropping separable")
                return
            }
            let mp4Data = initializationData + segmentData
            
            if debugWriteSegmentsToDisk, let folder = debugSegmentsFolderURL() {
                let fileURL = folder.appendingPathComponent("segment_\(bufferManager.segmentIndex).mp4")
                try? mp4Data.write(to: fileURL)
                OnScreenLog("writing to disk: \(fileURL.path)")
            }
            
            printBug(.bugAssetWriter, "segment:", bufferManager.segmentIndex+1)
            printBug(.bugAssetWriter, "now time, current playing time", playbackManager.currentTime, playbackManager.getCurrentPlayingTime())
                    
            //  let asset = AVAsset(url: fileURL)
            printBug(.bugResourceLoader, "enter avurlasset loader")
            guard let asset = AVURLAsset(mp4Data: mp4Data) else { return }
            printBug(.bugResourceLoader, "exit avurlasset loader")
            
            /// Wrap segment in AVMutableComposition → AVComposition before adding to queue (reduces jumpiness)
            let comp = AVMutableComposition()
            guard let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            guard let srcTrack = asset.tracks(withMediaType: .video).first else { return }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try? track.insertTimeRange(range, of: srcTrack, at: .zero)
            guard let copied = comp.copy() as? AVComposition else { return }
            
            let playerItem = AVPlayerItem(asset: copied)
            objc_setAssociatedObject(playerItem, &playbackManager.playerItemStartTimeKey, NSValue(time: bufferManager.nextBufferStartTime), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            
            DispatchQueue.main.async {
                self.playbackManager.playerConstant.insert(playerItem, after: nil)
            }
            
            printBug(.bugAssetWriter, "✅ [AVPlayer] Added valid player item.")
            
            bufferManager.addNewAsset(asset: asset)

            playbackManager.printPlayerItemBuffer()
            playbackManager.printPlayerQueueWithAssets()

        @unknown default:
            break
        }
        
    }
    
}
