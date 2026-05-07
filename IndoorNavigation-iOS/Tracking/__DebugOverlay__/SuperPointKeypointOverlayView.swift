//
// 이 폴더(__DebugOverlay__)는 디버그 시각화 전용입니다.
// 프로덕션 배포 전 폴더 통째로 삭제 가능하며, 본 모듈(Tracking/) 코드는
// 이 폴더 어떤 파일도 import 하지 않습니다 (단방향 의존).
//

#if DEBUG
import UIKit

final class SuperPointKeypointOverlayView: UIView {

    private let pointsLayer = CAShapeLayer()
    private var inputSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.addSublayer(pointsLayer)
        pointsLayer.fillColor = UIColor.systemGreen.withAlphaComponent(0.85).cgColor
        pointsLayer.strokeColor = UIColor.black.withAlphaComponent(0.4).cgColor
        pointsLayer.lineWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        pointsLayer.frame = bounds
    }

    func updateKeypoints(_ keypoints: [SIMD3<Float>], inputSize: CGSize) {
        self.inputSize = inputSize
        let path = UIBezierPath()
        let radius: CGFloat = 2.5

        let sx = bounds.width / inputSize.width
        let sy = bounds.height / inputSize.height
        let scale = max(sx, sy)
        let drawnW = inputSize.width * scale
        let drawnH = inputSize.height * scale
        let dx = (bounds.width - drawnW) / 2
        let dy = (bounds.height - drawnH) / 2

        for kp in keypoints {
            let x = CGFloat(kp.x) * scale + dx
            let y = CGFloat(kp.y) * scale + dy
            path.append(UIBezierPath(arcCenter: CGPoint(x: x, y: y),
                                     radius: radius, startAngle: 0,
                                     endAngle: 2 * .pi, clockwise: true))
        }
        pointsLayer.path = path.cgPath
    }

    func clear() {
        pointsLayer.path = nil
    }
}
#endif
