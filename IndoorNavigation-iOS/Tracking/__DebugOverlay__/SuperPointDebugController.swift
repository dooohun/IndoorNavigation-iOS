//
// 이 폴더(__DebugOverlay__)는 디버그 시각화 전용입니다.
// 프로덕션 배포 전 폴더 통째로 삭제 가능합니다.
//

#if DEBUG
import UIKit

final class SuperPointDebugController {

    private weak var hostView: UIView?
    private let overlayView: SuperPointKeypointOverlayView
    private let toggleButton: UIButton
    /// 추론 시간(mean / p95 ms) 표시 라벨. 토글 OFF 시 isHidden.
    private let inferenceTimeLabel: UILabel
    private(set) var isEnabled: Bool = false

    init(hostView: UIView) {
        self.hostView = hostView
        self.overlayView = SuperPointKeypointOverlayView(frame: hostView.bounds)
        self.overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.overlayView.isHidden = true

        let btn = UIButton(type: .system)
        btn.setTitle("SP", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        btn.layer.cornerRadius = 16
        btn.frame = CGRect(x: hostView.bounds.width - 48, y: 60, width: 32, height: 32)
        btn.autoresizingMask = [.flexibleLeftMargin]
        self.toggleButton = btn

        // 추론 시간 라벨: 토글 버튼 바로 아래, 우상단 정렬, 흑반투명 배경.
        let label = UILabel()
        label.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.textAlignment = .center
        label.text = "— / — ms"
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        label.frame = CGRect(x: hostView.bounds.width - 96, y: 60 + 32 + 6, width: 80, height: 18)
        label.autoresizingMask = [.flexibleLeftMargin]
        label.isHidden = true
        self.inferenceTimeLabel = label

        hostView.addSubview(overlayView)
        hostView.addSubview(btn)
        hostView.addSubview(label)
        btn.addTarget(self, action: #selector(onToggleTapped), for: .touchUpInside)
    }

    @objc private func onToggleTapped() {
        isEnabled.toggle()
        overlayView.isHidden = !isEnabled
        inferenceTimeLabel.isHidden = !isEnabled
        toggleButton.backgroundColor = isEnabled
            ? UIColor.systemGreen.withAlphaComponent(0.7)
            : UIColor.black.withAlphaComponent(0.5)
    }

    func receiveFrame(_ frame: SuperPointFrame) {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.overlayView.updateKeypoints(frame.keypoints, inputSize: frame.inputSize)
        }
    }

    /// 평균/95퍼센타일 추론 시간(ms) 표시. ARNavigationLogic 의 ring buffer 가 호출.
    func updateInferenceTime(meanMs: Double, p95Ms: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isEnabled else { return }
            self.inferenceTimeLabel.text = String(format: "%.0f / %.0f ms", meanMs, p95Ms)
        }
    }
}
#endif
