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

    let buildingId: String
    let destinationName: String

    init(buildingId: String, destinationName: String) {
        self.buildingId = buildingId
        self.destinationName = destinationName
    }

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

        // Catmull-Rom 스플라인으로 부드러운 경로 생성
        let smoothPoints = catmullRomSpline(points: arPoints, subdivisions: 20)

        // 연속 메시 리본으로 바닥 경로 그리기
        let pathNode = createContinuousPath(points: smoothPoints)
        scene?.rootNode.addChildNode(pathNode)

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

    // MARK: - 바닥 경로 (연속 메시 리본)

    /// 포인트 배열로 하나의 연속된 삼각형 스트립 메시를 생성
    /// 개별 사각형 대신 연속 리본으로 커브에서 매끄럽게 연결됨
    private func createContinuousPath(points: [simd_float3]) -> SCNNode {
        guard points.count >= 2 else { return SCNNode() }

        let halfWidth: Float = 0.4  // 경로 폭 0.8m의 절반
        let yOffset: Float = 0.02   // 바닥 살짝 위

        // 각 포인트에서 좌/우 정점 생성
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texCoords: [CGPoint] = []

        for i in 0..<points.count {
            let p = points[i]

            // 진행 방향 계산 (XZ 평면)
            let forward: simd_float2
            if i == 0 {
                forward = simd_normalize(simd_float2(points[1].x - p.x, points[1].z - p.z))
            } else if i == points.count - 1 {
                forward = simd_normalize(simd_float2(p.x - points[i-1].x, p.z - points[i-1].z))
            } else {
                // 앞뒤 방향의 평균 → 코너에서 부드러운 전환
                let fwd1 = simd_normalize(simd_float2(p.x - points[i-1].x, p.z - points[i-1].z))
                let fwd2 = simd_normalize(simd_float2(points[i+1].x - p.x, points[i+1].z - p.z))
                let avg = fwd1 + fwd2
                let len = simd_length(avg)
                if len > 0.001 {
                    forward = avg / len
                } else {
                    // 180도 급회전 시 수직 방향 사용
                    forward = simd_float2(-fwd1.y, fwd1.x)
                }
            }

            // 수직 방향 (XZ 평면에서 왼쪽) = (-forwardZ, forwardX)
            let perp = simd_float2(-forward.y, forward.x)

            // Miter 제한: 급격한 코너에서 정점이 튀어나가지 않도록
            // 앞뒤 방향이 많이 다르면 폭을 줄임
            var adjustedHalfWidth = halfWidth
            if i > 0 && i < points.count - 1 {
                let fwd1 = simd_normalize(simd_float2(p.x - points[i-1].x, p.z - points[i-1].z))
                let fwd2 = simd_normalize(simd_float2(points[i+1].x - p.x, points[i+1].z - p.z))
                let dotProduct = simd_dot(fwd1, fwd2)
                // dotProduct: 1.0(직선) → -1.0(180도 회전)
                // 급회전일수록 폭을 줄여서 삐져나감 방지
                let miterScale = max(0.5, (1.0 + dotProduct) / 2.0)
                adjustedHalfWidth = halfWidth * Float(miterScale)
            }

            // 좌/우 정점
            let left  = SCNVector3(p.x + perp.x * adjustedHalfWidth, p.y + yOffset, p.z + perp.y * adjustedHalfWidth)
            let right = SCNVector3(p.x - perp.x * adjustedHalfWidth, p.y + yOffset, p.z - perp.y * adjustedHalfWidth)

            vertices.append(left)
            vertices.append(right)
            normals.append(SCNVector3(0, 1, 0))
            normals.append(SCNVector3(0, 1, 0))

            let t = CGFloat(i) / CGFloat(points.count - 1)
            texCoords.append(CGPoint(x: 0, y: t))
            texCoords.append(CGPoint(x: 1, y: t))
        }

        // 삼각형 인덱스 (연속 쿼드 → 삼각형 2개씩)
        var indices: [UInt32] = []
        for i in 0..<(points.count - 1) {
            let base = UInt32(i * 2)
            // 삼각형 1: left[i], right[i], left[i+1]
            indices.append(contentsOf: [base, base + 1, base + 2])
            // 삼각형 2: right[i], right[i+1], left[i+1]
            indices.append(contentsOf: [base + 1, base + 3, base + 2])
        }

        // SCNGeometry 생성
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let texSource = SCNGeometrySource(textureCoordinates: texCoords)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, texSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.9)
        material.emission.contents = UIColor.white.withAlphaComponent(0.3)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.lightingModel = .constant
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "pathNode"
        node.renderingOrder = -1

        return node
    }

    // MARK: - Catmull-Rom 스플라인 보간

    /// 포인트 배열을 Catmull-Rom 스플라인으로 부드럽게 보간
    private func catmullRomSpline(points: [simd_float3], subdivisions: Int) -> [simd_float3] {
        guard points.count >= 2 else { return points }
        if points.count == 2 { return points }

        var result: [simd_float3] = []

        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]

            for j in 0..<subdivisions {
                let t = Float(j) / Float(subdivisions)
                let t2 = t * t
                let t3 = t2 * t

                let x = 0.5 * ((2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                    (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)

                let y = p1.y  // Y(높이)는 바닥 레벨 유지

                let z = 0.5 * ((2 * p1.z) +
                    (-p0.z + p2.z) * t +
                    (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2 +
                    (-p0.z + 3 * p1.z - 3 * p2.z + p3.z) * t3)

                result.append(simd_float3(x, y, z))
            }
        }

        result.append(points.last!)
        return result
    }

    // MARK: - 방향 화살표

    /// 경로를 따라 ~5m 간격으로 하늘색 쉐브론 화살표 배치
    /// 경로 가장자리(왼쪽)에 배치하여 바닥 경로와 겹치지 않도록 함
    private func placeDirectionArrows(along points: [simd_float3]) {
        guard points.count >= 2 else { return }

        let arrowInterval: Float = 5.0
        let edgeOffset: Float = 0.45  // 경로 중심에서 가장자리까지 오프셋
        var accumulatedDistance: Float = 0

        // 시작 지점 근처에 첫 화살표
        let firstDir = simd_normalize(points[1] - points[0])
        let firstOffset = min(2.0, simd_length(points[1] - points[0]) * 0.3)
        let firstPos = points[0] + firstDir * firstOffset
        let firstEdgePos = offsetToEdge(position: firstPos, direction: firstDir, offset: edgeOffset)
        let firstArrow = createChevronNode(at: firstEdgePos, direction: firstDir)
        scene?.rootNode.addChildNode(firstArrow)

        for i in 0..<(points.count - 1) {
            let segmentVec = points[i + 1] - points[i]
            let segmentLength = simd_length(segmentVec)
            guard segmentLength > 0.01 else { continue }

            let segmentDir = simd_normalize(segmentVec)
            var distInSegment = arrowInterval - accumulatedDistance

            while distInSegment < segmentLength {
                let pos = points[i] + segmentDir * distInSegment
                let edgePos = offsetToEdge(position: pos, direction: segmentDir, offset: edgeOffset)
                let arrow = createChevronNode(at: edgePos, direction: segmentDir)
                scene?.rootNode.addChildNode(arrow)
                distInSegment += arrowInterval
            }

            accumulatedDistance = (accumulatedDistance + segmentLength)
                .truncatingRemainder(dividingBy: arrowInterval)
        }
    }

    /// 경로 중심 위치를 진행 방향의 왼쪽 가장자리로 오프셋
    private func offsetToEdge(position: simd_float3, direction: simd_float3, offset: Float) -> simd_float3 {
        // XZ 평면에서 왼쪽 수직 방향: (-dz, dx)
        let left = simd_float3(-direction.z, 0, direction.x)
        return position + left * offset
    }

    /// 단일 셰브론(>) 노드 생성 — SCNBox 2개로 ">" 형태 조립
    /// SCNShape 대신 SCNBox 사용으로 확실한 렌더링 보장
    private func makeSingleChevron(material: SCNMaterial) -> SCNNode {
        let chevron = SCNNode()

        let armLength: CGFloat = 0.28   // 팔 길이
        let armWidth: CGFloat = 0.10    // 팔 두께 (두껍게)
        let armDepth: CGFloat = 0.08    // 앞뒤 깊이 (두께감)
        let halfAngle: Float = .pi / 5  // 36도 ("> " 벌어진 각도)

        // 위쪽 팔 ╲
        let upperArm = SCNBox(width: armLength, height: armWidth, length: armDepth, chamferRadius: 0.01)
        upperArm.materials = [material]
        let upperNode = SCNNode(geometry: upperArm)
        upperNode.position = SCNVector3(-Float(armLength) / 2 * cos(halfAngle),
                                         Float(armLength) / 2 * sin(halfAngle), 0)
        upperNode.eulerAngles.z = halfAngle

        // 아래쪽 팔 ╱
        let lowerArm = SCNBox(width: armLength, height: armWidth, length: armDepth, chamferRadius: 0.01)
        lowerArm.materials = [material]
        let lowerNode = SCNNode(geometry: lowerArm)
        lowerNode.position = SCNVector3(-Float(armLength) / 2 * cos(halfAngle),
                                        -Float(armLength) / 2 * sin(halfAngle), 0)
        lowerNode.eulerAngles.z = -halfAngle

        chevron.addChildNode(upperNode)
        chevron.addChildNode(lowerNode)
        return chevron
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

    /// 더블 셰브론(>>) 3D 노드 생성 — SCNBox 기반으로 확실한 렌더링
    /// - 바닥에서 0.5m 위에 세워서 배치
    /// - 두 개의 ">"를 나란히 배치하여 ">>" 형태
    /// - 진행 방향을 정확히 가리킴
    private func createChevronNode(at position: simd_float3, direction: simd_float3) -> SCNNode {
        let node = SCNNode()
        node.name = "pathNode"

        // 바닥에서 0.85m 위 (허리~가슴 높이로 잘 보임)
        node.position = SCNVector3(position.x, position.y + 0.85, position.z)

        // 셰브론 공통 재질 — PBR로 입체감 + 자체 발광으로 가시성 확보
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1.0)
        material.emission.contents = UIColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1.0)
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.35
        material.metalness.contents = 0.15
        material.isDoubleSided = true

        // 더블 셰브론: 두 개의 ">"를 진행 방향(+X)으로 나란히 배치
        let chevronSpacing: Float = 0.22
        for i in 0..<2 {
            let chevronChild = makeSingleChevron(material: material)
            // i=0: 뒤쪽(사용자에 가까운 쪽), i=1: 앞쪽(목적지에 가까운 쪽)
            chevronChild.position = SCNVector3(Float(i) * chevronSpacing, 0, 0)
            node.addChildNode(chevronChild)
        }

        // 쿼터니언으로 회전 합성 (euler angles 간섭 방지)
        // 1) 방향 회전: ">" 팁(+X)을 진행 방향으로
        let angle = atan2(direction.z, -direction.x)
        let dirQuat = simd_quatf(angle: angle, axis: simd_float3(0, 1, 0))
        // 2) 15도 기울기: 로컬 Z축 기준으로 상단이 진행 방향으로 기울어짐
        let tiltQuat = simd_quatf(angle: -0.26, axis: simd_float3(0, 0, 1))
        // 방향 회전 후 기울기 적용
        node.simdOrientation = dirQuat * tiltQuat

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
