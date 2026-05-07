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

    /// landscape 추출 좌표(u, v) 를 portrait 화면에 90° CW 회전 매핑.
    /// SuperPoint 입력이 ARFrame raw(가로) 비율 그대로 들어가므로 keypoint 도 landscape
    /// 좌표계. 사용자 폰이 portrait + 후면 카메라일 때 ARSCNView 가 영상을 90° CW
    /// 회전해서 보여주는 것과 일치하도록 같은 회전을 overlay 에도 적용.
    /// 회전 후 좌표계: rotatedW = inputSize.height, rotatedH = inputSize.width.
    /// 매핑: rx = (inputSize.height - kp.y), ry = kp.x.
    func updateKeypoints(_ keypoints: [SIMD3<Float>], inputSize: CGSize) {
        self.inputSize = inputSize
        let path = UIBezierPath()
        let radius: CGFloat = 2.5

        // 회전 후 가상 입력 사이즈 (portrait)
        let rotatedW = inputSize.height
        let rotatedH = inputSize.width

        let sx = bounds.width / rotatedW
        let sy = bounds.height / rotatedH
        let scale = max(sx, sy)            // aspect-fill (ARSCNView 기본과 동일)
        let drawnW = rotatedW * scale
        let drawnH = rotatedH * scale
        let dx = (bounds.width - drawnW) / 2
        let dy = (bounds.height - drawnH) / 2

        for kp in keypoints {
            // 90° CW 회전: (u, v) in landscape → (H - v, u) in portrait coord
            let rx = inputSize.height - CGFloat(kp.y)
            let ry = CGFloat(kp.x)
            let x = rx * scale + dx
            let y = ry * scale + dy
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
