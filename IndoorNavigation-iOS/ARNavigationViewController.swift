import UIKit
import SceneKit
import ARKit
import AVFoundation

class ARNavigationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    var sceneView: ARSCNView!
    var statusLabel: UILabel!
    var locateButton: UIButton!
    var spinner: UIActivityIndicatorView!
    var captureProgressLabel: UILabel!  // "사진 N/5"

    // MVP 용 테스트 파라미터
    let buildingId = "a6bbfe0b-8d05-4cde-82fc-7541f75f5954"
    let destinationName = "301호"
    var matchedARPose: simd_float4x4?
    var localizedPose: Pose?

    // 다중 프레임 캡처
    let maxImages = 5
    let captureInterval: TimeInterval = 0.8   // 0.8초마다 1장
    var capturedImages: [UIImage] = []
    var capturedARPoses: [simd_float4x4] = []
    var captureTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        setupStatusLabel()
        setupCaptureProgressLabel()
        setupSpinner()
        setupLocateButton()
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
        locateButton.addTarget(self, action: #selector(startLocalizationFlow), for: .touchUpInside)
        self.view.addSubview(locateButton)
    }

    private func setStatus(_ message: String, color: UIColor = .white) {
        statusLabel.text = message
        statusLabel.textColor = color
    }

    private func setLoading(_ loading: Bool) {
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        sceneView.session.delegate = self
        sceneView.session.run(configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
        sceneView.session.pause()
    }

    // MARK: - 다중 프레임 캡처 후 Localize

    @objc private func startLocalizationFlow() {
        guard sceneView.session.currentFrame != nil else {
            setStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        capturedImages = []
        capturedARPoses = []
        setLoading(true)
        setStatus("천천히 주변을 둘러보세요\n사진을 \(maxImages)장 촬영합니다.", color: .white)
        captureProgressLabel.isHidden = false

        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureOneFrame()
        }
    }

    private func captureOneFrame() {
        guard let frame = sceneView.session.currentFrame else { return }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

        capturedImages.append(uiImage)
        capturedARPoses.append(frame.camera.transform)

        let count = capturedImages.count
        captureProgressLabel.text = "\(count)/\(maxImages)"

        if count >= maxImages {
            stopCapture()
            sendToServer()
        }
    }

    private func stopCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        captureProgressLabel.isHidden = true
    }

    private func sendToServer() {
        guard !capturedImages.isEmpty else {
            setLoading(false)
            setStatus("캡처 실패. 다시 시도하세요.", color: .systemRed)
            return
        }

        setStatus("서버에 \(capturedImages.count)장 전송 중...", color: .white)

        NetworkManager.shared.localize(buildingId: buildingId, images: capturedImages) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let response):
                    self.handleLocalizeSuccess(response: response)
                case .failure(let error):
                    self.setLoading(false)
                    self.setStatus("서버 연결 실패:\n\(error.localizedDescription)", color: .systemRed)
                }
            }
        }
    }

    private func handleLocalizeSuccess(response: LocalizeResponse) {
        guard let pose = response.pose, pose.x != nil else {
            setLoading(false)
            var reason = "위치를 특정하지 못했습니다."
            if let matches = response.numMatches {
                reason += "\n매칭 특징점: \(matches)개 (부족)"
            }
            if let conf = response.confidence {
                reason += "\n신뢰도: \(String(format: "%.1f%%", conf * 100)) (낮음)"
            }
            reason += "\n더 특징적인 장소를 비추고 다시 시도하세요."
            setStatus(reason, color: .systemOrange)
            return
        }

        guard let matchedIndex = response.matchedImageIndex,
              matchedIndex >= 0, matchedIndex < capturedARPoses.count else {
            setLoading(false)
            setStatus("매칭된 이미지 인덱스 정보가 없습니다.\n다시 시도하세요.", color: .systemOrange)
            return
        }

        matchedARPose = capturedARPoses[matchedIndex]
        localizedPose = pose

        let confidence = response.confidence.map { String(format: "%.1f%%", $0 * 100) } ?? "?"
        let matches = response.numMatches.map { "\($0)개" } ?? "?"
        setStatus("위치 인식 성공 (이미지 #\(matchedIndex))\n신뢰도: \(confidence) | 매칭: \(matches)\n경로 계산 중...", color: .systemGreen)
        startPathfinding(pose: pose)
    }

    // MARK: - 경로 탐색

    private func startPathfinding(pose: Pose) {
        let request = PathfindingRequest(
            startFloorLevel: 1,
            startX: pose.x ?? 0.0,
            startY: pose.y ?? 0.0,
            startZ: pose.z ?? 0.0,
            destinationName: destinationName,
            preference: "SHORTEST"
        )

        NetworkManager.shared.findPath(buildingId: buildingId, requestDto: request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setLoading(false)
                switch result {
                case .success(let response):
                    let stepCount = response.steps?.count ?? 0
                    if stepCount > 0 {
                        self.setStatus("경로 탐색 완료 — \(stepCount)개 경유지\n초록 구체를 따라 이동하세요.", color: .systemGreen)
                        self.drawPathArrow(steps: response.steps ?? [])
                    } else {
                        self.setStatus("경로를 찾지 못했습니다.\n목적지명을 확인하세요.", color: .systemOrange)
                    }
                case .failure(let error):
                    self.setStatus("경로 탐색 실패:\n\(error.localizedDescription)", color: .systemRed)
                }
            }
        }
    }

    // MARK: - AR 경로 렌더링

    private func drawPathArrow(steps: [PathStep]) {
        sceneView.scene.rootNode.childNodes.filter { $0.name == "pathNode" }.forEach { $0.removeFromParentNode() }
        guard let arPose = matchedARPose, let pose = localizedPose else { return }

        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
                               iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1))

        let input = CoordinateTransformer.Input(
            serverPosition: serverPos,
            serverQuaternion: quat,
            arCameraPose: arPose
        )

        for step in steps {
            guard let pos = step.position else { continue }

            let serverPoint = simd_float3(Float(pos.x), Float(pos.y), Float(pos.z))
            let arPos = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)

            let node = createSphereNode()
            node.name = "pathNode"
            node.position = SCNVector3(arPos.x, arPos.y, arPos.z)
            sceneView.scene.rootNode.addChildNode(node)
        }
    }

    private func createSphereNode() -> SCNNode {
        let sphere = SCNSphere(radius: 0.2)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.8)
        sphere.materials = [material]
        return SCNNode(geometry: sphere)
    }
}
