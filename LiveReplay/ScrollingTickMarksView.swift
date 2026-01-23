//
//  ScrollingTickMarksView.swift
//  LiveReplay
//
//  Created by Albert Soong on 2/21/25.
//

import SwiftUI
import UIKit

struct ScrollingTickMarksView: UIViewControllerRepresentable {
    var cellWidth: CGFloat = 20  // ✅ Adjustable width of each cell

    func makeUIViewController(context: Context) -> ScrollingTickMarksViewController {
        let vc = ScrollingTickMarksViewController()
        return vc
    }

    func updateUIViewController(_ uiViewController: ScrollingTickMarksViewController, context: Context) {
    }
}

class CollectionViewCell: UICollectionViewCell {
    static let identifier = "cell"
    
    private let tickMark: UIView = {
        let view = UIView()
        view.backgroundColor = .white // Color of the tick mark
        return view
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(tickMark)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        let width: CGFloat = 2 // Thickness of the tick mark
        let height: CGFloat = bounds.height * 0.5 // Adjust height of the tick
        tickMark.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
    }
}
