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
        switch segmentType {
        case .initialization:
            initializationData = segmentData
        case .separable:
            let mp4Data = initializationData + segmentData
            let segmentNum = bufferManager.segmentIndex + 1
            
            guard let asset = AVURLAsset(mp4Data: mp4Data) else {
                print("⚠️ AVURLAsset(mp4Data:) failed for segment \(segmentNum), size \(mp4Data.count)")
                return
            }
            
            let playerItem = AVPlayerItem(asset: asset)
            let startTime = bufferManager.nextBufferStartTime
            objc_setAssociatedObject(playerItem, &playbackManager.playerItemStartTimeKey, NSValue(time: startTime), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            
            DispatchQueue.main.async {
                self.playbackManager.playerConstant.insert(playerItem, after: nil)
                self.playbackManager.printPlayerItemBuffer()
                self.playbackManager.printPlayerQueueWithAssets()
            }
            
            bufferManager.addNewAsset(asset: asset)
            
            printBug(.bugAssetWriter, "segment:", segmentNum, "size:", segmentData.count, "✅ [AVPlayer] Added player item.")

        @unknown default:
            break
        }
    }
    
}
