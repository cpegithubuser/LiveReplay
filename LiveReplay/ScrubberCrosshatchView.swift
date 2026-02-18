//
//  ScrubberCrosshatchView.swift
//  LiveReplay
//
//  Crosshatch done like the dots: one CALayer per hatch line, added to the view.
//

import SwiftUI
import UIKit

final class CrosshatchHostView: UIView {
    static let hatchCount = 50
    var lineLayers: [CALayer] = []
    var expectedWidth: CGFloat = 0
    var expectedHeight: CGFloat = 0
    private let hatchColor = UIColor(white: 0.48, alpha: 1).cgColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.85, alpha: 1)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: expectedWidth > 0 ? expectedWidth : UIView.noIntrinsicMetric,
               height: expectedHeight > 0 ? expectedHeight : UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = max(bounds.width, expectedWidth)
        let h = max(bounds.height, expectedHeight)
        guard w > 0, h > 0 else { return }

        let n = Self.hatchCount
        let diag = sqrt(w * w + h * h)

        if lineLayers.count != n {
            lineLayers.forEach { $0.removeFromSuperlayer() }
            lineLayers = (0..<n).map { i in
                let line = CALayer()
                line.name = "hatch-\(i)"
                line.backgroundColor = hatchColor
                layer.addSublayer(line)
                return line
            }
        }

        for i in 0..<n {
            let line = lineLayers[i]
            let x = (CGFloat(i) + 0.5) * w / CGFloat(n)
            line.bounds = CGRect(x: 0, y: 0, width: diag, height: 1)
            line.position = CGPoint(x: x, y: h / 2)
            line.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            line.transform = CATransform3DMakeRotation(-.pi / 4, 0, 0, 1)
        }
    }
}

struct ScrubberCrosshatchView: UIViewRepresentable {
    var width: CGFloat
    var height: CGFloat

    func makeUIView(context: Context) -> CrosshatchHostView {
        CrosshatchHostView(frame: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
    }

    func updateUIView(_ view: CrosshatchHostView, context: Context) {
        view.expectedWidth = width
        view.expectedHeight = height
        view.invalidateIntrinsicContentSize()
        if width > 0, height > 0 {
            view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        }
        view.setNeedsLayout()
    }
}
