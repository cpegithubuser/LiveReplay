//
//  InMemoryMP4ResourceLoader.swift
//  LiveReplay
//
//  Created by Albert Soong on 2/4/25.
//

import AVFoundation
import ObjectiveC
import AVKit

class InMemoryMP4ResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let mp4Data: Data
    private weak var asset: AVURLAsset?  // 🔹 Store a reference to the asset

    init(mp4Data: Data, asset: AVURLAsset) {
        self.mp4Data = mp4Data
        self.asset = asset  // 🔹 Save the associated asset
        printBug(.bugResourceLoader, "✅ [ResourceLoader] Initialized for asset: \(asset)")
    }
    
    deinit {
        printBug(.bugResourceLoader, "❌ [ResourceLoader] Deallocated! This should not happen during playback.")
    }

    func attachToAsset(_ asset: AVURLAsset) {
        //asset.resourceLoader.setDelegate(self, queue: DispatchQueue.global(qos: .userInteractive))
        printBug(.bugResourceLoader, "✅ [ResourceLoader] Attached to asset")
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        printBug(.bugResourceLoader, "🔄 [ResourceLoader] Received a request")

        guard let url = loadingRequest.request.url else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Request URL is nil")
            return false
        }
        
        printBug(.bugResourceLoader, "🌐 [ResourceLoader] Requested URL: \(url.absoluteString)")

        guard url.scheme == "inmemory-mp4" else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Unsupported scheme: \(url.scheme ?? "nil")")
            return false
        }
        
        if let asset = asset {
            printBug(.bugResourceLoader, "📌 [ResourceLoader] Associated asset: \(asset)")
        } else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Asset reference is nil")
        }

        // 🔹 Check Content Information Request
        if let infoRequest = loadingRequest.contentInformationRequest {
            printBug(.bugResourceLoader, "ℹ️ [ResourceLoader] Handling content information request")

            // ✅ Check if mp4Data is valid
            if mp4Data.isEmpty {
                printBug(.bugResourceLoader, "❌ [ResourceLoader] mp4Data is EMPTY! Returning error.")
                return false
            }
            
            printBug(.bugResourceLoader, "📏 [ResourceLoader] Setting content length: \(mp4Data.count) bytes")
            infoRequest.contentType = AVFileType.mp4.rawValue
            infoRequest.contentLength = Int64(mp4Data.count)
            infoRequest.isByteRangeAccessSupported = true
//            infoRequest.isEntireLengthAvailableOnDemand = true
        }

        // 🔹 Check Data Request
        if let dataRequest = loadingRequest.dataRequest {
            let requestedOffset = Int(dataRequest.requestedOffset)
            let requestedLength = dataRequest.requestedLength

            printBug(.bugResourceLoader, "📡 [ResourceLoader] Requested byte range: \(requestedOffset) to \(requestedOffset + requestedLength)")
            
            // ✅ Verify that mp4Data is large enough
            guard requestedOffset + requestedLength <= mp4Data.count else {
                printBug(.bugResourceLoader, "❌ [ResourceLoader] Requested range is out of bounds! mp4Data.count = \(mp4Data.count)")
                loadingRequest.finishLoading(with: NSError(domain: "InMemoryMP4", code: -1, userInfo: nil))
                return false
            }

            // ✅ Extract and send the requested data
            let requestedData = mp4Data.subdata(in: requestedOffset..<(requestedOffset + requestedLength))

            printBug(.bugResourceLoader, "📤 [ResourceLoader] Sending \(requestedData.count) bytes to AVPlayer")
            dataRequest.respond(with: requestedData)
            loadingRequest.finishLoading()
            printBug(.bugResourceLoader, "✅ [ResourceLoader] Successfully finished request")

            return true
        }
        
        printBug(.bugResourceLoader, "⚠️ [ResourceLoader] Request did not contain contentInformationRequest or dataRequest")
        return false
    }
}

extension AVURLAsset {
    convenience init?(mp4Data: Data) {
        
        let uniqueID = UUID().uuidString
            let url = URL(string: "inmemory-mp4://video-\(uniqueID)")!
            printBug(.bugResourceLoader, "🚀 [DEBUG] Generating unique URL: \(url)")

            self.init(url: url)
            printBug(.bugResourceLoader, "🚀 [DEBUG] AVURLAsset initialized with URL")

            let resourceLoader = InMemoryMP4ResourceLoader(mp4Data: mp4Data, asset: self)
            printBug(.bugResourceLoader, "🚀 [DEBUG] ResourceLoader created")

            self.resourceLoader.setDelegate(resourceLoader, queue: DispatchQueue.global(qos: .userInitiated))
     //       self.resourceLoader.setDelegate(resourceLoader, queue: DispatchQueue.global(qos: .userInteractive))
//            self.resourceLoader.setDelegate(resourceLoader, queue: .main)
            printBug(.bugResourceLoader, "🚀 [DEBUG] Delegate set on background queue")
        
            objc_setAssociatedObject(self, "AVURLAsset+InMemoryMP4-\(uniqueID)", resourceLoader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            printBug(.bugResourceLoader, "🚀 [DEBUG] Delegate retained")
        
            printBug(.bugResourceLoader, "✅ [AVURLAsset] Initialized unique in-memory asset: \(url)")
            printBug(.bugResourceLoader, "🚀 [DEBUG] Returning from AVURLAsset.init?")
        
    }
}



func testAVPlayerInMemoryMP4(mp4Data: Data) {
    print("🎥 Testing playback of in-memory MP4 file")

    guard let asset = AVURLAsset(mp4Data: mp4Data) else {
        print("❌ Failed to create AVURLAsset")
        return
    }

    DispatchQueue.main.async {
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            print("📺 Presenting AVPlayerViewController")
            rootVC.present(playerVC, animated: true) {
                print("✅ Playback started from memory")
                player.play()
            }
        } else {
            print("❌ Error: Could not find root view controller")
        }
    }
}
