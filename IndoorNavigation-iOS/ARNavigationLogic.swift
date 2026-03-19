import UIKit
import ARKit
import SceneKit

// MARK: - Delegate

protocol ARNavigationLogicDelegate: AnyObject {
    func updateStatus(_ message: String, color: UIColor)
    func setLoading(_ loading: Bool)
    func setCaptureProgress(text: String, isHidden: Bool)
}

// MARK: - Logic

class ARNavigationLogic {

    weak var delegate: ARNavigationLogicDelegate?
    weak var arSession: ARSession?
    weak var scene: SCNScene?

    // MVP 용 테스트 파라미터
    let buildingId = "a6bbfe0b-8d05-4cde-82fc-7541f75f5954"
    let destinationName = "301호"

    // 다중 프레임 캡처
    let maxImages = 5
    let captureInterval: TimeInterval = 0.8

    private var matchedARPose: simd_float4x4?
    private var localizedPose: Pose?
    private var capturedImages: [UIImage] = []
    private var capturedARPoses: [simd_float4x4] = []
    private var captureTimer: Timer?

    // MARK: - 다중 프레임 캡처 후 Localize

    func startLocalizationFlow() {
        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        capturedImages = []
        capturedARPoses = []
        delegate?.setLoading(true)
        delegate?.updateStatus("천천히 주변을 둘러보세요\n사진을 \(maxImages)장 촬영합니다.", color: .white)
        delegate?.setCaptureProgress(text: "", isHidden: false)

        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureOneFrame()
        }
    }

    private func captureOneFrame() {
        guard let frame = arSession?.currentFrame else { return }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

        capturedImages.append(uiImage)
        capturedARPoses.append(frame.camera.transform)

        let count = capturedImages.count
        delegate?.setCaptureProgress(text: "\(count)/\(maxImages)", isHidden: false)

        if count >= maxImages {
            stopCapture()
            sendToServer()
        }
    }

    func stopCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        delegate?.setCaptureProgress(text: "", isHidden: true)
    }

    private func sendToServer() {
        guard !capturedImages.isEmpty else {
            delegate?.setLoading(false)
            delegate?.updateStatus("캡처 실패. 다시 시도하세요.", color: .systemRed)
            return
        }

        delegate?.updateStatus("서버에 \(capturedImages.count)장 전송 중...", color: .white)

        NetworkManager.shared.localize(buildingId: buildingId, images: capturedImages) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let response):
                    self.handleLocalizeSuccess(response: response)
                case .failure(let error):
                    self.delegate?.setLoading(false)
                    self.delegate?.updateStatus("서버 연결 실패:\n\(error.localizedDescription)", color: .systemRed)
                }
            }
        }
    }

    private func handleLocalizeSuccess(response: LocalizeResponse) {
        guard let pose = response.pose, pose.x != nil else {
            delegate?.setLoading(false)
            var reason = "위치를 특정하지 못했습니다."
            if let matches = response.numMatches {
                reason += "\n매칭 특징점: \(matches)개 (부족)"
            }
            if let conf = response.confidence {
                reason += "\n신뢰도: \(String(format: "%.1f%%", conf * 100)) (낮음)"
            }
            reason += "\n더 특징적인 장소를 비추고 다시 시도하세요."
            delegate?.updateStatus(reason, color: .systemOrange)
            return
        }

        guard let matchedIndex = response.matchedImageIndex,
              matchedIndex >= 0, matchedIndex < capturedARPoses.count else {
            delegate?.setLoading(false)
            delegate?.updateStatus("매칭된 이미지 인덱스 정보가 없습니다.\n다시 시도하세요.", color: .systemOrange)
            return
        }

        matchedARPose = capturedARPoses[matchedIndex]
        localizedPose = pose

        let confidence = response.confidence.map { String(format: "%.1f%%", $0 * 100) } ?? "?"
        let matches = response.numMatches.map { "\($0)개" } ?? "?"
        delegate?.updateStatus("위치 인식 성공 (이미지 #\(matchedIndex))\n신뢰도: \(confidence) | 매칭: \(matches)\n경로 계산 중...", color: .systemGreen)
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
                self.delegate?.setLoading(false)
                switch result {
                case .success(let response):
                    let stepCount = response.steps?.count ?? 0
                    if stepCount > 0 {
                        self.delegate?.updateStatus("경로 탐색 완료 — \(stepCount)개 경유지\n초록 구체를 따라 이동하세요.", color: .systemGreen)
                        self.drawPathNodes(steps: response.steps ?? [])
                    } else {
                        self.delegate?.updateStatus("경로를 찾지 못했습니다.\n목적지명을 확인하세요.", color: .systemOrange)
                    }
                case .failure(let error):
                    self.delegate?.updateStatus("경로 탐색 실패:\n\(error.localizedDescription)", color: .systemRed)
                }
            }
        }
    }

    // MARK: - AR 경로 렌더링

    private func drawPathNodes(steps: [PathStep]) {
        scene?.rootNode.childNodes.filter { $0.name == "pathNode" }.forEach { $0.removeFromParentNode() }
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

            let node = makeSphereNode()
            node.name = "pathNode"
            node.position = SCNVector3(arPos.x, arPos.y, arPos.z)
            scene?.rootNode.addChildNode(node)
        }
    }

    private func makeSphereNode() -> SCNNode {
        let sphere = SCNSphere(radius: 0.2)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.8)
        sphere.materials = [material]
        return SCNNode(geometry: sphere)
    }
}
