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

        switch segmentType {
        case .initialization:
            initializationData = segmentData
        case .separable:
            let mp4Data = initializationData + segmentData
            
            //   let segmentName = "segment_\(bufferManager.segmentIndex).m4s"
            
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
