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
    func updateHUD(destinationName: String, remainingDistance: Float, instruction: String?)
    func setHUDVisible(_ visible: Bool)
    func setLocateButtonVisible(_ visible: Bool)
    func showRouteCalculating(_ visible: Bool)
}

// MARK: - Logic

class ARNavigationLogic {

    // MARK: - Mock Mode (서버 미가용 시 UI 점검용)
    // FIXME: 서버 복구 후 false로 전환
    static let useMockData: Bool = true

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

    // 경로 진행 추적 상태
    private var pathRootNode: SCNNode?
    private var allSteps: [PathStep] = []
    private var allARPoints: [simd_float3] = []
    private var smoothedPoints: [simd_float3] = []
    private var allChevronNodes: [(node: SCNNode, pointIndex: Int)] = []
    private var currentTargetWaypointIndex: Int = 0
    private var lastWindowUpdatePosition: simd_float3?
    private var pathProgressTimer: Timer?
    private let waypointSwitchThreshold: Float = 0.8
    private let renderWindowDistance: Float = 30.0
    private let windowUpdateMoveDelta: Float = 1.0

    // MARK: - 다중 프레임 캡처 후 Localize

    func startLocalizationFlow() {
        if Self.useMockData {
            runMockFlow()
            return
        }

        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        // 직전 시도 잔여 상태 정리 (재진입 안전성)
        pathRootNode?.removeFromParentNode()
        pathRootNode = nil
        allChevronNodes.removeAll()
        lastWindowUpdatePosition = nil
        allSteps = []
        allARPoints = []
        smoothedPoints = []
        currentTargetWaypointIndex = 0
        matchedARPose = nil
        localizedPose = nil
        destinationARPosition = nil

        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
        hasNotifiedArrival = false

        capturedImages = []
        capturedARPoses = []
        delegate?.setLocateButtonVisible(false)
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
            delegate?.setLocateButtonVisible(true)
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
                    self.delegate?.setLocateButtonVisible(true)
                }
            }
        }
    }

    private func handleLocalizeSuccess(response: LocalizeResponse) {
        guard let pose = response.pose, pose.x != nil else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치를 인식하지 못했어요.\n주변을 비추며 다시 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        guard let matchedIndex = response.matchedImageIndex,
              matchedIndex >= 0, matchedIndex < capturedARPoses.count else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치를 인식하지 못했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        matchedARPose = capturedARPoses[matchedIndex]
        localizedPose = pose

        delegate?.showScanComplete()
        delegate?.showRouteCalculating(true)
        startPathfinding(pose: pose)
    }

    // MARK: - 경로 탐색

    private func startPathfinding(pose: Pose) {
        let request = PathfindingRequest(
            // TODO: Phase 3에서 서버가 매칭된 floorLevel 반환 시 동적 설정
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
                self.delegate?.showRouteCalculating(false)
                switch result {
                case .success(let response):
                    let stepCount = response.steps?.count ?? 0
                    if stepCount > 0 {
                        self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                        self.drawPathNodes(steps: response.steps ?? [])
                    } else {
                        self.delegate?.showScanFailed(message: "경로를 찾지 못했어요.\n다시 한번 스캔해 주세요.")
                        self.delegate?.setLocateButtonVisible(true)
                    }
                case .failure:
                    self.delegate?.showScanFailed(message: "경로 탐색에 실패했어요.\n다시 한번 스캔해 주세요.")
                    self.delegate?.setLocateButtonVisible(true)
                }
            }
        }
    }

    // MARK: - AR 경로 렌더링

    private func drawPathNodes(steps: [PathStep]) {
        // 기존 경로 정리
        pathRootNode?.removeFromParentNode()
        pathRootNode = nil
        allChevronNodes.removeAll()

        guard let arPose = matchedARPose, let pose = localizedPose else { return }

        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
                               iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1))

        let input = CoordinateTransformer.Input(
            serverPosition: serverPos,
            serverQuaternion: quat,
            arCameraPose: arPose
        )

        // 카메라 높이에서 바닥 레벨 추정 (스마트폰 들고 있는 높이 ~1.5m)
        let cameraY = arPose.columns.3.y
        let floorY = cameraY - 1.5

        // 서버 좌표를 AR 좌표로 변환 후 Y를 바닥 레벨로 고정
        var arPoints: [simd_float3] = []
        for step in steps {
            guard let pos = step.position else { continue }
            let serverPoint = simd_float3(Float(pos.x), Float(pos.y), Float(pos.z))
            let arPos = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            arPoints.append(simd_float3(arPos.x, floorY, arPos.z))
        }

        guard arPoints.count >= 2 else {
            delegate?.showScanFailed(message: "경로 정보가 비어 있어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // Catmull-Rom 스플라인으로 부드러운 경로 생성
        let smoothPoints = catmullRomSpline(points: arPoints, subdivisions: 20)

        // 상태 보관
        allSteps = steps
        allARPoints = arPoints
        smoothedPoints = smoothPoints

        // 경로 부모 노드 생성
        let rootNode = SCNNode()
        rootNode.name = "pathRootNode"
        rootNode.renderingOrder = -1
        scene?.rootNode.addChildNode(rootNode)
        pathRootNode = rootNode

        let cameraPos = simd_float3(arPose.columns.3.x, arPose.columns.3.y, arPose.columns.3.z)
        currentTargetWaypointIndex = 1
        lastWindowUpdatePosition = cameraPos

        // 30m 슬라이딩 윈도우 초기 렌더링
        updateRibbonWindow(cameraPos: cameraPos)

        // 경로 구간별 더블 쉐브론 화살표 배치
        placeChevronArrows(on: smoothPoints, steps: steps, rootNode: rootNode)

        // 목적지에 빨간 3D 핀 마커 배치
        if let lastPoint = arPoints.last {
            let pinNode = createDestinationPin(at: lastPoint)
            rootNode.addChildNode(pinNode)
            destinationARPosition = lastPoint
            startArrivalCheck()
        }

        // 진행 추적 시작 + HUD 표시
        startPathProgressTracking()
        delegate?.setHUDVisible(true)
        delegate?.setLocateButtonVisible(false)
    }

    // MARK: - 연속 바닥 경로 Ribbon

    private func buildRibbonNode(points: [simd_float3]) -> SCNNode {
        let container = SCNNode()
        container.name = "ribbonContainer"

        guard points.count >= 2 else { return container }

        // --- 연속 ribbon geometry ---
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []

        let stripWidth: Float = 0.8
        let yOffset: Float = 0.003

        for (i, point) in points.enumerated() {
            let prev = i > 0 ? points[i - 1] : points[i]
            let next = i < points.count - 1 ? points[i + 1] : points[i]

            var tx = next.x - prev.x
            var tz = next.z - prev.z
            let tLen = sqrt(tx * tx + tz * tz)
            if tLen > 0.0001 { tx /= tLen; tz /= tLen }

            // 수직(perp) 벡터: 진행 방향의 90° 회전
            let px: Float = -tz
            let pz: Float = tx
            let half = stripWidth / 2
            let y = point.y + yOffset

            vertices.append(SCNVector3(point.x - px * half, y, point.z - pz * half))
            vertices.append(SCNVector3(point.x + px * half, y, point.z + pz * half))
            normals.append(SCNVector3(0, 1, 0))
            normals.append(SCNVector3(0, 1, 0))

            if i > 0 {
                let base = Int32((i - 1) * 2)
                indices.append(contentsOf: [base, base + 2, base + 1,
                                            base + 1, base + 2, base + 3])
            }
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])

        let ribbonMaterial = SCNMaterial()
        ribbonMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.55)
        ribbonMaterial.lightingModel = .constant
        ribbonMaterial.writesToDepthBuffer = false
        ribbonMaterial.readsFromDepthBuffer = true   // 쉐브론이 ribbon 위에 정상 렌더링
        ribbonMaterial.isDoubleSided = true
        geometry.materials = [ribbonMaterial]

        let ribbonNode = SCNNode(geometry: geometry)
        ribbonNode.name = "ribbonNode"
        container.addChildNode(ribbonNode)

        // --- 방향 삼각형: arc-length 0.6m 간격 ---
        let triangleSpacing: Float = 0.6
        let triangleMaterial = SCNMaterial()
        triangleMaterial.diffuse.contents = UIColor.white
        triangleMaterial.lightingModel = .constant
        triangleMaterial.writesToDepthBuffer = false
        triangleMaterial.readsFromDepthBuffer = false
        triangleMaterial.isDoubleSided = true

        var coveredDist: Float = 0
        var nextPlace: Float = triangleSpacing / 2

        for i in 1..<points.count {
            let p1 = points[i - 1]
            let p2 = points[i]
            let ddx = p2.x - p1.x
            let ddz = p2.z - p1.z
            let segLen = sqrt(ddx * ddx + ddz * ddz)
            guard segLen > 0.0001 else { continue }

            while coveredDist + segLen >= nextPlace {
                let t = (nextPlace - coveredDist) / segLen
                let tx = p1.x + t * ddx
                let tz = p1.z + t * ddz
                let ty = p1.y + 0.006

                let pyramid = SCNPyramid(width: 0.25, height: 0.01, length: 0.35)
                pyramid.materials = [triangleMaterial]
                let triNode = SCNNode(geometry: pyramid)
                triNode.position = SCNVector3(tx, ty, tz)
                triNode.simdOrientation = simd_quatf(angle: atan2(ddx / segLen, ddz / segLen),
                                                      axis: simd_float3(0, 1, 0))
                container.addChildNode(triNode)
                nextPlace += triangleSpacing
            }

            coveredDist += segLen
        }

        return container
    }

    // MARK: - 더블 쉐브론 화살표

    private func createChevronNode() -> SCNNode {
        let node = SCNNode()
        node.name = "chevronArrow"

        let bobNode = SCNNode()
        node.addChildNode(bobNode)

        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)
        mat.lightingModel = .constant
        mat.isDoubleSided = true

        // ">>" shape in local XY plane (vertical sign); face normal = local Z.
        // Tip is at +X (local). placeChevronArrows aligns local +X to travel direction
        // via yaw, then applies a small pitch (~20°) around the world-horizontal axis
        // perpendicular to travel for sign-board visibility.
        let halfW: Float = 0.22
        let halfH: Float = 0.32
        let armLen: Float = sqrt((2 * halfW) * (2 * halfW) + halfH * halfH)
        let armThick: Float = 0.07  // Y cross-section (visual thickness of arm)
        let faceDepth: Float = 0.04 // Z depth (face thickness, thin)
        let gap: Float = 0.26       // Z spacing between two ">" shapes

        // arm from tip (+halfW, 0) → base (-halfW, ±halfH): direction (-2*halfW, ±halfH)
        let armAngle = atan2(halfH, -2 * halfW)  // Z-rotation angle (Q2, upper-left from tip)

        for zOff: Float in [-gap / 2, gap / 2] {
            let uBox = SCNBox(width: CGFloat(armLen), height: CGFloat(armThick), length: CGFloat(faceDepth), chamferRadius: 0)
            uBox.materials = [mat]
            let uNode = SCNNode(geometry: uBox)
            uNode.position = SCNVector3(0, halfH / 2, zOff)
            uNode.eulerAngles = SCNVector3(0, 0, armAngle)
            bobNode.addChildNode(uNode)

            let lBox = SCNBox(width: CGFloat(armLen), height: CGFloat(armThick), length: CGFloat(faceDepth), chamferRadius: 0)
            lBox.materials = [mat]
            let lNode = SCNNode(geometry: lBox)
            lNode.position = SCNVector3(0, -halfH / 2, zOff)
            lNode.eulerAngles = SCNVector3(0, 0, -armAngle)
            bobNode.addChildNode(lNode)
        }

        let up = SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.8)
        up.timingMode = .easeInEaseOut
        let down = SCNAction.moveBy(x: 0, y: -0.08, z: 0, duration: 0.8)
        down.timingMode = .easeInEaseOut
        bobNode.runAction(SCNAction.repeatForever(SCNAction.sequence([up, down])))

        return node
    }

    // 경로 위에 5m 간격 + 회전 구간 더블 쉐브론 배치
    private func placeChevronArrows(on points: [simd_float3], steps: [PathStep], rootNode: SCNNode) {
        allChevronNodes.removeAll()

        // 회전 구간: instruction에 "회전" 포함된 step의 smooth point 인덱스
        let subdiv = 20
        var turnIndices: Set<Int> = []
        for (idx, step) in steps.enumerated() {
            if (step.instruction ?? "").contains("회전") {
                let si = min(idx * subdiv, points.count - 1)
                turnIndices.insert(si)
            }
        }

        var placedSet: Set<Int> = []

        func place(at idx: Int) {
            guard idx < points.count - 1, !placedSet.contains(idx) else { return }
            placedSet.insert(idx)
            let p = points[idx]
            let pn = points[idx + 1]
            let dx = pn.x - p.x
            let dz = pn.z - p.z
            let len = sqrt(dx * dx + dz * dz)
            guard len > 0.001 else { return }
            let chevron = createChevronNode()

            // 위치: 다음 노드 직전(가장자리 끝)으로 이동. pn에서 진행 반대로 0.6m 뒤.
            let edgeOffsetFromNext: Float = 0.6
            let t: Float = max(0.0, (len - edgeOffsetFromNext) / len)
            let ex = p.x + (pn.x - p.x) * t
            let ez = p.z + (pn.z - p.z) * t
            let ey = p.y + 0.8
            chevron.position = SCNVector3(ex, ey, ez)

            // Yaw: 모델의 +X(tip)이 진행 방향(dx,dz)으로 향하도록.
            // SceneKit Y-up + right-hand: +Y 양의 각도는 +Z → +X 회전이므로,
            // 모델 +X(tip)을 (dx,dz)로 보내려면 angle = -atan2(dz, dx).
            let yaw = atan2(dz, dx)
            let yawQ = simd_quatf(angle: -yaw, axis: simd_float3(0, 1, 0))

            // Pitch: 사용자 시야에 잘 보이도록 화살표 윗면을 사용자 쪽(진행 반대)으로 약 20° 기울임.
            // 진행 방향에 수직인 수평축(world right axis) 기준 회전.
            let pitchAngleDeg: Float = 20.0
            let pitchAngle = pitchAngleDeg * .pi / 180.0
            let worldRightAxis = simd_float3(-dz / len, 0, dx / len)
            let pitchQ = simd_quatf(angle: pitchAngle, axis: worldRightAxis)

            // 합성: world frame 기준이므로 pitch * yaw (왼쪽이 후속 적용)
            chevron.simdOrientation = pitchQ * yawQ
            chevron.renderingOrder = 10  // ribbon보다 위에 렌더링
            rootNode.addChildNode(chevron)
            allChevronNodes.append((node: chevron, pointIndex: idx))
        }

        // 회전 구간 우선 배치
        for idx in turnIndices { place(at: idx) }

        // 25m 간격 정규 배치
        let spacing: Float = 25.0
        var covered: Float = 0
        var nextPlace: Float = spacing / 2

        for i in 1..<points.count {
            let p1 = points[i - 1]
            let p2 = points[i]
            let ddx = p2.x - p1.x
            let ddz = p2.z - p1.z
            let segLen = sqrt(ddx * ddx + ddz * ddz)
            guard segLen > 0.0001 else { continue }
            while covered + segLen >= nextPlace {
                place(at: i)
                nextPlace += spacing
            }
            covered += segLen
        }
    }

    // 30m 슬라이딩 윈도우: 카메라와 가장 가까운 smooth point부터 30m 앞까지만 렌더링
    private func updateRibbonWindow(cameraPos: simd_float3) {
        guard let rootNode = pathRootNode, !smoothedPoints.isEmpty else { return }

        // 카메라 XZ 위치와 가장 가까운 smooth point → window 시작점
        let camXZ = simd_float2(cameraPos.x, cameraPos.z)
        var startIdx = 0
        var nearestDist: Float = .infinity
        for i in 0..<smoothedPoints.count {
            let p = smoothedPoints[i]
            let d = simd_distance(camXZ, simd_float2(p.x, p.z))
            if d < nearestDist { nearestDist = d; startIdx = i }
        }

        // startIdx부터 30m 누적까지 endIdx 탐색
        var endIdx = startIdx
        var cumDist: Float = 0
        for i in startIdx..<smoothedPoints.count - 1 {
            let p1 = smoothedPoints[i], p2 = smoothedPoints[i + 1]
            cumDist += sqrt((p2.x - p1.x) * (p2.x - p1.x) + (p2.z - p1.z) * (p2.z - p1.z))
            endIdx = i + 1
            if cumDist >= renderWindowDistance { break }
        }

        guard endIdx > startIdx else { return }
        let windowPoints = Array(smoothedPoints[startIdx...endIdx])
        guard windowPoints.count >= 2 else { return }

        rootNode.childNode(withName: "ribbonContainer", recursively: false)?.removeFromParentNode()
        rootNode.addChildNode(buildRibbonNode(points: windowPoints))

        for (chevron, pointIdx) in allChevronNodes {
            chevron.isHidden = pointIdx < startIdx || pointIdx > endIdx
        }
    }

    // MARK: - 경로 진행 추적

    private func startPathProgressTracking() {
        pathProgressTimer?.invalidate()
        pathProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let frame = self.arSession?.currentFrame else { return }
            let cameraPos = simd_float3(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            self.tickPathProgress(cameraPos: cameraPos)
        }
    }

    private func tickPathProgress(cameraPos: simd_float3) {
        guard !smoothedPoints.isEmpty else { return }

        // 1. waypoint 전환 체크: 카메라가 waypoint를 지나쳤는지 dot-product로 판별
        while currentTargetWaypointIndex < smoothedPoints.count - 1 {
            let wp = smoothedPoints[currentTargetWaypointIndex]
            let wpNext = smoothedPoints[currentTargetWaypointIndex + 1]
            let pathDir = simd_float2(wpNext.x - wp.x, wpNext.z - wp.z)
            let toCam = simd_float2(cameraPos.x - wp.x, cameraPos.z - wp.z)
            if simd_dot(pathDir, toCam) > 0 {
                currentTargetWaypointIndex += 1
            } else {
                break
            }
        }

        // 2. 30m 슬라이딩 윈도우 업데이트 (1m 이동마다)
        if let lastPos = lastWindowUpdatePosition {
            let ddx = cameraPos.x - lastPos.x
            let ddz = cameraPos.z - lastPos.z
            if sqrt(ddx * ddx + ddz * ddz) >= windowUpdateMoveDelta {
                updateRibbonWindow(cameraPos: cameraPos)
                lastWindowUpdatePosition = cameraPos
            }
        }

        // 3. HUD 갱신
        if currentTargetWaypointIndex >= smoothedPoints.count {
            // 도착
            pathProgressTimer?.invalidate()
            pathProgressTimer = nil
            delegate?.updateHUD(destinationName: destinationName, remainingDistance: 0, instruction: "목적지에 도착했습니다")
            return
        }

        let remaining = computeRemainingDistance(cameraPos: cameraPos)
        let stepIdx = min(currentTargetWaypointIndex, max(allSteps.count - 1, 0))
        let instruction = (stepIdx >= 0 && stepIdx < allSteps.count) ? allSteps[stepIdx].instruction : nil
        delegate?.updateHUD(destinationName: destinationName, remainingDistance: remaining, instruction: instruction)
    }

    func stopPathProgressTracking() {
        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
    }

    // MARK: - Mock Mode

    /// 서버 미가용 시 mock pose/steps로 경로 렌더링을 트리거.
    /// `useMockData == true`일 때 `startLocalizationFlow()`가 호출.
    private func runMockFlow() {
        guard let frame = arSession?.currentFrame else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다.", color: .systemYellow)
            return
        }

        print("[MOCK] 로컬라이즈 우회, mock pose/steps 사용")

        // 직전 시도 잔여 상태 정리 (재진입 안전성)
        pathRootNode?.removeFromParentNode()
        pathRootNode = nil
        allChevronNodes.removeAll()
        lastWindowUpdatePosition = nil
        allSteps = []
        allARPoints = []
        smoothedPoints = []
        currentTargetWaypointIndex = 0
        matchedARPose = nil
        localizedPose = nil
        destinationARPosition = nil

        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
        hasNotifiedArrival = false

        delegate?.setLocateButtonVisible(false)
        delegate?.setScanningOverlay(visible: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.delegate?.setScanningOverlay(visible: false)
            self.delegate?.showScanComplete()
            self.delegate?.showRouteCalculating(true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.delegate?.showRouteCalculating(false)

                self.matchedARPose = frame.camera.transform
                self.localizedPose = self.makeMockPose()
                self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                self.drawPathNodes(steps: self.makeMockSteps())
            }
        }
    }

    private func makeMockPose() -> Pose {
        return Pose(x: 0, y: 0, z: 0, qx: 0, qy: 0, qz: 0, qw: 1)
    }

    private func makeMockSteps() -> [PathStep] {
        // RTAB-Map 좌표계: X-forward, Y-left, Z-up
        // 0→50m 직진 → 50m 지점 90도 우회전(Y 감소 = 오른쪽) → 50m 직진 (총 100m)
        let positions: [(Double, Double, Double, String)] = [
            (0,   0,   0, "직진하세요"),
            (25,  0,   0, "직진하세요"),
            (50,  0,   0, "우회전하세요"),
            (50, -25,  0, "직진하세요"),
            (50, -50,  0, "목적지 근처입니다")
        ]

        return positions.enumerated().map { (index, tuple) in
            let (x, y, z, instruction) = tuple
            return PathStep(
                stepNumber: index,
                floorLevel: 1,
                position: Position(x: x, y: y, z: z),
                instruction: instruction
            )
        }
    }

    // MARK: - 헬퍼

    private func computeRemainingDistance(cameraPos: simd_float3) -> Float {
        guard !smoothedPoints.isEmpty else { return 0 }
        guard currentTargetWaypointIndex < smoothedPoints.count else { return 0 }

        let target = smoothedPoints[currentTargetWaypointIndex]
        let dx = cameraPos.x - target.x
        let dz = cameraPos.z - target.z
        var total = sqrt(dx * dx + dz * dz)

        var i = currentTargetWaypointIndex
        while i < smoothedPoints.count - 1 {
            let p1 = smoothedPoints[i]
            let p2 = smoothedPoints[i + 1]
            let ddx = p2.x - p1.x
            let ddz = p2.z - p1.z
            total += sqrt(ddx * ddx + ddz * ddz)
            i += 1
        }
        return total
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
}
