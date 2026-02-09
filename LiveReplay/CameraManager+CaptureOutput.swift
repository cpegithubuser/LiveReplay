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
            
            guard let writer = assetWriter,
                  let input  = videoInput else {
              initializeAssetWriter()
              return
            }

            if writer.status == .unknown {
                let success = assetWriter.startWriting()
                assert(success)
                startTime = sampleBuffer.presentationTimeStamp
                assetWriter.startSession(atSourceTime: startTime)
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
