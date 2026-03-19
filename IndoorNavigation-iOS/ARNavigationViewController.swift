import UIKit
import SceneKit
import ARKit

class ARNavigationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    var sceneView: ARSCNView!
    var statusLabel: UILabel!
    var locateButton: UIButton!
    var spinner: UIActivityIndicatorView!
    var captureProgressLabel: UILabel!

    private let logic = ARNavigationLogic()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        setupStatusLabel()
        setupCaptureProgressLabel()
        setupSpinner()
        setupLocateButton()

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

    private func setupStatusLabel() {
        statusLabel = UILabel()
        statusLabel.text = "버튼을 눌러 현위치를 스캔하세요"
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.frame = CGRect(x: 20, y: 60, width: self.view.bounds.width - 40, height: 70)
        self.view.addSubview(statusLabel)
    }

    private func setupCaptureProgressLabel() {
        captureProgressLabel = UILabel()
        captureProgressLabel.textColor = .white
        captureProgressLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.75)
        captureProgressLabel.textAlignment = .center
        captureProgressLabel.font = .systemFont(ofSize: 22, weight: .bold)
        captureProgressLabel.layer.cornerRadius = 30
        captureProgressLabel.clipsToBounds = true
        captureProgressLabel.frame = CGRect(
            x: self.view.bounds.midX - 50,
            y: self.view.bounds.midY - 50,
            width: 100, height: 100
        )
        captureProgressLabel.isHidden = true
        self.view.addSubview(captureProgressLabel)
    }

    private func setupSpinner() {
        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.center = CGPoint(x: self.view.center.x, y: self.view.center.y + 70)
        spinner.hidesWhenStopped = true
        self.view.addSubview(spinner)
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
        sceneView.session.pause()
    }
}

// MARK: - ARNavigationLogicDelegate

extension ARNavigationViewController: ARNavigationLogicDelegate {

    func updateStatus(_ message: String, color: UIColor) {
        statusLabel.text = message
        statusLabel.textColor = color
    }

    func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimating()
            locateButton.isEnabled = false
            locateButton.alpha = 0.5
        } else {
            spinner.stopAnimating()
            locateButton.isEnabled = true
            locateButton.alpha = 1.0
        }
    }

    func setCaptureProgress(text: String, isHidden: Bool) {
        captureProgressLabel.text = text
        captureProgressLabel.isHidden = isHidden
    }
}
