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
//            let tracks = asset.tracks  // 🚨 Forces AVFoundation to check file existence
            printBug(.bugResourceLoader, "exit avurlasset loader")
//            printBug(.bugResourceLoader, "📊 [AVAsset] Tracks: \(tracks)")
//            printBug(.bugResourceLoader, "📊 [AVAsset] Playable: \(asset.isPlayable)")
            
//            printBug(.bugAssetWriter, asset)
//            let startPTS = tracks.first?.timeRange.start
//            printBug(.bugAssetWriter, "Asset first frame PTS: \(startPTS?.seconds)")
            
            /// Create a playerItem to insert at the end of the current AVQueuePlayer
            let playerItem = AVPlayerItem(asset: asset)

            //let ptr = Unmanaged.passUnretained(playerItem).toOpaque()
            //printBug(.bugPlayerItemObserver, "🤖 setting assoc on item @ \(ptr) start: \(bufferManager.nextBufferStartTime)")
            objc_setAssociatedObject(playerItem, &playbackManager.playerItemStartTimeKey, NSValue(time: bufferManager.nextBufferStartTime), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            
            DispatchQueue.main.async {
                self.playbackManager.playerConstant.insert(playerItem, after: nil)
            }
            
            printBug(.bugAssetWriter, "✅ [AVPlayer] Added valid player item.")
            
            /// Add this asset to the buffer
            bufferManager.addNewAsset(asset: asset)

            playbackManager.printPlayerItemBuffer()
            playbackManager.printPlayerQueueWithAssets()

        @unknown default:
            break
        }
        
    }
    
}
