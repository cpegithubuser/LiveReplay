//
//  CameraManager+CaptureOutput.swift
//  LiveReplay
//
//  Created by Albert Soong on 8/1/25.
//

import Foundation
import AVFoundation

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        /// Drop a few frames because often they are dark from camera starting up
        if droppedFrames < 3 {
            droppedFrames += 1
            return
        }
        
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentMediaTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
            
            // Resume playback on the first frame after returning from background.
            // Re-adjust the offset to absorb the camera-startup gap so that
            // currentTime stays exactly where .active placed it (no leftward jump).
            if self.resumePlaybackOnFirstFrame {
                self.resumePlaybackOnFirstFrame = false
                let targetCurrentTime = playbackManager.currentTime          // value set in .active
                bufferManager.bufferTimeOffset = CMTimeSubtract(targetCurrentTime, currentMediaTime)
                // currentTime = currentMediaTime + new offset = targetCurrentTime  (no change)
                DispatchQueue.main.async {
                    PlaybackManager.shared.playerConstant.play()
                    PlaybackManager.shared.playbackState = .playing
                }
            }
            
            playbackManager.currentTime = CMTimeAdd(currentMediaTime, bufferManager.bufferTimeOffset)
            
            // Print the width and height of the frame
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                //      print("Frame dimensions: \(width)x\(height)",UIDevice.current.orientation.rawValue, cameraSession?.outputs.first?.connections.first?.videoOrientation.rawValue ?? -1, currentTime)
                //            print("Frame dimensions: \(width)x\(height)",UIDevice.current.orientation.rawValue, cameraSession?.outputs.first?.connections.first?.videoOrientation.rawValue ?? -1, cameraLayer.connection?.videoOrientation.rawValue)
            } else {
                print("Could not access pixel buffer.")
            }
            
            guard let writer = assetWriter,
                  let input  = videoInput else {
              initializeAssetWriter(resetBuffer: false)
              return
            }

            if writer.status == .unknown {
                let success = assetWriter.startWriting()
                assert(success)
                startTime = sampleBuffer.presentationTimeStamp
                assetWriter.startSession(atSourceTime: startTime)
                // bufferTimeOffset is set only in addNewAsset (single source of truth)
            } else if writer.status == .writing {
                //       print("Asset writer already writing.")
            } else {
                print("Asset writer in unexpected state: \(assetWriter.status.rawValue)")
            }
            
            if startTime == nil {
                let success = assetWriter.startWriting()
                assert(success)
                startTime = sampleBuffer.presentationTimeStamp
                assetWriter.startSession(atSourceTime: startTime)
            }
            
            if input.isReadyForMoreMediaData {
              input.append(sampleBuffer)
            }
            
   //         print(sampleBuffer.presentationTimeStamp)
            
        }
    }
    

}
