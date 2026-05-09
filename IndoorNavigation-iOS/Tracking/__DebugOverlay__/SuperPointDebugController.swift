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
    /// 다음 프레임 dump 트리거 버튼. 토글 ON/OFF 와 무관하게 항상 보인다 (디버그 빌드 한정).
    private let dumpButton: UIButton
    /// 다음 프레임 dump 헬퍼. ARNavigationLogic.processARFrame 에서 직접 접근.
    let frameDumper: SuperPointFrameDumper
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

        // DUMP 버튼: SP 토글 버튼 바로 왼쪽. 같은 흑반투명 배경.
        let dumpBtn = UIButton(type: .system)
        dumpBtn.setTitle("DUMP", for: .normal)
        dumpBtn.titleLabel?.font = .systemFont(ofSize: 10, weight: .bold)
        dumpBtn.setTitleColor(.white, for: .normal)
        dumpBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        dumpBtn.layer.cornerRadius = 6
        dumpBtn.frame = CGRect(x: hostView.bounds.width - 88, y: 60, width: 36, height: 32)
        dumpBtn.autoresizingMask = [.flexibleLeftMargin]
        self.dumpButton = dumpBtn

        self.frameDumper = SuperPointFrameDumper()

        hostView.addSubview(overlayView)
        hostView.addSubview(btn)
        hostView.addSubview(label)
        hostView.addSubview(dumpBtn)
        btn.addTarget(self, action: #selector(onToggleTapped), for: .touchUpInside)
        dumpBtn.addTarget(self, action: #selector(onDumpTapped), for: .touchUpInside)
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

    // MARK: - Dump 트리거

    @objc private func onDumpTapped() {
        frameDumper.requestNextDump()
        flashDumpButton(color: .systemYellow)
    }

    /// dump 결과(성공/실패) 시각 피드백. ARNavigationLogic 이 completion 에서 호출.
    func notifyDumpResult(success: Bool) {
        flashDumpButton(color: success ? .systemGreen : .systemRed)
    }

    /// dump 버튼을 0.5초간 강조색으로 칠한 뒤 0.6초 ease-out 으로 흑반투명 복귀.
    private func flashDumpButton(color: UIColor) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dumpButton.backgroundColor = color.withAlphaComponent(0.85)
            UIView.animate(withDuration: 0.6, delay: 0.5, options: []) {
                self.dumpButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            }
        }
    }
}
#endif
