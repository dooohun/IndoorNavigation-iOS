import UIKit
import SceneKit
import ARKit

class ARNavigationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    var sceneView: ARSCNView!
    var locateButton: UIButton!
    var scanningOverlayView: UIView!
    var scanCompleteBadge: UIView!
    var scanFailedView: UIView!
    var scanFailedLabel: UILabel!
    var arrivalBadge: UIView!

    private let logic = ARNavigationLogic()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        setupLocateButton()
        setupScanningOverlay()
        setupScanCompleteBadge()
        setupScanFailedView()
        setupArrivalBadge()

        logic.delegate = self
        logic.arSession = sceneView.session
        logic.scene = sceneView.scene
    }

    // MARK: - UI 세팅

    private func setupARView() {
        sceneView = ARSCNView(frame: self.view.bounds)
        self.view.addSubview(sceneView)
        sceneView.delegate = self
        sceneView.showsStatistics = true
        sceneView.autoenablesDefaultLighting = true
    }

    private func setupLocateButton() {
        locateButton = UIButton(type: .system)
        locateButton.setTitle("현위치 스캔 및 길찾기 시작", for: .normal)
        locateButton.backgroundColor = .systemBlue
        locateButton.setTitleColor(.white, for: .normal)
        locateButton.layer.cornerRadius = 10
        locateButton.frame = CGRect(x: 20, y: self.view.bounds.height - 100, width: self.view.bounds.width - 40, height: 50)
        locateButton.addTarget(self, action: #selector(onLocateButtonTapped), for: .touchUpInside)
        self.view.addSubview(locateButton)
    }

    private func setupScanningOverlay() {
        let bounds = self.view.bounds

        scanningOverlayView = UIView(frame: bounds)
        scanningOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scanningOverlayView.isHidden = true
        scanningOverlayView.isUserInteractionEnabled = false

        // 스캔 아이콘 (SF Symbol)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let iconImage = UIImage(systemName: "viewfinder", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: bounds.midX - 40, y: bounds.midY - 120, width: 80, height: 80)

        // 메인 안내 문구
        let titleLabel = UILabel()
        titleLabel.text = "좌우로 천천히 스캔해 주세요!"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.frame = CGRect(x: 20, y: bounds.midY - 20, width: bounds.width - 40, height: 30)

        // 보조 안내 문구
        let subtitleLabel = UILabel()
        subtitleLabel.text = "위치를 확인하고 있어요.\n스마트폰을 들고 천천히 움직여 보세요."
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.frame = CGRect(x: 20, y: bounds.midY + 16, width: bounds.width - 40, height: 50)

        scanningOverlayView.addSubview(iconView)
        scanningOverlayView.addSubview(titleLabel)
        scanningOverlayView.addSubview(subtitleLabel)
        self.view.addSubview(scanningOverlayView)
    }

    private func setupScanCompleteBadge() {
        let bounds = self.view.bounds

        // 반투명 어두운 배경
        scanCompleteBadge = UIView(frame: bounds)
        scanCompleteBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        scanCompleteBadge.isHidden = true
        scanCompleteBadge.isUserInteractionEnabled = false

        // 필(pill) 형태 배지
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        pill.layer.cornerRadius = 22
        pill.translatesAutoresizingMaskIntoConstraints = false
        scanCompleteBadge.addSubview(pill)

        // 체크마크 아이콘
        let checkConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let checkImage = UIImage(systemName: "checkmark.circle.fill", withConfiguration: checkConfig)
        let checkView = UIImageView(image: checkImage)
        checkView.tintColor = .systemBlue
        checkView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(checkView)

        // "스캔 완료" 텍스트
        let label = UILabel()
        label.text = "스캔 완료"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        self.view.addSubview(scanCompleteBadge)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: scanCompleteBadge.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: scanCompleteBadge.bottomAnchor, constant: -bounds.height * 0.35),
            pill.heightAnchor.constraint(equalToConstant: 44),

            checkView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            checkView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 22),
            checkView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: checkView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
        ])
    }

    private func setupScanFailedView() {
        let bounds = self.view.bounds

        scanFailedView = UIView(frame: bounds)
        scanFailedView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scanFailedView.isHidden = true
        scanFailedView.isUserInteractionEnabled = false

        // 실패 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        let iconImage = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: bounds.midX - 25, y: bounds.midY - 80, width: 50, height: 50)

        // 실패 메시지
        scanFailedLabel = UILabel()
        scanFailedLabel.textColor = .white
        scanFailedLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        scanFailedLabel.textAlignment = .center
        scanFailedLabel.numberOfLines = 0
        scanFailedLabel.frame = CGRect(x: 20, y: bounds.midY - 16, width: bounds.width - 40, height: 60)

        scanFailedView.addSubview(iconView)
        scanFailedView.addSubview(scanFailedLabel)
        self.view.addSubview(scanFailedView)
    }

    private func setupArrivalBadge() {
        let bounds = self.view.bounds

        // 반투명 어두운 배경
        arrivalBadge = UIView(frame: bounds)
        arrivalBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        arrivalBadge.isHidden = true
        arrivalBadge.isUserInteractionEnabled = false

        // 필(pill) 형태 배지
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        pill.layer.cornerRadius = 22
        pill.translatesAutoresizingMaskIntoConstraints = false
        arrivalBadge.addSubview(pill)

        // 위치 핀 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let iconImage = UIImage(systemName: "mappin.circle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemRed
        iconView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(iconView)

        // "목적지 도착" 텍스트
        let label = UILabel()
        label.text = "목적지 도착"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        self.view.addSubview(arrivalBadge)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: arrivalBadge.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: arrivalBadge.bottomAnchor, constant: -bounds.height * 0.35),
            pill.heightAnchor.constraint(equalToConstant: 44),

            iconView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
        ])
    }

    @objc private func onLocateButtonTapped() {
        logic.startLocalizationFlow()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        sceneView.session.delegate = self
        sceneView.session.run(configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        logic.stopCapture()
        logic.stopArrivalCheck()
        sceneView.session.pause()
    }
}

// MARK: - ARNavigationLogicDelegate

extension ARNavigationViewController: ARNavigationLogicDelegate {

    func updateStatus(_ message: String, color: UIColor) {
        // 스캔 오버레이 / 완료 배지가 대체
    }

    func setLoading(_ loading: Bool) {
        locateButton.isEnabled = !loading
        locateButton.alpha = loading ? 0.5 : 1.0
    }

    func setCaptureProgress(text: String, isHidden: Bool) {
        // 스캔 오버레이가 대체하므로 별도 표시 없음
    }

    func setScanningOverlay(visible: Bool) {
        if visible {
            scanningOverlayView.alpha = 0
            scanningOverlayView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.scanningOverlayView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.3) {
                self.scanningOverlayView.alpha = 0
            } completion: { _ in
                self.scanningOverlayView.isHidden = true
            }
        }
    }

    func showScanComplete() {
        scanningOverlayView.isHidden = true

        scanCompleteBadge.alpha = 0
        scanCompleteBadge.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.scanCompleteBadge.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIView.animate(withDuration: 0.4) {
                self.scanCompleteBadge.alpha = 0
            } completion: { _ in
                self.scanCompleteBadge.isHidden = true
            }
        }
    }

    func showArrivalNotification() {
        arrivalBadge.alpha = 0
        arrivalBadge.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.arrivalBadge.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.4) {
                self.arrivalBadge.alpha = 0
            } completion: { _ in
                self.arrivalBadge.isHidden = true
            }
        }
    }

    func showScanFailed(message: String) {
        scanningOverlayView.isHidden = true
        scanFailedLabel.text = message

        scanFailedView.alpha = 0
        scanFailedView.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.scanFailedView.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.4) {
                self.scanFailedView.alpha = 0
            } completion: { _ in
                self.scanFailedView.isHidden = true
            }
        }
    }
}
