import UIKit
import ARKit
import SceneKit

// MARK: - Delegate

protocol ARNavigationLogicDelegate: AnyObject {
    func updateStatus(_ message: String, color: UIColor)
    func setLoading(_ loading: Bool)
    func setCaptureProgress(text: String, isHidden: Bool)
    func setScanningOverlay(visible: Bool)
    func showScanComplete()
    func showScanFailed(message: String)
    func showArrivalNotification()
}

// MARK: - Logic

class ARNavigationLogic {

    weak var delegate: ARNavigationLogicDelegate?
    weak var arSession: ARSession?
    weak var scene: SCNScene?

    // MVP 용 테스트 파라미터
    let buildingId = "9853086b-ef02-4a95-b61a-072d11b16f34"
    let destinationName = "301호"

    // 다중 프레임 캡처
    let maxImages = 5
    let captureInterval: TimeInterval = 0.8
    private var matchedARPose: simd_float4x4?
    private var localizedPose: Pose?
    private var capturedImages: [UIImage] = []
    private var capturedARPoses: [simd_float4x4] = []
    private var captureTimer: Timer?

    // 목적지 도착 감지
    private var destinationARPosition: simd_float3?
    private var arrivalCheckTimer: Timer?
    private var hasNotifiedArrival = false
    private let arrivalThreshold: Float = 2.0  // 2m 이내 도착 판정

    // MARK: - 다중 프레임 캡처 후 Localize

    func startLocalizationFlow() {
        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        capturedImages = []
        capturedARPoses = []
        delegate?.setLoading(true)
        delegate?.setScanningOverlay(visible: true)
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
            delegate?.setScanningOverlay(visible: false)
            delegate?.showScanFailed(message: "촬영에 실패했어요.\n다시 한번 스캔해 주세요.")
            return
        }

        NetworkManager.shared.localize(buildingId: buildingId, images: capturedImages) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.delegate?.setScanningOverlay(visible: false)
                switch result {
                case .success(let response):
                    self.handleLocalizeSuccess(response: response)
                case .failure:
                    self.delegate?.setLoading(false)
                    self.delegate?.showScanFailed(message: "서버 연결에 실패했어요.\n다시 한번 스캔해 주세요.")
                }
            }
        }
    }

    private func handleLocalizeSuccess(response: LocalizeResponse) {
        guard let pose = response.pose, pose.x != nil else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치를 인식하지 못했어요.\n주변을 비추며 다시 스캔해 주세요.")
            return
        }

        guard let matchedIndex = response.matchedImageIndex,
              matchedIndex >= 0, matchedIndex < capturedARPoses.count else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치를 인식하지 못했어요.\n다시 한번 스캔해 주세요.")
            return
        }

        matchedARPose = capturedARPoses[matchedIndex]
        localizedPose = pose

        delegate?.showScanComplete()
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
                        self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                        self.drawPathNodes(steps: response.steps ?? [])
                    } else {
                        self.delegate?.showScanFailed(message: "경로를 찾지 못했어요.\n다시 한번 스캔해 주세요.")
                    }
                case .failure:
                    self.delegate?.showScanFailed(message: "경로 탐색에 실패했어요.\n다시 한번 스캔해 주세요.")
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

        // 카메라 높이에서 바닥 레벨 추정 (스마트폰 들고 있는 높이 ~1.3m)
        let cameraY = arPose.columns.3.y
        let floorY = cameraY - 1.3

        // 서버 좌표를 AR 좌표로 변환 후 Y를 바닥 레벨로 고정
        var arPoints: [simd_float3] = []
        for step in steps {
            guard let pos = step.position else { continue }
            let serverPoint = simd_float3(Float(pos.x), Float(pos.y), Float(pos.z))
            let arPos = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            arPoints.append(simd_float3(arPos.x, floorY, arPos.z))
        }

        guard arPoints.count >= 2 else { return }

        // 바닥 경로 세그먼트 그리기 (단일 불투명 레이어로)
        for i in 0..<(arPoints.count - 1) {
            let segmentNode = createPathSegment(from: arPoints[i], to: arPoints[i + 1])
            scene?.rootNode.addChildNode(segmentNode)
        }

        // ~5m 간격으로 방향 화살표 배치
        placeDirectionArrows(along: arPoints)

        // 목적지에 빨간 3D 핀 마커 배치
        if let lastPoint = arPoints.last {
            let pinNode = createDestinationPin(at: lastPoint)
            scene?.rootNode.addChildNode(pinNode)
            destinationARPosition = lastPoint
            startArrivalCheck()
        }
    }

    // MARK: - 바닥 경로

    /// 두 점 사이에 흰색 반투명 바닥 경로 세그먼트 생성
    private func createPathSegment(from: simd_float3, to: simd_float3) -> SCNNode {
        let direction = to - from
        let distance = simd_length(direction)
        guard distance > 0.01 else { return SCNNode() }

        let pathWidth: CGFloat = 0.8
        // cornerRadius 없이 깔끔한 직사각형
        let plane = SCNPlane(width: pathWidth, height: CGFloat(distance) + 0.05)

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.6)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.blendMode = .replace  // 중첩 시 투명도 누적 방지
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.name = "pathNode"
        node.renderingOrder = -1

        // 중간 지점에 배치, 바닥 살짝 위
        let mid = (from + to) / 2
        node.position = SCNVector3(mid.x, mid.y + 0.02, mid.z)

        // XY 평면 → XZ 평면 (바닥에 눕히기)
        node.eulerAngles.x = -.pi / 2

        // 경로 방향으로 회전
        let angle = atan2(direction.x, direction.z) - .pi
        node.eulerAngles.y = angle

        return node
    }

    // MARK: - 방향 화살표

    /// 경로를 따라 ~5m 간격으로 하늘색 쉐브론 화살표 배치
    private func placeDirectionArrows(along points: [simd_float3]) {
        guard points.count >= 2 else { return }

        let arrowInterval: Float = 5.0
        var accumulatedDistance: Float = 0

        // 시작 지점 근처에 첫 화살표
        let firstDir = simd_normalize(points[1] - points[0])
        let firstOffset = min(2.0, simd_length(points[1] - points[0]) * 0.3)
        let firstPos = points[0] + firstDir * firstOffset
        let firstArrow = createChevronNode(at: firstPos, direction: firstDir)
        scene?.rootNode.addChildNode(firstArrow)

        for i in 0..<(points.count - 1) {
            let segmentVec = points[i + 1] - points[i]
            let segmentLength = simd_length(segmentVec)
            guard segmentLength > 0.01 else { continue }

            let segmentDir = simd_normalize(segmentVec)
            var distInSegment = arrowInterval - accumulatedDistance

            while distInSegment < segmentLength {
                let pos = points[i] + segmentDir * distInSegment
                let arrow = createChevronNode(at: pos, direction: segmentDir)
                scene?.rootNode.addChildNode(arrow)
                distInSegment += arrowInterval
            }

            accumulatedDistance = (accumulatedDistance + segmentLength)
                .truncatingRemainder(dividingBy: arrowInterval)
        }
    }

    /// 단일 셰브론(>) 형태의 UIBezierPath 생성
    /// +X 방향(오른쪽)을 가리키는 ">" 모양, 중심 원점 기준
    private func makeChevronPath() -> UIBezierPath {
        let path = UIBezierPath()
        let tipX: CGFloat = 0.15      // 셰브론 꼭짓점 X
        let armY: CGFloat = 0.20      // 팔 끝 Y (위아래), 전체 높이 ~0.4m
        let thickness: CGFloat = 0.07  // 셰브론 선 두께

        // ">" 모양 (바깥 → 안쪽 순서로 그림)
        path.move(to: CGPoint(x: tipX, y: 0))                          // 꼭짓점 (오른쪽 끝)
        path.addLine(to: CGPoint(x: -tipX, y: armY))                   // 왼쪽 위
        path.addLine(to: CGPoint(x: -tipX + thickness, y: armY))       // 안쪽 왼쪽 위
        path.addLine(to: CGPoint(x: tipX - thickness, y: 0))           // 안쪽 꼭짓점
        path.addLine(to: CGPoint(x: -tipX + thickness, y: -armY))      // 안쪽 왼쪽 아래
        path.addLine(to: CGPoint(x: -tipX, y: -armY))                  // 왼쪽 아래
        path.close()

        return path
    }

    // MARK: - 목적지 3D 핀 마커

    /// 빨간색 3D 지도 핀 마커 생성 (구 + 원뿔)
    private func createDestinationPin(at position: simd_float3) -> SCNNode {
        let node = SCNNode()
        node.name = "pathNode"

        // 빨간 구 (핀 머리)
        let sphere = SCNSphere(radius: 0.25)
        let sphereMaterial = SCNMaterial()
        sphereMaterial.diffuse.contents = UIColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 1.0)
        sphereMaterial.emission.contents = UIColor(red: 0.3, green: 0.05, blue: 0.05, alpha: 1.0)
        sphereMaterial.lightingModel = .physicallyBased
        sphereMaterial.roughness.contents = 0.3
        sphereMaterial.metalness.contents = 0.1
        sphere.materials = [sphereMaterial]

        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.position = SCNVector3(0, 0.65, 0)

        // 빨간 원뿔 (핀 꼬리)
        let cone = SCNCone(topRadius: 0.18, bottomRadius: 0.005, height: 0.45)
        let coneMaterial = SCNMaterial()
        coneMaterial.diffuse.contents = UIColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1.0)
        coneMaterial.emission.contents = UIColor(red: 0.25, green: 0.04, blue: 0.04, alpha: 1.0)
        coneMaterial.lightingModel = .physicallyBased
        coneMaterial.roughness.contents = 0.3
        coneMaterial.metalness.contents = 0.1
        cone.materials = [coneMaterial]

        let coneNode = SCNNode(geometry: cone)
        coneNode.position = SCNVector3(0, 0.2, 0)

        // 흰색 원 (핀 내부 표시)
        let innerCircle = SCNSphere(radius: 0.12)
        let innerMaterial = SCNMaterial()
        innerMaterial.diffuse.contents = UIColor(red: 0.6, green: 0.08, blue: 0.08, alpha: 1.0)
        innerMaterial.emission.contents = UIColor(red: 0.2, green: 0.02, blue: 0.02, alpha: 1.0)
        innerCircle.materials = [innerMaterial]

        let innerNode = SCNNode(geometry: innerCircle)
        innerNode.position = SCNVector3(0, 0.65, 0)

        node.addChildNode(coneNode)
        node.addChildNode(sphereNode)
        node.addChildNode(innerNode)

        node.position = SCNVector3(position.x, position.y + 0.3, position.z)

        // 떠다니는 애니메이션
        let hover = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0.15, z: 0, duration: 0.8),
            SCNAction.moveBy(x: 0, y: -0.15, z: 0, duration: 0.8)
        ])
        hover.timingMode = .easeInEaseOut
        node.runAction(SCNAction.repeatForever(hover))

        return node
    }

    // MARK: - 목적지 도착 감지

    private func startArrivalCheck() {
        hasNotifiedArrival = false
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkArrival()
        }
    }

    private func checkArrival() {
        guard !hasNotifiedArrival,
              let destination = destinationARPosition,
              let frame = arSession?.currentFrame else { return }

        let cameraPos = simd_float3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        // Y축 무시, XZ 평면 거리만 계산
        let dx = cameraPos.x - destination.x
        let dz = cameraPos.z - destination.z
        let distance = sqrt(dx * dx + dz * dz)

        if distance < arrivalThreshold {
            hasNotifiedArrival = true
            arrivalCheckTimer?.invalidate()
            arrivalCheckTimer = nil
            DispatchQueue.main.async {
                self.delegate?.showArrivalNotification()
            }
        }
    }

    func stopArrivalCheck() {
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
    }

    /// 더블 셰브론(>>) 3D 노드 생성
    /// - 바닥에서 0.5m 위에 세워서 배치
    /// - 정면(사용자 쪽)에서 ">>" 모양이 보임
    /// - 15° 뒤로 기울여 수평 시야에서도 잘 보임
    /// - 진행 방향을 정확히 가리킴
    private func createChevronNode(at position: simd_float3, direction: simd_float3) -> SCNNode {
        let node = SCNNode()
        node.name = "pathNode"

        // 바닥에서 0.5m 위
        node.position = SCNVector3(position.x, position.y + 0.5, position.z)

        // 셰브론 공통 재질
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.3, green: 0.65, blue: 1.0, alpha: 1.0)
        material.emission.contents = UIColor(red: 0.15, green: 0.35, blue: 0.7, alpha: 1.0)
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.25
        material.metalness.contents = 0.1

        // 더블 셰브론: 두 개의 ">"를 진행 방향으로 나란히 배치
        let chevronSpacing: Float = 0.18  // 두 셰브론 사이 간격
        for i in 0..<2 {
            let chevronPath = makeChevronPath()
            let shape = SCNShape(path: chevronPath, extrusionDepth: 0.06)  // 옆에서 보이는 두께
            shape.materials = [material]

            let shapeNode = SCNNode(geometry: shape)

            // SCNShape는 XY 평면에 생성, 팁이 +X 방향
            // Y축 +90° 회전 → 팁이 -Z 방향(부모 노드의 진행 방향)으로 향함
            shapeNode.eulerAngles.y = .pi / 2
            // X축 +15° 회전 → 상단이 사용자 쪽으로 살짝 기울어짐 (수평 시야 가시성)
            shapeNode.eulerAngles.x = 0.26  // ~15°

            // 두 셰브론을 진행 방향(-Z)으로 나란히 배치
            // i=0: 뒤쪽(사용자에 가까운 쪽), i=1: 앞쪽(목적지에 가까운 쪽)
            let offset = Float(i) * chevronSpacing
            shapeNode.position = SCNVector3(0, 0, -offset)

            node.addChildNode(shapeNode)
        }

        // 부모 노드를 진행 방향으로 회전
        // SceneKit 기본 정면 = -Z, 이를 direction 방향으로 회전
        let angle = atan2(-direction.x, -direction.z)
        node.eulerAngles.y = angle

        // 부드러운 펄스 애니메이션
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.05, duration: 0.7),
            SCNAction.scale(to: 0.95, duration: 0.7)
        ])
        pulse.timingMode = .easeInEaseOut
        node.runAction(SCNAction.repeatForever(pulse))

        return node
    }
}
