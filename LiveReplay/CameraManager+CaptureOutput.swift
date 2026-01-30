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
        if shouldDropFrame() { return }
        
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentMediaTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
            let newCurrentTime = CMTimeAdd(currentMediaTime, bufferManager.bufferTimeOffset)
            DispatchQueue.main.async { self.playbackManager.currentTime = newCurrentTime }
            
            guard let writer = assetWriter,
                  let input  = videoInput else {
                initializeAssetWriter()
                return
            }

            switch writer.status {
            case .unknown:
                guard writer.startWriting() else {
                    print("⚠️ Asset writer startWriting() failed")
                    return
                }
                let pts = sampleBuffer.presentationTimeStamp
                startTime = pts
                writer.startSession(atSourceTime: pts)
                let initialOffset = CMTimeSubtract(.zero, CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
                bufferManager.setBufferTimeOffset(initialOffset)
            case .writing:
                break
            default:
                print("⚠️ Asset writer in unexpected state: \(writer.status.rawValue)")
                return
            }
            
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
    

}
