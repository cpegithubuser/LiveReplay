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
        
        // Guard against late frames while backgrounding / switching cameras.
        if isBackgroundedOrShuttingDown {
            return
        }
        
        /// Drop a few frames because often they are dark from camera starting up
        if droppedFrames < 3 {
            droppedFrames += 1
            return
        }
        
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBackgroundedOrShuttingDown else { return }
            
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
                // If we're active but writer/input are missing, try to recreate.
                // If we're backgrounding/switching, just drop the frame.
                guard !self.isBackgroundedOrShuttingDown else { return }
                initializeAssetWriter()
                return
            }

            if writer.status == .unknown {
                // If the writer is in the unknown state, start writing
                let success = assetWriter.startWriting()
                assert(success)
                startTime = sampleBuffer.presentationTimeStamp
                assetWriter.startSession(atSourceTime: startTime)
                /// Here we record the CACurrentMediaTime of the first frame of video. This first frame is going to be "zero" time so we
                bufferManager.bufferTimeOffset = CMTimeSubtract(.zero, CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
                
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
