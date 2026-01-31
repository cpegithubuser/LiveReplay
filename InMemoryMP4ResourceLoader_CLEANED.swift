//
//  InMemoryMP4ResourceLoader.swift (Cleaned Version)
//  LiveReplay
//
//  Improved version with cleanup and better error handling
//

import AVFoundation
import ObjectiveC

final class InMemoryMP4ResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let mp4Data: Data

    // Needs to be accessible from the AVURLAsset extension below
    fileprivate static var associatedObjectKey: UInt8 = 0

    init(mp4Data: Data) {
        guard !mp4Data.isEmpty else {
            fatalError("InMemoryMP4ResourceLoader: mp4Data cannot be empty")
        }
        self.mp4Data = mp4Data
        super.init()
        printBug(.bugResourceLoader, "✅ [ResourceLoader] Initialized with \(mp4Data.count) bytes")
    }

    deinit {
        printBug(.bugResourceLoader, "❌ [ResourceLoader] Deallocated")
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {

        guard let url = loadingRequest.request.url else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Request URL is nil")
            return false
        }

        guard url.scheme == "inmemory-mp4" else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Unsupported scheme: \(url.scheme ?? "nil")")
            return false
        }

        var handledAnything = false
        var error: Error?

        if let info = loadingRequest.contentInformationRequest {
            handledAnything = true
            fillContentInfo(info)
        }

        if let data = loadingRequest.dataRequest {
            handledAnything = true
            error = serveData(data)
        }

        guard handledAnything else {
            printBug(.bugResourceLoader, "⚠️ [ResourceLoader] No contentInformationRequest or dataRequest")
            return false
        }

        // Finish loading - error if data request failed, otherwise success
        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }

        return true
    }

    // MARK: - Helpers

    private func fillContentInfo(_ info: AVAssetResourceLoadingContentInformationRequest) {
        printBug(.bugResourceLoader, "ℹ️ [ResourceLoader] Handling content information request")
        
        info.contentType = AVFileType.mp4.rawValue
        info.contentLength = Int64(mp4Data.count)
        info.isByteRangeAccessSupported = true
        
        printBug(.bugResourceLoader, "📏 [ResourceLoader] Content length: \(mp4Data.count) bytes")
    }

    private func serveData(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Error? {
        let reqStart = dataRequest.requestedOffset
        let reqEnd = reqStart + Int64(dataRequest.requestedLength) // exclusive
        let cur = dataRequest.currentOffset

        // Start from where AVFoundation says the next bytes should come from
        let start64 = max(reqStart, cur)

        let eof64 = Int64(mp4Data.count)
        let end64 = min(reqEnd, eof64) // clamp at EOF

        printBug(.bugResourceLoader, "📡 [ResourceLoader] Requested byte range: \(reqStart) to \(reqEnd), current: \(cur)")

        // Invalid start (negative or past EOF)
        guard start64 >= 0, start64 <= eof64 else {
            return NSError(
                domain: "InMemoryMP4",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Offset out of bounds",
                    "requestedOffset": reqStart,
                    "requestedLength": dataRequest.requestedLength,
                    "currentOffset": cur,
                    "dataLength": mp4Data.count
                ]
            )
        }

        // Nothing to send (already satisfied or at EOF)
        guard end64 > start64 else {
            printBug(.bugResourceLoader, "📡 [ResourceLoader] No data to send (already satisfied or at EOF)")
            return nil
        }

        let start = Int(start64)
        let end = Int(end64)

        let requestedData = mp4Data.subdata(in: start..<end)
        
        printBug(.bugResourceLoader, "📤 [ResourceLoader] Sending \(requestedData.count) bytes")
        dataRequest.respond(with: requestedData)
        
        printBug(.bugResourceLoader, "✅ [ResourceLoader] Successfully handled data request")
        return nil
    }
}

// MARK: - AVURLAsset Extension

extension AVURLAsset {
    /// Creates an AVURLAsset that loads MP4 data from memory instead of disk.
    /// - Parameter mp4Data: The complete MP4 file data
    /// - Returns: An AVURLAsset configured to load from memory, or nil if initialization fails
    convenience init?(mp4Data: Data) {
        guard !mp4Data.isEmpty else {
            printBug(.bugResourceLoader, "❌ [AVURLAsset] Cannot create asset from empty data")
            return nil
        }

        let uniqueID = UUID().uuidString
        guard let url = URL(string: "inmemory-mp4://video-\(uniqueID)") else {
            printBug(.bugResourceLoader, "❌ [AVURLAsset] Failed to create URL")
            return nil
        }

        printBug(.bugResourceLoader, "🚀 [AVURLAsset] Creating asset with URL: \(url)")

        self.init(url: url)

        let loader = InMemoryMP4ResourceLoader(mp4Data: mp4Data)
        self.resourceLoader.setDelegate(loader, queue: DispatchQueue.global(qos: .userInitiated))

        objc_setAssociatedObject(
            self,
            &InMemoryMP4ResourceLoader.associatedObjectKey,
            loader,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        printBug(.bugResourceLoader, "✅ [AVURLAsset] Initialized in-memory asset: \(url)")
    }
}
