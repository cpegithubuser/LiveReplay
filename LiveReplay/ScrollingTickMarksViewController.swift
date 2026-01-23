//
//  ScrollingTickMarksViewController.swift
//  LiveReplay
//
//  Created by Albert Soong on 2/21/25.
//

import AVFoundation
import UIKit

class ScrollingTickMarksViewController: UIViewController {
    
    var collectionView: UICollectionView!
    
    /// Tick marks properties
    var cellWidth: CGFloat = 20   /// Width of each tick mark (default, is usually set by caller)
    let buffer = 200              /// ✅ Increased buffer for smoother looping
    var totalTicks: Int = 0
    
    /// Tick Tracking
    var cumulativeOffset: CGFloat = 0
    var previousOffset: CGFloat = 0
    var previousTickIndex: Int = 0
    var tickCount: Int = 0
    var tickChange: Int = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0 // No extra spacing

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.register(CollectionViewCell.self, forCellWithReuseIdentifier: CollectionViewCell.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isPagingEnabled = false
        collectionView.showsHorizontalScrollIndicator = false
        
        /// the collection view itself's background is gray and transparent
        collectionView.backgroundColor = UIColor.gray.withAlphaComponent(0.3)

        view.addSubview(collectionView)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.frame = view.bounds
        calculateTotalTicks()
    }
    
    /// ✅ Dynamically calculate required tick marks
    func calculateTotalTicks() {
        let screenWidth = view.bounds.width
        let ticksOnScreen = Int(screenWidth / cellWidth)
        totalTicks = ticksOnScreen + buffer
        collectionView.reloadData()
    }
}

extension ScrollingTickMarksViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return totalTicks
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CollectionViewCell.identifier, for: indexPath) as? CollectionViewCell else {
            return UICollectionViewCell()
        }
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: cellWidth, height: collectionView.bounds.height) // ✅ Uses cellWidth
    }
}

extension ScrollingTickMarksViewController: UIScrollViewDelegate {
    
    /// ✅ Track scrolling and count ticks correctly
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset.x  // where are we in the scroll
        let currentTickIndex = Int((currentOffset + cumulativeOffset) / cellWidth + 0.5) // ✅ tick position in the cumulative world
        printBug(.bugScrolling, "enter", currentOffset, previousOffset, cumulativeOffset, currentTickIndex, previousTickIndex)
        
        /// ✅ Count ticks only when a new tick is passed
        if currentTickIndex != previousTickIndex {
            let difference = currentTickIndex - previousTickIndex
            
            // ✅ Update Tick Counter
            tickCount += difference
            
            // ✅ Update Tick Change
            tickChange = difference
            
            printBug(.bugScrolling, "player time: \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: PlaybackManager.shared.playerConstant.currentTime().seconds), dateStyle: .medium, timeStyle: .medium)).\(Int(PlaybackManager.shared.playerConstant.currentTime().seconds.truncatingRemainder(dividingBy: 1) * 1000))")
            let currentPlayingTime = PlaybackManager.shared.getCurrentPlayingTime()
            printBug(.bugScrolling, "getCurrentPlayingTime:", CMTimeConvertScale(currentPlayingTime, timescale: 600, method: .default))
            
            // Add 1/30th of a second (one frame at 30 FPS)
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(CameraManager.shared.selectedFrameRate))
            let adjustedTargetTime = CMTimeSubtract(currentPlayingTime, CMTimeMultiply(frameDuration, multiplier: Int32(tickChange)))
            
            // ✅ Haptic Feedback on each tick
            let generator = UIImpactFeedbackGenerator(style: .light)
            //generator.impactOccurred()
            
            if let currentItem = PlaybackManager.shared.playerConstant.currentItem {
                let playbackRangeStart = currentPlayingTime - PlaybackManager.shared.playerConstant.currentTime()
             //   let smallOffset = CMTime(value: 2, timescale: 600) // A very small offset (2/600 sec)
                let smallOffset = CMTime(value: 0, timescale: 600) // A very small offset (2/600 sec)
                let playbackRangeEnd = CMTimeSubtract(CMTimeAdd(playbackRangeStart, currentItem.duration), CMTimeAdd(frameDuration, smallOffset))
                printBug(.bugScrolling, "item:", currentItem)
                printBug(.bugScrolling, "playbackRangeStart:", CMTimeConvertScale(playbackRangeStart, timescale: 600, method: .default))
                printBug(.bugScrolling, "playbackRangeEnd:", CMTimeConvertScale(playbackRangeEnd, timescale: 600, method: .default))
                printBug(.bugScrolling, "adjustedTargetTime:", CMTimeConvertScale(adjustedTargetTime, timescale: 600, method: .default))
                printBug(.bugScrolling, "currentlyplayingStartTime:", CMTimeConvertScale(PlaybackManager.shared.currentlyPlayingPlayerItemStartTime, timescale: 600, method: .default))
                DispatchQueue.main.async {
                    PlaybackManager.shared.playerConstant.pause()
  //                      PlaybackManager.shared.seeker?.smoothlyJump(targetTime: adjustedTargetTime)
//                    print("duration", frameDuration)
                    print("adjusted target", adjustedTargetTime)
//                    print("current", currentPlayingTime)
                    print(CMTimeMultiply(frameDuration, multiplier: Int32(self.tickChange)))
                    print("playertime", currentItem.currentTime())
                    if adjustedTargetTime >= playbackRangeStart && adjustedTargetTime < playbackRangeEnd {
                        currentItem.step(byCount: -self.tickChange)
                        print("playertime after step", currentItem.currentTime())
                    } else {
                        // Jump to the new adjusted time if it's outside the valid range
                   //     PlaybackManager.shared.jumpToPlayingTimex(targetTime: adjustedTargetTime)
                        PlaybackManager.shared.jump(to: adjustedTargetTime)
                    }
                }
            }
            
            
        }

        // ✅ Update previous tick index
        previousTickIndex = currentTickIndex
        
        /// ✅ Infinite Scrolling Handling
        if currentOffset > cellWidth * CGFloat(totalTicks - buffer) {
            cumulativeOffset += cellWidth * CGFloat(totalTicks - buffer)
            collectionView.contentOffset.x -= cellWidth * CGFloat(totalTicks - buffer)
        }
        if currentOffset < 0 {
            cumulativeOffset -= cellWidth * CGFloat(totalTicks - buffer)
            collectionView.contentOffset.x += cellWidth * CGFloat(totalTicks - buffer)
        }
        printBug(.bugScrolling, "exit", currentOffset, previousOffset, cumulativeOffset, currentTickIndex, previousTickIndex)
    }

    /// ✅ Snap to the closest tick mark when scrolling stops
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let targetOffsetX = targetContentOffset.pointee.x
        let closestTickIndex = round(targetOffsetX / cellWidth) // ✅ Snap to closest tick
        targetContentOffset.pointee.x = closestTickIndex * cellWidth
    }
}
