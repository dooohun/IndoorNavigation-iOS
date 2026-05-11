import UIKit
import ARKit
import SceneKit

// MARK: - Phase 6 UI 모델 (Step 기반 카드 UX)

enum NavigationActionKind {
    case straight
    case turnLeft, turnRight, turnSlightLeft, turnSlightRight
    case uturn
    case stairsUp, stairsDown
    case elevator
    case arrive
    case unknown
}

struct NavigationStepViewModel {
    let action: NavigationActionKind
    let distanceMeters: Double
    let approxSteps: Int
    let remainingTotalMeters: Double
    let remainingMinutes: Int
    let remainingExtraStepsCount: Int
    let destinationFloorLevel: Int?
    let destinationName: String
}

// MARK: - Phase 6 turn 3D 화살표 모델

enum TurnArrowKind { case sharp, slight, uturn }

struct TurnArrowViewModel {
    let direction: TurnDirection   // 기존 Guidance/GuidanceDirector.swift 재사용
    let kind: TurnArrowKind
    let arPosition: simd_float3
    let stepIndex: Int
}

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
    func updateNavigationStep(_ vm: NavigationStepViewModel)
    func updateTurnArrow(_ vm: TurnArrowViewModel?)
    func updateMarkers(_ markers: [ARMarkerNode])
    func setHUDVisible(_ visible: Bool)
    func setLocateButtonVisible(_ visible: Bool)
    func showFloorNavigationMap(_ map: FloorMapResponse, routeSteps: [PathStep], currentPosition: Position?, currentHeadingDegrees: Float?)
    func updateFloorNavigationPosition(_ position: Position?, headingDegrees: Float?)
    func hideFloorNavigationMap()
    func showRouteCalculating(_ visible: Bool)
    func showFloorTransition(transitionType: String, targetFloor: Int?, currentFloor: Int?)
    func hideFloorTransition()
}

// MARK: - Logic

class ARNavigationLogic {

    /// LightGlue 비활성 (2026-05-10) — 매처 정확도 한계 확정으로 Phase 4 추적 루프 정지.
    /// SuperPoint 추출 + V3 측위 + path 렌더 + 정적 checkpoint 만 유지.
    /// 모델 자원(LightGlueMatcher.mlpackage) 은 추후 재활성화 위해 보존.
    static let useLightGlueMatcher: Bool = false

    /// SuperPoint 추출 비활성 (2026-05-10) — 발열/배터리 절감용 일시 OFF.
    /// V3 측위는 서버 측 SuperPoint 추출이라 클라 추출 없이도 정상 동작.
    /// 모델 자원(SuperPoint.mlpackage) 은 추후 재활성화 위해 보존.
    static let useSuperPointExtractor: Bool = false

    weak var delegate: ARNavigationLogicDelegate?
    weak var arSession: ARSession?
    weak var scene: SCNScene?

    let buildingId: String
    let floorId: String
    let destinationName: String
    let goal: Coordinate

    init(buildingId: String, floorId: String, destinationName: String, goal: Coordinate) {
        self.buildingId = buildingId
        self.floorId = floorId
        self.destinationName = destinationName
        self.goal = goal
    }

    // 다중 프레임 캡처
    // TODO(서버답): V3 권장 이미지 개수 4-5장 가정
    let maxImages = 5
    let captureInterval: TimeInterval = 0.8
    /// 캡처 시점 카메라 이동 속도 임계 (m/s). 초과 시 motion blur 우려로 skip.
    let captureMaxTranslationVel: Float = 0.3
    /// 캡처 시점 카메라 회전 속도 임계 (rad/s ≈ 30°/s). 초과 시 skip.
    let captureMaxRotationVel: Float = 0.52
    private var lastCaptureTimestamp: TimeInterval?
    private var matchedARPose: simd_float4x4?
    private var localizedPose: Pose?
    private var localizedFloorId: String?
    private var localizedFloorLevel: Int?
    private var localizedScanId: String?  // V3 응답 mapId — B4 PathfindingRequest.startScanId 인계용
    private var capturedImages: [UIImage] = []
    private var capturedARPoses: [simd_float4x4] = []
    private var captureTimer: Timer?

    // LocalizeDebugLogger 용 — drawPathFromSteps 까지 살아남을 데이터
    private var lastLocalizeResponse: SLAMLocalizeResponse?
    private var lastMatchedImage: UIImage?
    private var lastMatchedImageIndex: Int?

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
    private var destinationPinNode: SCNNode?
    private var currentTargetWaypointIndex: Int = 0
    private var pathProgressTimer: Timer?
    private let waypointSwitchThreshold: Float = 0.8

    // 층 이동 인터렉션
    private var hasActiveFloorTransition: Bool = false
    private var pendingRemainingSteps: [PathStep] = []
    private var pendingTargetFloor: Int? = nil
    private var isFloorTransitionRestart: Bool = false
    private let floorTransitionTriggerDistance: Float = 1.0

    // 경로 시작점 진단
    private var lastStartSnapDistance: Double?

    // 방향 안내 (Phase 5)
    private let guidanceDirector = GuidanceDirector()
    private let pathSubdivisions: Int = 20  // catmullRomSpline subdivisions와 동기화
    /// RDP(Ramer-Douglas-Peucker) 사전 경로 단순화 임계값 (XZ 평면, m).
    /// 0.25m 격자·0.5m 미만 단차 흡수. 시각 경로(리본·쉐브론)와 GuidanceDirector turn 판정 모두에 적용.
    private let pathSimplificationEpsilonM: Float = 0.7
    /// drawPathNodes에서 RDP 단순화 결과 점 개수. tickPathProgress의 step index 비례 환산에 사용.
    private var simplifiedPointCount: Int = 0

    // MARK: - SuperPoint (Phase 7)

    /// SuperPoint 추출기. 기본은 ML 구현(SuperPointExtractorML), DEBUG 빌드에서 UserDefaults
    /// `useSuperPointStub == true` 면 stub 으로 폴백. ML init 실패 시에도 stub 폴백.
    private var superPointExtractor: SuperPointExtracting?
    /// 추론 빈도 제어 (정지/걷기/회전 + thermal throttle).
    private let cadenceController = InferenceCadenceController()
    /// 최근 추론 시간(ms) ring buffer (capacity 100). DEBUG 빌드에서 mean/p95 산출에 사용.
    private var inferenceTimesMs: [Double] = []
    private let inferenceTimesCapacity: Int = 100
    #if DEBUG
    /// 디버그 시각화 컨트롤러 (옵셔널 weak). 본 모듈은 디버그 폴더 타입을 단방향 의존만 — receiveFrame 호출만 한다.
    private weak var superPointDebug: SuperPointDebugController?
    #endif

    // MARK: - Phase 8 mock matching (mock bundle 호환성 검증)
    /// 서버 endpoint 결정 전 mock JSON bundle 로드. extract 결과와 매칭해 호환성 검증.
    private var localizationBundle: LocalizationBundle?
    /// keyframe 별 base64 디코딩된 descriptor bytes 캐시 (반복 디코딩 회피).
    private var keyframeDescriptorCache: [Data] = []
    /// NetworkBundleProvider strong reference — fetch completion 까지 인스턴스 살려둠
    /// (로컬 변수만 두면 setupSuperPointExtractor 종료 시 deallocated → completion silent return).
    private var networkBundleProvider: NetworkBundleProvider?
    /// PnP solver — RANSAC 으로 outlier 매칭에 면역. iter 100, inlier 임계 20px (intrinsics
    /// 불일치 미세 reproj 차이 흡수 — 단계 5 클라 K 정확화 전 잠정), 최소 inlier 8.
    /// 단순 DLT 단독은 outlier 1~2 개에도 reproj 폭주하므로 실측에서 무용지물 (관찰됨).
    private let pnpSolver: PnPSolving = RansacPnPSolver(
        iterations: 100,
        inlierThresholdPx: 20.0,
        minInliers: 8
    )
    /// PnP 최소 매칭 점 수 (DLT 이론상 6, 실용은 더 많을수록 안정).
    private let pnpMinPairs: Int = 6

    // MARK: - Phase 8 추적 cadence (A 트랙)
    /// 추적 측위 주기 (초). SuperPoint ~700ms + LightGlue 5kf × ~100ms ≈ 1.2s.
    /// cadence 5.0s = thermal throttle 회피 + prefix drop 충분 빈도.
    private let trackingCadenceSec: TimeInterval = 5.0
    /// 매 tick 매칭할 후보 keyframe 최대 개수 (candidates 앞쪽부터).
    /// prefix drop 모델상 사용자는 인덱스 0~N 근처 → 19개 모두 매칭 불요.
    private let trackingMatchTopK: Int = 5
    /// 추적 timer.
    private var trackingTimer: Timer?
    /// 추적 추론 큐 — userInitiated.
    private let trackingQueue = DispatchQueue(label: "tracking.lightglue", qos: .userInitiated)
    /// tick 간 큐 쌓임 방지. main 전용.
    private var isTrackingTickInFlight: Bool = false
    /// 도착 임계 (m). TODO(A1).
    private let trackingArrivalThresholdM: Float = 1.0

    // Phase 8 keyframe 단계 추적 (A 트랙 재설계)
    /// 진행 방향 정렬된 후보 — 인덱스 0 이 시작쪽(목적지로부터 먼 점), 마지막 인덱스가 목적지쪽(가장 가까운 점).
    /// tick 마다 best 까지 prefix drop — "지워나감" 모델.
    private var trackingKeyframeCandidates: [BundleKeyframe] = []
    /// 단일 흰색 원형 바닥 마커. 다음 keyframe 위치를 표시.
    private var checkpointNode: SCNNode?
    /// 직전 tick best — 변화 추적 로그용.
    private var lastBestKeyframeIndex: Int?
    /// fetchBundleForPath 시점에 보관한 query 좌표열. 새 lookup 트리거 시 다음 좌표 결정용.
    private var pathQueryPoints: [NetworkBundleProvider.QueryPoint] = []
    /// 다음 query 좌표 커서. triggerNewLookup 호출 시 +1.
    private var consumedQueryPointIndex: Int = 0
    /// pathfinding steps 시각화용 노드 (sphere + 인접 segment cylinder).
    private var pathNodes: [SCNNode] = []
    /// drawPathFromSteps 가 받은 마지막 steps — PnP 보정 후 재렌더용.
    private var lastPathSteps: [PathStep] = []
    private var floorMapCache: [String: FloorMapResponse] = [:]
    private var floorMapRequestGeneration: Int = 0
    /// trial counter — 화면 더블탭으로 측위 재시작 시 +1, 로그 prefix 용.
    private var trialNumber: Int = 0

    // MARK: - Phase 6 step UI 추적 상태
    /// 현재 사용자가 진행 중인 step index (lastPathSteps 기준).
    /// recomputeCurrentStepIndex 가 단조 증가로 갱신.
    private var currentStepIndex: Int = 0
    /// processARFrame 내 1Hz throttle 용 마지막 tick 시각 (CACurrentMediaTime).
    private var lastNavStepTickAt: TimeInterval = 0
    /// 보행 평균 속도 (m/s) — remainingMinutes 계산. docs Phase 6.
    private static let walkSpeedMps: Double = 1.2
    /// 보행 평균 보폭 (m) — approxSteps 계산. docs Phase 6.
    private static let walkStrideM: Double = 0.7
    /// turn step 3D 화살표 진입 임계 (XZ, m). 카메라 ↔ turn step 거리 ≤ 10m 일 때 NextArrow 진입 (사양 §3).
    private static let turnArrowLookaheadM: Double = 10.0

    /// LightGlue 매칭 엔진 — 토글 ON 시에만 init. mlpackage 미배치/load 실패 시 nil → fallback.
    // 비활성: useLightGlueMatcher=false. 인스턴스화 회피로 mlpackage 로드 비용 절감.
    private lazy var lightGlueMatcher: LightGlueMatcherEngine? = { return nil }()

    // MARK: - 외부 노출

    func setGuidanceDelegate(_ delegate: GuidanceDirectorDelegate) {
        guidanceDirector.delegate = delegate
    }

    /// SuperPoint extractor 인스턴스화 + warmUp. ViewController에서 viewDidLoad 끝에 호출.
    /// 기본 경로: SuperPointExtractorML (Core ML 추론). DEBUG 빌드에서 UserDefaults
    /// `useSuperPointStub` 가 true 면 stub 으로 강제 폴백. ML init 실패 시에도 stub 폴백.
    func setupSuperPointExtractor() {
        guard Self.useSuperPointExtractor else {
            print("[SuperPoint] 비활성 — 발열 절감용 OFF. mlpackage 로드/warmUp 회피.")
            return
        }
        let useStub: Bool = {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: "useSuperPointStub")
            #else
            return false
            #endif
        }()

        if useStub {
            let stub = SuperPointExtractorStub()
            stub.warmUp()
            superPointExtractor = stub
            return
        }

        do {
            let ml = try SuperPointExtractorML()
            ml.onInferenceTimeMs = { [weak self] ms in self?.recordInferenceTime(ms) }
            ml.warmUp()
            superPointExtractor = ml
        } catch {
            let stub = SuperPointExtractorStub()
            stub.warmUp()
            superPointExtractor = stub
        }

    }

    /// SuperPointExtractorML 의 onInferenceTimeMs 콜백으로부터 호출. 최근 100개만 유지.
    /// DEBUG 빌드에서는 mean/p95 ms 를 디버그 컨트롤러에 전달한다.
    private func recordInferenceTime(_ ms: Double) {
        inferenceTimesMs.append(ms)
        if inferenceTimesMs.count > inferenceTimesCapacity {
            inferenceTimesMs.removeFirst(inferenceTimesMs.count - inferenceTimesCapacity)
        }
        #if DEBUG
        let times = inferenceTimesMs
        guard !times.isEmpty else { return }
        let mean = times.reduce(0, +) / Double(times.count)
        let sorted = times.sorted()
        let pIdx = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95 = sorted[max(0, pIdx)]
        superPointDebug?.updateInferenceTime(meanMs: mean, p95Ms: p95)
        #endif
    }

    #if DEBUG
    /// 디버그 시각화 컨트롤러 연결 (DEBUG 빌드 전용).
    func attachSuperPointDebug(_ debug: SuperPointDebugController) {
        superPointDebug = debug
    }
    #endif

    /// ARSessionDelegate.session(_:didUpdate:) 에서 매 프레임 호출.
    /// cadence 통과 시에만 extract 수행하고, DEBUG 빌드에서 디버그 오버레이로 결과 전달.
    func processARFrame(_ frame: ARFrame) {
        // Phase 6: 2D 지도 위치는 매 AR frame 갱신하고, 텍스트 step vm만 1Hz throttle.
        if !lastPathSteps.isEmpty {
            let floorNavigationPose = currentFloorNavigationPose(frame: frame)
            delegate?.updateFloorNavigationPosition(
                floorNavigationPose?.position,
                headingDegrees: floorNavigationPose?.headingDegrees
            )

            let now = CACurrentMediaTime()
            if now - lastNavStepTickAt >= 1.0 {
                lastNavStepTickAt = now
                let cam = simd_float3(frame.camera.transform.columns.3.x,
                                      frame.camera.transform.columns.3.y,
                                      frame.camera.transform.columns.3.z)
                recomputeCurrentStepIndex(cameraPos: cam)
                if let vm = makeNavigationStepViewModel(cameraPos: cam) {
                    delegate?.updateNavigationStep(vm)
                }
                let turnVM = makeTurnArrowViewModel(cameraPos: cam)
                delegate?.updateTurnArrow(turnVM)
                let markers = makeActiveMarkerList(cameraPos: cam)
                delegate?.updateMarkers(markers)
            }
        }

        guard Self.useSuperPointExtractor else { return }
        guard let extractor = superPointExtractor else { return }

        let thermal = ProcessInfo.processInfo.thermalState
        guard cadenceController.shouldRunInference(
            cameraTransform: frame.camera.transform,
            timestamp: frame.timestamp,
            thermalState: thermal
        ) else { return }

        let intrinsics = frame.camera.intrinsics
        // 디바이스 자세 → SuperPoint 입력 orientation 결정. ARFrame raw 는 항상 landscape 라
        // 사용자가 폰 portrait 면 90° CW 회전 후 가로 띠 crop 으로 upright 입력을 만든다.
        let deviceIsLandscape = UIDevice.current.orientation.isLandscape
        let orientation: InputOrientation = deviceIsLandscape ? .landscape : .portrait
        let result = extractor.extract(
            image: frame.capturedImage,
            intrinsics: intrinsics,
            timestamp: frame.timestamp,
            orientation: orientation
        )

        #if DEBUG
        if let debug = superPointDebug {
            debug.frameDumper.consumeIfRequested(
                frame: result,
                arPose: frame.camera.transform
            ) { res in
                switch res {
                case .success:
                    debug.notifyDumpResult(success: true)
                case .failure:
                    debug.notifyDumpResult(success: false)
                }
            }
        }
        #endif

        #if DEBUG
        superPointDebug?.receiveFrame(result)
        #endif
        _ = result
    }

    // MARK: - 다중 프레임 캡처 후 Localize

    /// 새 trial(측위) 시작 시 잔여 상태/노드/타이머 일괄 정리. idempotent — 여러 번 호출해도 안전.
    /// 화면 더블탭으로 측위 재시작 시에도 재사용.
    private func resetForNewTrial() {
        // SCNNode 제거
        pathRootNode?.removeFromParentNode()
        pathRootNode = nil
        checkpointNode?.removeFromParentNode()
        checkpointNode = nil
        destinationPinNode = nil
        allChevronNodes.removeAll()
        delegate?.updateTurnArrow(nil)
        delegate?.updateMarkers([])

        // timer 정지
        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        captureTimer?.invalidate()
        captureTimer = nil

        // 상태 클리어
        allSteps = []
        allARPoints = []
        smoothedPoints = []
        simplifiedPointCount = 0
        currentTargetWaypointIndex = 0
        matchedARPose = nil
        localizedPose = nil
        localizedScanId = nil
        destinationARPosition = nil
        lastStartSnapDistance = nil
        hasNotifiedArrival = false
        isTrackingTickInFlight = false
        trackingKeyframeCandidates = []
        lastBestKeyframeIndex = nil
        pathQueryPoints = []
        consumedQueryPointIndex = 0
        pathNodes.forEach { $0.removeFromParentNode() }
        pathNodes = []
        lastPathSteps = []
        floorMapRequestGeneration += 1
        delegate?.hideFloorNavigationMap()
        currentStepIndex = 0
        lastNavStepTickAt = 0

        // bundle 클리어
        localizationBundle = nil
        keyframeDescriptorCache = []
        networkBundleProvider = nil

        // capture 버퍼 클리어
        capturedImages = []
        capturedARPoses = []
        lastCaptureTimestamp = nil

        // GuidanceDirector 도 reset (Phase 5 dead path 지만 호출 부수효과 없게)
        guidanceDirector.reset()
    }

    func startLocalizationFlow() {
        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        trialNumber += 1
        resetForNewTrial()

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

        // 1. ARKit 모션 경고 — excessiveMotion / relocalizing / insufficientFeatures
        if case .limited(let reason) = frame.camera.trackingState {
            switch reason {
            case .excessiveMotion:
                delegate?.updateStatus("잠시 멈춰주세요 (흔들림 감지)", color: .orange)
                return
            case .insufficientFeatures:
                delegate?.updateStatus("주변에 특징이 부족해요. 다른 곳을 비춰주세요", color: .orange)
                return
            case .initializing, .relocalizing:
                return
            @unknown default:
                return
            }
        }

        // 2. 직전 캡처 대비 카메라 이동·회전 속도 — blur 임계 차단
        if let lastTime = lastCaptureTimestamp,
           let lastTransform = capturedARPoses.last {
            let dt = max(Float(frame.timestamp - lastTime), 0.001)
            let curT = frame.camera.transform.columns.3
            let lastT = lastTransform.columns.3
            let dist = simd_distance(
                simd_float3(curT.x, curT.y, curT.z),
                simd_float3(lastT.x, lastT.y, lastT.z)
            )
            let translationVel = dist / dt  // m/s
            let curR = simd_float3x3(
                SIMD3<Float>(frame.camera.transform.columns.0.x, frame.camera.transform.columns.0.y, frame.camera.transform.columns.0.z),
                SIMD3<Float>(frame.camera.transform.columns.1.x, frame.camera.transform.columns.1.y, frame.camera.transform.columns.1.z),
                SIMD3<Float>(frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y, frame.camera.transform.columns.2.z)
            )
            let lastR = simd_float3x3(
                SIMD3<Float>(lastTransform.columns.0.x, lastTransform.columns.0.y, lastTransform.columns.0.z),
                SIMD3<Float>(lastTransform.columns.1.x, lastTransform.columns.1.y, lastTransform.columns.1.z),
                SIMD3<Float>(lastTransform.columns.2.x, lastTransform.columns.2.y, lastTransform.columns.2.z)
            )
            let curQ = simd_quatf(curR)
            let lastQ = simd_quatf(lastR)
            let angleDelta = (curQ.normalized * lastQ.normalized.inverse).angle
            let rotationVel = abs(angleDelta) / dt  // rad/s

            if translationVel > captureMaxTranslationVel || rotationVel > captureMaxRotationVel {
                delegate?.updateStatus("천천히 움직여주세요", color: .orange)
                return
            }
        }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        capturedImages.append(uiImage)
        capturedARPoses.append(frame.camera.transform)
        lastCaptureTimestamp = frame.timestamp

        let count = capturedImages.count
        delegate?.setCaptureProgress(text: "\(count)/\(maxImages)", isHidden: false)
        delegate?.updateStatus("천천히 주변을 둘러보세요\n사진을 \(maxImages)장 촬영합니다.", color: .white)

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

    /// V3 측위 흐름 — multipart 업로드 + SLAMLocalizeResponse 핸들링.
    private func sendToServer() {
        guard !capturedImages.isEmpty else {
            delegate?.setLoading(false)
            delegate?.setScanningOverlay(visible: false)
            delegate?.showScanFailed(message: "캡처된 이미지가 없어요.\n다시 시도해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        NetworkManager.shared.localizeV3(buildingId: buildingId, images: capturedImages) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.delegate?.setScanningOverlay(visible: false)
                switch result {
                case .success(let response):
                    self.handleLocalizeV3Success(response: response)
                case .failure:
                    self.delegate?.setLoading(false)
                    self.delegate?.showScanFailed(message: "서버 연결에 실패했어요.\n다시 한번 스캔해 주세요.")
                    self.delegate?.setLocateButtonVisible(true)
                }
            }
        }
    }

    /// V3 측위 응답 핸들러 — showScanComplete + V3 pathfinding 시작.
    private func handleLocalizeV3Success(response: SLAMLocalizeResponse) {
        // TODO(서버답): confidence 임계값 미정 → 0.3 잠정
        guard response.confidence >= 0.3 else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식 신뢰도가 낮아요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        guard let _ = response.pose.toMatrix4x4(),
              let translation = response.pose.translation,
              let quat = response.pose.rotationQuaternion else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // 서버가 매칭에 사용한 프레임의 AR pose 와 짝지어야 변환식이 정합.
        // matchedImageIndex 가 유효하면 그 인덱스, 아니면 마지막 프레임 fallback.
        guard !capturedARPoses.isEmpty else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }
        let arPoseIndex: Int = {
            if let idx = response.matchedImageIndex, capturedARPoses.indices.contains(idx) {
                return idx
            }
            return capturedARPoses.count - 1
        }()
        matchedARPose = capturedARPoses[arPoseIndex]
        print("[Localize] matchedImageIndex=\(response.matchedImageIndex.map(String.init) ?? "nil") → AR pose index=\(arPoseIndex)/\(capturedARPoses.count - 1)")

        // 디버그 로깅 — drawPathFromSteps 시점까지 보관
        lastLocalizeResponse = response
        lastMatchedImageIndex = arPoseIndex
        lastMatchedImage = capturedImages.indices.contains(arPoseIndex) ? capturedImages[arPoseIndex] : nil

        let pose = Pose(
            x: Double(translation.x), y: Double(translation.y), z: Double(translation.z),
            qx: Double(quat.imag.x), qy: Double(quat.imag.y), qz: Double(quat.imag.z), qw: Double(quat.real)
        )
        localizedPose = pose
        localizedFloorId = response.pose.floorId ?? self.floorId
        localizedFloorLevel = response.pose.floorLevel
        localizedScanId = response.mapId

        delegate?.showScanComplete()

        if isFloorTransitionRestart {
            // 층 전환 잔여 경로 재시작 — 추적 모델에서 미지원 (TODO)
            delegate?.showRouteCalculating(false)
            delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
            pendingRemainingSteps = []
            isFloorTransitionRestart = false
            delegate?.setLoading(false)
        } else {
            delegate?.showRouteCalculating(false)
            delegate?.setLoading(false)
            delegate?.updateStatus("\(destinationName) 방향으로 이동하세요.", color: .white)
            delegate?.setHUDVisible(true)
            startV3Pathfinding(scanId: response.mapId,
                               startFloorLevel: response.pose.floorLevel,
                               translation: translation)
        }
    }

    private func refreshFloorNavigationMap(routeSteps: [PathStep], currentFrame: ARFrame?) {
        let resolvedFloorId = localizedFloorId ?? floorId
        guard !resolvedFloorId.isEmpty else { return }

        let currentPose = currentFloorNavigationPose(frame: currentFrame)
        if let cached = floorMapCache[resolvedFloorId] {
            delegate?.showFloorNavigationMap(
                cached,
                routeSteps: routeSteps,
                currentPosition: currentPose?.position,
                currentHeadingDegrees: currentPose?.headingDegrees
            )
            return
        }

        floorMapRequestGeneration += 1
        let generation = floorMapRequestGeneration
        NetworkManager.shared.fetchFloorMap(floorId: resolvedFloorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.floorMapRequestGeneration == generation else { return }
                switch result {
                case .success(let map):
                    self.floorMapCache[resolvedFloorId] = map
                    let currentPose = self.currentFloorNavigationPose(frame: self.arSession?.currentFrame)
                    self.delegate?.showFloorNavigationMap(
                        map,
                        routeSteps: routeSteps,
                        currentPosition: currentPose?.position,
                        currentHeadingDegrees: currentPose?.headingDegrees
                    )
                case .failure(let error):
                    print("[FloorMap] fetch failed floorId=\(resolvedFloorId): \(error)")
                }
            }
        }
    }

    private func currentFloorNavigationPose(frame: ARFrame?) -> (position: Position, headingDegrees: Float?)? {
        guard let pose = localizedPose,
              let x = pose.x,
              let y = pose.y,
              let z = pose.z,
              let qx = pose.qx,
              let qy = pose.qy,
              let qz = pose.qz,
              let qw = pose.qw else { return nil }

        let serverPosition = simd_float3(Float(x), Float(y), Float(z))
        let serverQuaternion = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))

        guard let frame, let matchedARPose else {
            return (
                Position(x: x, y: y, z: z),
                serverHeadingDegrees(from: serverQuaternion)
            )
        }

        let input = CoordinateTransformer.Input(
            serverPosition: serverPosition,
            serverQuaternion: serverQuaternion,
            arCameraPose: matchedARPose
        )
        let cameraTransform = frame.camera.transform
        let arCameraPosition = simd_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let forwardAR4 = cameraTransform * simd_float4(0, 0, -1, 1)
        let arForwardPoint = simd_float3(forwardAR4.x, forwardAR4.y, forwardAR4.z)

        let currentServer = arWorldPointToServer(arCameraPosition, input: input)
        let forwardServer = arWorldPointToServer(arForwardPoint, input: input)
        let heading = Float(atan2(forwardServer.y - currentServer.y,
                                  forwardServer.x - currentServer.x) * 180 / .pi)

        return (
            Position(x: Double(currentServer.x), y: Double(currentServer.y), z: Double(currentServer.z)),
            heading
        )
    }

    private func arWorldPointToServer(_ arPoint: simd_float3, input: CoordinateTransformer.Input) -> simd_float3 {
        var serverCameraTransform = simd_float4x4(input.serverQuaternion)
        serverCameraTransform.columns.3 = simd_float4(input.serverPosition.x,
                                                      input.serverPosition.y,
                                                      input.serverPosition.z,
                                                      1)
        let arFromServer = input.arCameraPose
            * CoordinateTransformer.rtabCameraToARKit
            * serverCameraTransform.inverse
        let result = arFromServer.inverse * simd_float4(arPoint.x, arPoint.y, arPoint.z, 1)
        return simd_float3(result.x, result.y, result.z)
    }

    private func serverHeadingDegrees(from quaternion: simd_quatf) -> Float {
        let forward = quaternion.act(simd_float3(1, 0, 0))
        return Float(atan2(forward.y, forward.x) * 180 / .pi)
    }

    // MARK: - 경로 탐색

    // NOTE(B4): floorTransitions[] 는 detectFloorTransition 이 step 변화로 자동 처리 — 별도 매핑 불요.
    // 키워드 미스매치 발견 시 detectFloorTransition 의 stairsKeywords/elevatorKeywords 보강.
    private func startV3Pathfinding(scanId: String?, startFloorLevel: Int?, translation: simd_float3, retriedWithoutScanId: Bool = false) {
        // 서버 PathfindingRequest: startScanId 우선, 없으면 startFloorLevel — 둘 다 nil 이면 422 START_NOT_SPECIFIED
        guard scanId != nil || startFloorLevel != nil else {
            delegate?.setLoading(false)
            delegate?.showRouteCalculating(false)
            delegate?.showScanFailed(message: "측위 결과가 부족해요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }
        // TODO(서버답): verticalPreference/preference 사용자 설정 분리 — 별도 트랙
        let req = PathfindingRequest(
            startFloorLevel: startFloorLevel,
            startX: Double(translation.x),
            startY: Double(translation.y),
            startZ: Double(translation.z),
            destinationName: self.destinationName,
            preference: .shortest,
            verticalPreference: .elevator
        )
        let pathfindingTrial = trialNumber
        NetworkManager.shared.pathfinding(buildingId: buildingId, request: req) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.trialNumber == pathfindingTrial else {
                    print("[V3-PATH] stale pathfinding ignored — trial changed")
                    return
                }
                switch result {
                case .success(let resp):
                    let steps = resp.toPathSteps()
                    self.lastStartSnapDistance = nil
                    print("[V3-PATH] steps=\(steps.count), totalDistance=\(resp.totalDistance)m, floorTransitions=\(resp.floorTransitions?.count ?? 0)")
                    self.drawPathFromSteps(steps)
                    self.refreshFloorNavigationMap(routeSteps: steps, currentFrame: self.arSession?.currentFrame)
                    self.dumpLocalizeDebug(rawSteps: resp.steps)
                    // steps[].position 좌표를 lookup multi-query 로 사용 → 경로 전체 영역 keyframe pack 받음.
                    self.fetchBundleForPath(steps: steps, fallbackTranslation: translation, fallbackFloorLevel: startFloorLevel)
                case .failure(let err):
                    // START_SCAN_NOT_FOUND / SNAP_DISTANCE_EXCEEDED 시 startScanId 빼고 좌표만으로 재시도
                    let msg = String(describing: err)
                    if !retriedWithoutScanId, scanId != nil, startFloorLevel != nil,
                       msg.contains("START_SCAN_NOT_FOUND") {
                        print("[V3-PATH] startScanId inactive — retry without scanId")
                        self.startV3Pathfinding(scanId: nil,
                                                startFloorLevel: startFloorLevel,
                                                translation: translation,
                                                retriedWithoutScanId: true)
                        return
                    }
                    // pathfinding 실패해도 사용자 좌표 1점으로 lookup fallback — 추적 측위는 가능하게
                    print("[V3-PATH] 실패 (\(msg)) — 사용자 좌표 단일 query 로 lookup fallback")
                    self.fetchBundleForPath(steps: [], fallbackTranslation: translation, fallbackFloorLevel: startFloorLevel)
                }
            }
        }
    }

    /// pathfinding 응답 steps 좌표 multi-query (또는 fallback 단일 query) 로 lookup 호출.
    /// 받은 keyframe pack 으로 추적 측위 시작.
    private func fetchBundleForPath(steps: [PathStep], fallbackTranslation: simd_float3, fallbackFloorLevel: Int?) {
        // query 좌표 결정: steps 가 충분하면 그것, 아니면 사용자 좌표 1개
        var queryPoints: [NetworkBundleProvider.QueryPoint] = []
        if !steps.isEmpty {
            for step in steps {
                guard let pos = step.position else { continue }
                queryPoints.append(NetworkBundleProvider.QueryPoint(
                    floorLevel: step.floorLevel ?? (fallbackFloorLevel ?? 1),
                    x: pos.x ?? 0, y: pos.y ?? 0, z: pos.z ?? 0
                ))
            }
        }
        if queryPoints.isEmpty {
            queryPoints.append(NetworkBundleProvider.QueryPoint(
                floorLevel: fallbackFloorLevel ?? 1,
                x: Double(fallbackTranslation.x),
                y: Double(fallbackTranslation.y),
                z: Double(fallbackTranslation.z)
            ))
        }
        // 새 lookup 트리거 시 다음 query 좌표 결정용 — pathfinding 응답 그대로 보관.
        self.pathQueryPoints = queryPoints
        self.consumedQueryPointIndex = 0

        // 서버 cap: queries 64, maxKeyframesPerQuery 16, dedup 후 128. radius 5m 권장 (패턴 A).
        let provider = NetworkBundleProvider(
            buildingId: self.buildingId,
            queryPoints: queryPoints,
            radiusM: 5.0,
            maxKeyframesPerQuery: 5
        )
        self.networkBundleProvider = provider
        print("[NetworkBundle] pathfinding 후 multi-query lookup — queries=\(queryPoints.count), radius 5m")
        provider.fetch { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let bundle):
                self.localizationBundle = bundle
                self.keyframeDescriptorCache = bundle.keyframes.map { kf in
                    Data(base64Encoded: kf.descriptorsB64) ?? Data()
                }
                print("[NetworkBundle] loaded \(bundle.keyframes.count) keyframes (경로 전체 영역)")
                self.delegate?.showRouteCalculating(false)
                self.delegate?.setLoading(false)
                self.delegate?.updateStatus("\(self.destinationName) 방향으로 이동하세요.", color: .white)
                self.setupTrackingCandidates(bundle: bundle)
                self.startTracking()
            case .failure(let error):
                print("[NetworkBundle] fetch failed: \(error) — 추적 미시작, ARKit pose 만")
                self.delegate?.showRouteCalculating(false)
                self.delegate?.setLoading(false)
            }
        }
    }

    // MARK: - AR 경로 렌더링 (Phase 8 keyframe 단계 추적 모델로 대체)
    //
    // drawPathNodes / buildRibbonNode / createChevronNode / placeChevronArrows /
    // createDestinationPin 함수들은 Phase 8 재설계로 모두 제거되었다.
    //  - 새 모델: trackingKeyframeCandidates 후보열 + checkpointNode (단일 흰색 원형 마커) +
    //            tick 마다 best 까지 prefix drop ("지워나감").
    //  - simplifyXZ / rdpRecurse / perpendicularDistanceXZ / catmullRomSpline 등 보조 헬퍼는
    //    아래 MARK 섹션에 보존 — 향후 keyframe 사이 보간 안내 등 재활용 여지.
    //  - Phase 5 GuidanceDirector / chevron / ribbon / 목적지 핀 / 슬라이딩 윈도우 dead path —
    //    호출만 끊었고 멤버 변수·인스턴스는 보존. 별도 트랙에서 정리.

    // MARK: - 경로 진행 추적 (Phase 8 keyframe 단계 추적 모델로 대체 — body 무력화)

    /// Phase 8 keyframe 단계 추적 모델로 대체 — body 무력화.
    /// allSteps/smoothedPoints 미구축이라 호출돼도 dead path. ViewController 호출 안전.
    /// TODO(Phase 8+): keyframe 진행 추적은 runTrackingTick 으로 통합됨 — 본 함수 폐기 예정.
    private func startPathProgressTracking() {
        // intentionally empty — pathProgressTimer 사용 안 함.
    }

    /// Phase 8 keyframe 단계 추적 모델로 대체 — body 무력화. dead path.
    private func tickPathProgress(cameraPos: simd_float3) {
        _ = cameraPos
    }

    /// ViewController.viewWillDisappear 에서 호출 — 안전한 no-op.
    func stopPathProgressTracking() {
        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
    }

    // MARK: - 층 이동 인터렉션

    /// 현재 step → 다음 step 사이에 층 이동(계단/엘리베이터)이 발생하는지 감지.
    /// floorLevel 변화 또는 instruction 키워드 매칭. 둘 중 하나만 만족해도 트리거.
    private func detectFloorTransition(currentStepIdx: Int) -> (type: String, targetFloor: Int?)? {
        guard currentStepIdx + 1 < allSteps.count else { return nil }
        let cur = allSteps[currentStepIdx]
        let nxt = allSteps[currentStepIdx + 1]

        // 조건 1: floorLevel 변화
        let floorChanged: Bool = {
            if let cf = cur.floorLevel, let nf = nxt.floorLevel, cf != nf { return true }
            return false
        }()

        // 조건 2: instruction 키워드 매칭 (현재 또는 다음 step)
        let curInstr = cur.instruction ?? ""
        let nxtInstr = nxt.instruction ?? ""
        let combined = curInstr + " " + nxtInstr

        let stairsKeywords = ["TAKE_STAIRS", "STAIRS", "계단"]
        let elevatorKeywords = ["TAKE_ELEVATOR", "ELEVATOR", "엘리베이터"]

        let hasStairs = stairsKeywords.contains { combined.contains($0) }
        let hasElevator = elevatorKeywords.contains { combined.contains($0) }

        guard floorChanged || hasStairs || hasElevator else { return nil }

        // type 우선순위: instruction 키워드 매칭 결과로 결정. 없으면 기본 STAIRS.
        let type: String
        if hasElevator {
            type = "ELEVATOR"
        } else if hasStairs {
            type = "STAIRS"
        } else {
            type = "STAIRS"
        }

        return (type, nxt.floorLevel)
    }

    private func triggerFloorTransition(type: String, targetFloor: Int?, currentStepIdx: Int) {
        hasActiveFloorTransition = true

        // 잔여 steps 추출
        let remaining: [PathStep]
        if currentStepIdx + 1 < allSteps.count {
            remaining = Array(allSteps[(currentStepIdx + 1)...])
        } else {
            remaining = []
        }

        // 잔여 step이 비어있으면 도착 처리로 폴백
        if remaining.isEmpty {
            hasActiveFloorTransition = false
            delegate?.showArrivalNotification()
            return
        }

        pendingRemainingSteps = remaining
        pendingTargetFloor = targetFloor

        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil

        // AR 노드 숨김 (세션은 유지)
        pathRootNode?.isHidden = true

        // Phase 5: 층 전환 중에는 방향 안내 UI 일시 정지
        guidanceDirector.pause()

        delegate?.setHUDVisible(false)
        delegate?.showFloorTransition(transitionType: type, targetFloor: targetFloor, currentFloor: allSteps[currentStepIdx].floorLevel)
    }

    func restartFromFloorTransition() {
        guard hasActiveFloorTransition else { return }
        delegate?.hideFloorTransition()

        // 기존 노드 정리
        pathRootNode?.removeFromParentNode()
        pathRootNode = nil
        allChevronNodes.removeAll()
        destinationPinNode = nil
        currentTargetWaypointIndex = 0
        matchedARPose = nil
        localizedPose = nil
        destinationARPosition = nil
        hasNotifiedArrival = false
        lastStartSnapDistance = nil

        // Phase 5: director 상태도 초기화. 새 setRoute가 들어오면 isPaused 자동 해제.
        guidanceDirector.reset()

        hasActiveFloorTransition = false
        isFloorTransitionRestart = true

        // 재스캔 안내 UI 복귀 + 캡처 재시작
        delegate?.setLocateButtonVisible(false)
        delegate?.setLoading(true)
        delegate?.setScanningOverlay(visible: true)
        delegate?.updateStatus("천천히 주변을 둘러보세요\n사진을 \(maxImages)장 촬영합니다.", color: .white)
        delegate?.setCaptureProgress(text: "", isHidden: false)

        capturedImages = []
        capturedARPoses = []
        lastCaptureTimestamp = nil

        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureOneFrame()
        }

        // Phase 6: step index 만 리셋. vm 발신은 다음 drawPathFromSteps 가 담당.
        currentStepIndex = 0
        delegate?.updateTurnArrow(nil)
        delegate?.updateMarkers([])
    }

    // MARK: - Phase 8 추적 측위 cadence (A 트랙)

    /// 추적 측위 시작 — V3 측위 + lookup 완료 후 호출. cadence 마다 background 측위.
    func startTracking() {
        guard Self.useLightGlueMatcher else {
            print("[Tracking] 비활성 — LightGlue OFF (SuperPoint 단독 모드). V3 측위 + 정적 path/checkpoint 만 표시.")
            return
        }
        guard let bundle = localizationBundle, !bundle.keyframes.isEmpty else {
            print("[Tracking] start 실패 — bundle 없음 또는 빈 keyframes")
            return
        }
        guard lightGlueMatcher != nil else {
            print("[Tracking] start 실패 — lightGlueMatcher=nil")
            return
        }
        guard superPointExtractor != nil else {
            print("[Tracking] start 실패 — superPointExtractor=nil")
            return
        }
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: trackingCadenceSec, repeats: true) { [weak self] _ in
            self?.runTrackingTick()
        }
        print("[Tracking] 시작 — cadence=\(trackingCadenceSec)s, keyframes=\(bundle.keyframes.count)")
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func runTrackingTick() {
        guard !isTrackingTickInFlight else {
            return
        }
        guard let frame = arSession?.currentFrame,
              let bundle = localizationBundle,
              let extractor = superPointExtractor,
              let engine = lightGlueMatcher else { return }
        // 후보 비어있으면 skip (setupTrackingCandidates 미호출 또는 직후 reset)
        guard !trackingKeyframeCandidates.isEmpty else { return }

        let arPoseAtCapture = frame.camera.transform
        let pixelBuffer = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let timestamp = frame.timestamp
        let deviceIsLandscape = UIDevice.current.orientation.isLandscape
        let orientation: InputOrientation = deviceIsLandscape ? .landscape : .portrait

        // tick 시점 후보 snapshot — background 큐에서 매칭만 (PnP 폐기)
        let candidatesSnapshot = trackingKeyframeCandidates
        let intrinsicsSnapshot = bundle.manifest.intrinsics

        isTrackingTickInFlight = true
        let bundleSnapshot = bundle
        print("[Tick] 시작 — candidates=\(candidatesSnapshot.count)")
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            let queryFrame = extractor.extract(
                image: pixelBuffer,
                intrinsics: intrinsics,
                timestamp: timestamp,
                orientation: orientation
            )
            print("[Tick] SuperPoint 추출 완료 — keypoints=\(queryFrame.keypoints.count)")
            var matchErrors = 0
            var allKfData: [(idx: Int, count: Int, matches: [LightGlueMatcherEngine.Match])] = []
            // 발열 제어: prefix drop 모델상 사용자는 candidates 앞쪽 근처 → topK 만 매칭.
            let matchLimit = min(self.trackingMatchTopK, candidatesSnapshot.count)
            for idx in 0..<matchLimit {
                let kf = candidatesSnapshot[idx]
                guard !kf.keypoints.isEmpty else { continue }
                do {
                    let m = try engine.match(query: queryFrame, targetKeyframe: kf, targetIntrinsics: intrinsicsSnapshot)
                    allKfData.append((idx, m.count, m))
                } catch {
                    matchErrors += 1
                    if matchErrors <= 1 { print("[Tick] LightGlue 실패 kf=\(idx): \(error)") }
                }
            }
            let perKfMatches = allKfData.map { (idx: $0.idx, matched: $0.count) }
            let summary = perKfMatches.map { "\($0.idx):\($0.matched)" }.joined(separator: ",")
            print("[Tick] LightGlue 결과 — kf매칭=\(perKfMatches.count)/\(candidatesSnapshot.count) [\(summary)] errors=\(matchErrors)")
            guard let best = perKfMatches.max(by: { $0.matched < $1.matched }) else {
                DispatchQueue.main.async {
                    print("[Tick] best 없음 — 후보 유지")
                    self.isTrackingTickInFlight = false
                }
                return
            }

            // PnP 보정 — V3 측위 quat 오차 + ARKit drift 누적 정정. 매 tick 적용.
            var pnpRefinement: PoseEstimate? = nil
            let bestRaw = allKfData.first { $0.idx == best.idx }?.matches ?? []
            let bestKf = candidatesSnapshot[best.idx]
            let pairs = MatchedPointExtractor.extract(
                lightGlueMatches: bestRaw,
                queryKeypoints: queryFrame.keypoints,
                bundleKeyframe: bestKf
            )
            if pairs.count >= self.pnpMinPairs {
                let mIntr = bundleSnapshot.manifest.intrinsics
                let K = simd_float3x3(rows: [
                    SIMD3<Float>(Float(mIntr.fx), 0, Float(mIntr.cx)),
                    SIMD3<Float>(0, Float(mIntr.fy), Float(mIntr.cy)),
                    SIMD3<Float>(0, 0, 1),
                ])
                if let solved = self.pnpSolver.solve(
                    objectPoints: pairs.map { $0.worldPoint },
                    imagePoints: pairs.map { $0.imagePoint },
                    intrinsics: K
                ), solved.reprojectionError < 30 {
                    pnpRefinement = solved
                    print(String(format: "[Tick] PnP 보정 성공 — pairs=%d reproj=%.2fpx", pairs.count, solved.reprojectionError))
                } else {
                    print("[Tick] PnP fail (pairs=\(pairs.count) — reproj 초과 또는 solve 실패)")
                }
            } else {
                print("[Tick] PnP skip — pairs=\(pairs.count) < \(self.pnpMinPairs)")
            }

            DispatchQueue.main.async {
                print("[Tick] best kf=\(best.idx) matched=\(best.matched) → prefix drop")
                if let pnp = pnpRefinement {
                    self.applyPnPRefinement(pose: pnp, arPose: arPoseAtCapture)
                }
                self.handleTrackingMatchResult(
                    bestIdx: best.idx,
                    bestMatched: best.matched,
                    perKfMatches: perKfMatches,
                    arPoseAtCapture: arPoseAtCapture
                )
                self.isTrackingTickInFlight = false
            }
        }
    }

    /// PnP 결과로 localizedPose / matchedARPose 갱신 + path / checkpoint 재렌더.
    /// PoseEstimate.rotation 은 world→camera (W2C). server pose 응답 형식과 동일 convention 이라
    /// quaternion 그대로 qx/qy/qz/qw 로. translation 은 -R^T t_W2C 로 camera position in world.
    private func applyPnPRefinement(pose: PoseEstimate, arPose: simd_float4x4) {
        let R_W2C = pose.rotation
        let t_W2C = pose.translation
        let R_C2W = R_W2C.transpose
        let t_W = -(R_C2W * t_W2C)
        let q_W2C = simd_quatf(R_W2C)

        self.localizedPose = Pose(
            x: Double(t_W.x), y: Double(t_W.y), z: Double(t_W.z),
            qx: Double(q_W2C.imag.x), qy: Double(q_W2C.imag.y),
            qz: Double(q_W2C.imag.z), qw: Double(q_W2C.real)
        )
        self.matchedARPose = arPose
        print(String(format: "[PnP] refined → t_W=(%.2f,%.2f,%.2f) reproj=%.2fpx", t_W.x, t_W.y, t_W.z, pose.reprojectionError))

        // 보정된 pose 로 path / checkpoint 재렌더
        self.drawPathFromSteps(self.lastPathSteps)
        self.refreshFloorNavigationMap(routeSteps: self.lastPathSteps, currentFrame: arSession?.currentFrame)
        self.updateCheckpointNode()
    }

    /// runTrackingTick 의 main 큐 후속 처리. PnP 없이 best keyframe 까지 prefix drop +
    /// checkpoint 갱신 + localizedPose 갱신 + 도착 판정.
    private func handleTrackingMatchResult(
        bestIdx: Int,
        bestMatched: Int,
        perKfMatches: [(idx: Int, matched: Int)],
        arPoseAtCapture: simd_float4x4
    ) {
        // "지워나감" — best 까지 prefix drop. snapshot 인덱스(idx)는 매칭 시점 candidatesSnapshot 기준.
        // 본 main 큐 도달 시점에 trackingKeyframeCandidates 가 다른 흐름으로 변경됐을 가능성 — count 가드.
        guard bestIdx < trackingKeyframeCandidates.count else {
            return
        }
        trackingKeyframeCandidates = Array(trackingKeyframeCandidates[bestIdx...])
        lastBestKeyframeIndex = bestIdx
        _ = arPoseAtCapture  // 매 tick 변환 갱신 폐기 — checkpointNode 는 V3 측위 시점에 한 번 고정.

        // 후보 1개로 줄었으면 새 lookup 트리거 (현재 keyframe 영역 모두 통과한 상태)
        if trackingKeyframeCandidates.count <= 1 {
            triggerNewLookup()
        }

        // 도착 판정 — 후보 1개 이하 + query 좌표 모두 소비 + 카메라 ↔ checkpoint XZ 거리 < 임계
        if trackingKeyframeCandidates.count <= 1,
           consumedQueryPointIndex >= max(pathQueryPoints.count - 1, 0),
           let frame = arSession?.currentFrame,
           let checkpoint = checkpointNode {
            let cam = frame.camera.transform.columns.3
            let dx = cam.x - checkpoint.position.x
            let dz = cam.z - checkpoint.position.z
            let dist = sqrt(dx * dx + dz * dz)
            if dist < trackingArrivalThresholdM, !hasNotifiedArrival {
                hasNotifiedArrival = true
                stopTracking()
                delegate?.showArrivalNotification()
            }
        }
    }

    /// trackingKeyframeCandidates 를 진행 방향 정렬. 인덱스 0 = 시작쪽(목적지에서 먼 점),
    /// 마지막 인덱스 = 목적지쪽(가장 가까운 점). 사용자가 진행할수록 prefix drop.
    private func setupTrackingCandidates(bundle: LocalizationBundle) {
        let goalVec = simd_float3(
            Float(self.goal.x),
            Float(self.goal.y),
            Float(self.goal.z ?? 0)
        )
        let sorted = bundle.keyframes.sorted { (a, b) -> Bool in
            let da = distanceToGoal(kf: a, goal: goalVec)
            let db = distanceToGoal(kf: b, goal: goalVec)
            return da > db  // 거리 내림차순 — 인덱스 0 이 가장 멀고(시작쪽), 마지막이 가장 가까움(목적지쪽)
        }
        trackingKeyframeCandidates = sorted
        lastBestKeyframeIndex = nil
        updateCheckpointNode()
        // AR 마커 초기 표시 지연 방지 — 후보 정렬 직후 1회 발신.
        // 다음 1Hz processARFrame tick 까지 기다리지 않고 첫 마커가 즉시 등장하도록.
        if let frame = arSession?.currentFrame {
            let cam = simd_float3(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            let markers = makeActiveMarkerList(cameraPos: cam)
            delegate?.updateMarkers(markers)
        }
    }

    /// keyframe pose4x4 마지막 열 → simd_float3, goal 과 거리 계산.
    private func distanceToGoal(kf: BundleKeyframe, goal: simd_float3) -> Float {
        let kfTr = kf.pose4x4
        let kfPos = simd_float3(
            Float(kfTr[0][3]),
            Float(kfTr[1][3]),
            Float(kfTr[2][3])
        )
        return simd_distance(kfPos, goal)
    }

    /// 단일 흰색 원형 바닥 마커 갱신 → 시각 노드는 ARMarkerController 로 이관(다이아몬드 마커가 대체).
    /// 좌표 계산 로직만 보존 (도착 판정이 checkpointNode.position 을 참조하므로 placeholder 노드에 위치만 기록).
    /// 시각 렌더링(흰색 원형 geometry, scene.rootNode.addChildNode) 은 무력화.
    private func updateCheckpointNode() {
        guard let lastKf = trackingKeyframeCandidates.last,
              let arPose = matchedARPose,
              let pose = localizedPose else { return }

        let serverPos = simd_float3(
            Float(pose.x ?? 0),
            Float(pose.y ?? 0),
            Float(pose.z ?? 0)
        )
        let quat = simd_quatf(
            ix: Float(pose.qx ?? 0),
            iy: Float(pose.qy ?? 0),
            iz: Float(pose.qz ?? 0),
            r: Float(pose.qw ?? 1)
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPos,
            serverQuaternion: quat,
            arCameraPose: arPose
        )
        let kfTr = lastKf.pose4x4
        let kfPos = simd_float3(
            Float(kfTr[0][3]),
            Float(kfTr[1][3]),
            Float(kfTr[2][3])
        )
        let arPos = CoordinateTransformer.transform(serverPoint: kfPos, input: input)

        // 카메라 높이 → 바닥 레벨 추정 (drawPathNodes 동일 패턴)
        let cameraY = arPose.columns.3.y
        let floorY = cameraY - 1.7
        let placement = simd_float3(arPos.x, floorY, arPos.z)

        // placeholder 노드 — scene 에 추가하지 않음. arrival 판정에서 position 만 참조.
        if let node = checkpointNode {
            node.position = SCNVector3(placement.x, placement.y, placement.z)
        } else {
            let node = SCNNode()
            node.name = "checkpointPositionPlaceholder"
            node.position = SCNVector3(placement.x, placement.y, placement.z)
            checkpointNode = node
            // 의도적으로 scene?.rootNode.addChildNode(node) 미수행 — 시각 표현은 ARMarkerController 가 담당.
        }
    }

    /// pathfinding steps[].position 들을 server world → AR world 변환 후 sphere + cylinder line 으로 시각화.
    /// V3 측위 + lookup 직후 1회 호출. 매 tick 갱신 X.
    private func drawPathFromSteps(_ steps: [PathStep]) {
        lastPathSteps = steps
        print("[NAV] path with \(lastPathSteps.count) steps:")
        for (i, s) in lastPathSteps.enumerated() {
            let kind = Self.navigationActionKind(steps: lastPathSteps, at: i)
            let pStr = s.position.map { p in "(\(p.x ?? -999),\(p.y ?? -999))" } ?? "nil"
            print("[NAV]  [\(i)] floor=\(s.floorLevel ?? -1) pos=\(pStr) kind=\(kind) instruction=\"\(s.instruction ?? "")\"")
        }
        pathNodes.forEach { $0.removeFromParentNode() }
        pathNodes.removeAll()

        guard let arPose = matchedARPose, let pose = localizedPose else { return }

        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(
            ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
            iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose
        )
        let floorY = arPose.columns.3.y - 1.7

        let arPoints: [simd_float3] = steps.compactMap { step in
            guard let pos = step.position,
                  let x = pos.x, let y = pos.y, let z = pos.z else { return nil }
            let p = CoordinateTransformer.transform(
                serverPoint: simd_float3(Float(x), Float(y), Float(z)),
                input: input
            )
            return simd_float3(p.x, floorY, p.z)
        }
        guard arPoints.count >= 2 else { return }

        for p in arPoints {
            let sphere = SCNSphere(radius: 0.12)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.systemBlue
            mat.lightingModel = .constant
            mat.writesToDepthBuffer = false
            sphere.materials = [mat]
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(p.x, p.y, p.z)
            scene?.rootNode.addChildNode(node)
            pathNodes.append(node)
        }
        for i in 0..<(arPoints.count - 1) {
            let seg = lineSegmentNode(from: arPoints[i], to: arPoints[i + 1])
            scene?.rootNode.addChildNode(seg)
            pathNodes.append(seg)
        }
        print("[Path] drew \(steps.count) steps as \(arPoints.count) points + \(arPoints.count - 1) segments")

        // Phase 6: 경로가 새로 그려지면 step index 리셋 + 첫 vm 즉시 발신
        // 첫 vm 은 cameraPos 가 없어 fallback 거리 사용 (다음 1Hz tick 에서 정확한 거리로 갱신).
        currentStepIndex = 0
        if let vm = makeNavigationStepViewModel(cameraPos: nil) {
            delegate?.updateNavigationStep(vm)
        }
        // Phase 6: 새 경로 → turn arrow 정리. 다음 1Hz tick 에서 cameraPos 기반으로 재평가.
        delegate?.updateTurnArrow(nil)
        // Marker 도 동반 정리 — 다음 1Hz tick 에 makeActiveMarkerList 가 새로 발신.
        delegate?.updateMarkers([])
    }

    /// V3 측위 + pathfinding 후 디버깅 데이터 일괄 dump.
    /// 변환식 입력(matchedARPose, localizePose) + 출력(transformed AR points) + 매칭 사진 저장.
    private func dumpLocalizeDebug(rawSteps: [PathStepResponse]) {
        guard let response = lastLocalizeResponse,
              let arPose = matchedARPose,
              let pose = localizedPose else {
            print("[LocalizeDebug] dump skip — 누락된 데이터")
            return
        }

        // drawPathFromSteps 와 동일한 변환식 적용 (Y 는 floorY 가 아닌 변환된 그대로)
        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(
            ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
            iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose
        )
        let transformed: [(stepNumber: Int, ar: simd_float3)] = rawSteps.map { s in
            let ar = CoordinateTransformer.transform(
                serverPoint: simd_float3(Float(s.position.x), Float(s.position.y), Float(s.position.z)),
                input: input
            )
            return (s.stepNumber, ar)
        }

        let snapshot = LocalizeDebugLogger.Snapshot(
            matchedImageIndex: lastMatchedImageIndex,
            matchedImage: lastMatchedImage,
            matchedARPose: arPose,
            localizePose: response.pose,
            confidence: response.confidence,
            mapId: response.mapId,
            numMatches: response.numMatches,
            floorId: response.floorId,
            floorLevel: response.floorLevel,
            steps: rawSteps,
            transformedSteps: transformed
        )
        LocalizeDebugLogger.dump(snapshot)
    }

    /// 두 점 사이 cylinder. SCNCylinder 의 default 축은 Y. cross product 로 v 방향 회전.
    private func lineSegmentNode(from a: simd_float3, to b: simd_float3) -> SCNNode {
        let v = b - a
        let length = simd_length(v)
        let cyl = SCNCylinder(radius: 0.05, height: CGFloat(length))
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.7)
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        cyl.materials = [mat]
        let node = SCNNode(geometry: cyl)
        let mid = (a + b) * 0.5
        node.position = SCNVector3(mid.x, mid.y, mid.z)

        let yAxis = simd_float3(0, 1, 0)
        let dir = simd_normalize(v)
        let cross = simd_cross(yAxis, dir)
        let dot = simd_dot(yAxis, dir)
        if simd_length(cross) > 0.001 {
            let axis = simd_normalize(cross)
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, acos(max(-1, min(1, dot))))
        }
        return node
    }

    /// 흰색 원형 바닥 마커 — torus(테두리) + cylinder(채움 alpha 0.6).
    /// lightingModel = .constant, writesToDepthBuffer = false, isDoubleSided = true.
    private func createCheckpointNode(at position: simd_float3) -> SCNNode {
        let node = SCNNode()
        node.name = "checkpointNode"

        // 테두리 (torus)
        let torus = SCNTorus(ringRadius: 0.45, pipeRadius: 0.04)
        let torusMat = SCNMaterial()
        torusMat.diffuse.contents = UIColor.white
        torusMat.lightingModel = .constant
        torusMat.writesToDepthBuffer = false
        torusMat.isDoubleSided = true
        torus.materials = [torusMat]
        let torusNode = SCNNode(geometry: torus)
        node.addChildNode(torusNode)

        // 내부 채움 (얇은 원판)
        let disc = SCNCylinder(radius: 0.45, height: 0.005)
        let discMat = SCNMaterial()
        discMat.diffuse.contents = UIColor.white.withAlphaComponent(0.6)
        discMat.lightingModel = .constant
        discMat.writesToDepthBuffer = false
        discMat.isDoubleSided = true
        disc.materials = [discMat]
        let discNode = SCNNode(geometry: disc)
        node.addChildNode(discNode)

        node.position = SCNVector3(position.x, position.y, position.z)
        return node
    }

    /// 후보 1개 이하 도달 시 — 다음 query 좌표(또는 목적지) 로 새 lookup. 결과로 후보 갱신.
    private func triggerNewLookup() {
        consumedQueryPointIndex += 1
        let nextQueryPoint: NetworkBundleProvider.QueryPoint
        if consumedQueryPointIndex < pathQueryPoints.count {
            nextQueryPoint = pathQueryPoints[consumedQueryPointIndex]
        } else {
            nextQueryPoint = NetworkBundleProvider.QueryPoint(
                floorLevel: localizedFloorLevel ?? 1,
                x: self.goal.x,
                y: self.goal.y,
                z: self.goal.z ?? 0
            )
        }
        let provider = NetworkBundleProvider(
            buildingId: self.buildingId,
            queryPoints: [nextQueryPoint],
            radiusM: 5.0,
            maxKeyframesPerQuery: 5
        )
        self.networkBundleProvider = provider
        print("[NetworkBundle] new lookup (consumed=\(consumedQueryPointIndex)/\(pathQueryPoints.count))")
        provider.fetch { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let bundle):
                self.localizationBundle = bundle
                self.keyframeDescriptorCache = bundle.keyframes.map {
                    Data(base64Encoded: $0.descriptorsB64) ?? Data()
                }
                self.setupTrackingCandidates(bundle: bundle)
                print("[NetworkBundle] new keyframes=\(bundle.keyframes.count)")
            case .failure(let err):
                print("[NetworkBundle] new lookup 실패: \(err) — 기존 후보 유지")
            }
        }
    }

    // MARK: - Phase 6 UI 모델

    /// RTAB-Map 컨벤션: server.z 는 수직, 수평 평면은 server.x, server.y. 1m 미만 segment 는 noise → straight 로 분류 (도어웨이/클러스터 필터).
    /// i 부터 양방향 walk 으로 ≥1m 떨어진 의미 있는 step 의 position 을 inbound/outbound 로 사용.
    /// 서버가 코너에 노드 클러스터 박는 케이스 대응. cross > 0 → LEFT 가정.
    private static func navigationActionKind(steps: [PathStep], at i: Int) -> NavigationActionKind {
        let lastIdx = steps.count - 1
        guard i >= 0, i <= lastIdx else { return .unknown }
        let curr = steps[i]

        if i >= lastIdx { return .arrive }

        let next = steps[i + 1]
        if let cf = curr.floorLevel, let nf = next.floorLevel, cf != nf {
            return nf > cf ? .stairsUp : .stairsDown
        }

        guard let cx = curr.position?.x, let cy = curr.position?.y else { return .unknown }

        var prevPos: (Double, Double)? = nil
        var j = i - 1
        while j >= 0 {
            if let px = steps[j].position?.x, let py = steps[j].position?.y {
                let dx = cx - px, dy = cy - py
                if (dx*dx + dy*dy) >= 1.0 { prevPos = (px, py); break }
            }
            j -= 1
        }
        if prevPos == nil { return .straight }

        var nextPos: (Double, Double)? = nil
        var k = i + 1
        while k <= lastIdx {
            if let nx = steps[k].position?.x, let ny = steps[k].position?.y {
                let dx = nx - cx, dy = ny - cy
                if (dx*dx + dy*dy) >= 1.0 { nextPos = (nx, ny); break }
            }
            k += 1
        }
        if nextPos == nil { return .straight }

        let (px, py) = prevPos!
        let (nx, ny) = nextPos!
        let ix = cx - px, iy = cy - py
        let ox = nx - cx, oy = ny - cy
        let cross = ix * oy - iy * ox
        let dot = ix * ox + iy * oy
        let angleDeg = atan2(cross, dot) * 180.0 / .pi
        let absA = abs(angleDeg)

        if absA < 25.0 { return .straight }
        if absA < 50.0 { return cross > 0 ? .turnSlightLeft : .turnSlightRight }
        if absA < 135.0 { return cross > 0 ? .turnLeft : .turnRight }
        return .uturn
    }

    /// 5m 이내 turn step 진입 시 AR 공간에 띄울 3D 화살표 vm.
    /// `currentStepIndex` 부터 마지막 step 까지 첫 turn(좌/우/살짝좌/살짝우/유턴) 을 검색,
    /// 카메라 ↔ turn step XZ 거리 ≤ 5m 일 때만 vm 생성. 그 외엔 nil 반환.
    /// arPosition Y 는 floorY + 1m (사용자 시야 가까이).
    private func makeTurnArrowViewModel(cameraPos: simd_float3?) -> TurnArrowViewModel? {
        guard let cam = cameraPos,
              let arPose = matchedARPose,
              let pose = localizedPose else { return nil }
        guard !lastPathSteps.isEmpty else { return nil }

        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(
            ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
            iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose
        )

        let lastIdx = lastPathSteps.count - 1
        let startIdx = max(0, min(currentStepIndex, lastIdx))

        for i in startIdx...lastIdx {
            let s = lastPathSteps[i]
            let kind = Self.navigationActionKind(steps: lastPathSteps, at: i)
            let mapped: (TurnDirection, TurnArrowKind)?
            switch kind {
            case .turnLeft:        mapped = (.left, .sharp)
            case .turnRight:       mapped = (.right, .sharp)
            case .turnSlightLeft:  mapped = (.left, .slight)
            case .turnSlightRight: mapped = (.right, .slight)
            case .uturn:           mapped = (.uTurn, .uturn)
            default:               mapped = nil
            }
            guard let (direction, arrowKind) = mapped else { continue }

            // 첫 turn step 발견 — 거리 검사 후 결정. 5m 초과면 nil (그 너머 turn 은 무시).
            guard let p = s.position,
                  let sx = p.x, let sy = p.y, let sz = p.z else { return nil }
            let serverPoint = simd_float3(Float(sx), Float(sy), Float(sz))
            let arPoint = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            let dx = cam.x - arPoint.x
            let dz = cam.z - arPoint.z
            let distXZ = Double(sqrt(dx * dx + dz * dz))
            if distXZ > Self.turnArrowLookaheadM { return nil }

            let floorY = arPose.columns.3.y - 1.7
            let arPosition = simd_float3(arPoint.x, floorY + 1.0, arPoint.z)
            return TurnArrowViewModel(
                direction: direction,
                kind: arrowKind,
                arPosition: arPosition,
                stepIndex: i
            )
        }
        return nil
    }

    // MARK: - AR 마커 후보 발신 (사양 §3)
    /// 1Hz tick 마다 호출. DistanceMarker / NextArrow 후보 1~2개를 단일 ARMarkerNode 리스트로 발신.
    /// 후보 선택 규칙:
    ///   - turn step (좌/우/살짝좌/살짝우) 이 `currentStepIndex` 이후에 존재하면 그 step 좌표를 .nextTurn 으로 발신.
    ///   - 그 외 (turn 없음 / 마지막 도착 step) → trackingKeyframeCandidates.last 좌표를 .distance 로 발신.
    /// kind 의 meters 값은 controller 가 raw 거리로 재계산하므로 round(d) 로 채워 보낸다.
    /// 카메라 ↔ marker XZ 거리 50m 초과시 hidden 후보로 만들지 않고 빈 배열 반환 (controller 가 정리).
    private func makeActiveMarkerList(cameraPos: simd_float3) -> [ARMarkerNode] {
        guard let arPose = matchedARPose, let pose = localizedPose else { return [] }
        guard !lastPathSteps.isEmpty else { return [] }

        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(
            ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
            iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose
        )
        let floorY = arPose.columns.3.y - 1.7
        // 사용자 시선 가까이로 띄움 (turn arrow 와 동일 패턴)
        let markerY = floorY + 1.0

        // 1) NextArrow 후보 — currentStepIndex 이후 첫 turn step
        let lastIdx = lastPathSteps.count - 1
        let startIdx = max(0, min(currentStepIndex, lastIdx))
        for i in startIdx...lastIdx {
            let kind = Self.navigationActionKind(steps: lastPathSteps, at: i)
            let dir: TurnDirection?
            switch kind {
            case .turnLeft, .turnSlightLeft:   dir = .left
            case .turnRight, .turnSlightRight: dir = .right
            case .uturn:                        dir = .uTurn  // controller 가 hidden 처리
            default:                            dir = nil
            }
            guard let direction = dir else { continue }
            guard let p = lastPathSteps[i].position,
                  let sx = p.x, let sy = p.y, let sz = p.z else { return [] }
            let serverPoint = simd_float3(Float(sx), Float(sy), Float(sz))
            let arPoint = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            let worldPos = simd_float3(arPoint.x, markerY, arPoint.z)
            let dx = cameraPos.x - worldPos.x
            let dz = cameraPos.z - worldPos.z
            let d = sqrt(dx * dx + dz * dz)
            if d > 50.0 { return [] }
            // turn step 발견 — NextArrow 후보 단일 발신 (controller 가 거리 임계로 distance/nextTurn 결정).
            let id = "step_\(i)"
            // 거리 50m 이하: 항상 발신. controller 가 d>10 이면 distance 로, d≤10 이면 nextTurn 으로 결정.
            // controller 가 raw kind 의 direction 을 신뢰하므로 nextTurn 으로 발신.
            return [ARMarkerNode(id: id, worldPosition: worldPos, kind: .nextTurn(direction: direction))]
        }

        // 2) turn step 없음 → DistanceMarker 후보 (trackingKeyframeCandidates.last → 목적지 쪽 keyframe)
        if let lastKf = trackingKeyframeCandidates.last {
            let kfTr = lastKf.pose4x4
            let kfPos = simd_float3(Float(kfTr[0][3]), Float(kfTr[1][3]), Float(kfTr[2][3]))
            let arPoint = CoordinateTransformer.transform(serverPoint: kfPos, input: input)
            let worldPos = simd_float3(arPoint.x, markerY, arPoint.z)
            let dx = cameraPos.x - worldPos.x
            let dz = cameraPos.z - worldPos.z
            let d = sqrt(dx * dx + dz * dz)
            if d > 50.0 { return [] }
            let id = "kf_\(lastKf.index)"
            return [ARMarkerNode(id: id, worldPosition: worldPos, kind: .distance(meters: Int(d.rounded())))]
        }

        return []
    }

    /// 시맨틱: `currentStepIndex` 는 "다음에 도달해야 할 step".
    /// 카드 idx 는 기본적으로 currentStepIndex 이지만, 그 액션이 turn 이 아니라면 5m 이내 lookahead 로
    /// 곧 다가올 turn(좌/우/살짝좌/살짝우/유턴) 을 미리 표시해 사용자가 준비할 시간을 확보.
    /// 카드 거리 = 카메라 ↔ step[idx] XZ. cameraPos 가 nil 이면 server-world segment 거리로 fallback.
    private func makeNavigationStepViewModel(cameraPos: simd_float3?) -> NavigationStepViewModel? {
        guard !lastPathSteps.isEmpty else { return nil }
        var idx = max(0, min(currentStepIndex, lastPathSteps.count - 1))
        let lastIdx = lastPathSteps.count - 1

        // CoordinateTransformer.Input — cameraPos + 측위 정보 가용 시 1회 구성, lookahead 와 dist 양쪽에서 재사용.
        let xform: CoordinateTransformer.Input? = {
            guard cameraPos != nil, let arPose = matchedARPose, let pose = localizedPose else { return nil }
            let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
            let quat = simd_quatf(
                ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
                iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
            )
            return CoordinateTransformer.Input(
                serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose
            )
        }()

        func action(at i: Int) -> NavigationActionKind {
            if i >= lastIdx { return .arrive }
            return Self.navigationActionKind(steps: lastPathSteps, at: i)
        }

        func cameraDistance(toStep i: Int) -> Double? {
            guard let cam = cameraPos, let input = xform else { return nil }
            guard let pos = lastPathSteps[i].position,
                  let sx = pos.x, let sy = pos.y, let sz = pos.z else { return nil }
            let serverPoint = simd_float3(Float(sx), Float(sy), Float(sz))
            let arPoint = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            let dx = cam.x - arPoint.x
            let dz = cam.z - arPoint.z
            return Double(sqrt(dx * dx + dz * dz))
        }

        /// lookahead 전용 거리 측정. 카메라 ↔ step 직선거리 우선, 불가하면 prev↔target server-world fallback.
        /// 카드 dist 계산과 동일한 fallback 정책으로 통일하여 lookahead 가 cameraPos/측위 미가용 시에도 동작.
        func lookaheadDistance(toStep i: Int) -> Double? {
            if let d = cameraDistance(toStep: i) { return d }
            guard i > 0 else { return nil }
            guard let a = lastPathSteps[i - 1].position, let b = lastPathSteps[i].position,
                  let ax = a.x, let ay = a.y, let bx = b.x, let by = b.y else { return nil }
            let dx = bx - ax
            let dy = by - ay
            return Double((dx * dx + dy * dy).squareRoot())
        }

        let isTurn: (NavigationActionKind) -> Bool = { a in
            switch a {
            case .turnLeft, .turnRight, .turnSlightLeft, .turnSlightRight, .uturn: return true
            default: return false
            }
        }

        // 카드 표시 idx: currentStepIndex 부터 첫 "실제 이벤트" (turn 또는 arrive) 찾기.
        // 멀면 .straight 로 강등 표시 (turn 은 ≤10m, arrive 는 ≤2m 일 때만 실제 액션).
        let baseIdx = idx
        var eventIdx = lastIdx
        for i in baseIdx...lastIdx {
            let a = action(at: i)
            if isTurn(a) || a == .arrive { eventIdx = i; break }
        }
        idx = eventIdx
        print("[NAV] event: cur=\(currentStepIndex) baseIdx=\(baseIdx) eventIdx=\(eventIdx) action=\(action(at: eventIdx))")

        let target = lastPathSteps[idx]
        let isLast = (idx >= lastIdx)

        // 카드 거리 — 카메라 ↔ target. 변환 안되면 prev↔target server-world fallback.
        let dist: Double = cameraDistance(toStep: idx) ?? {
            if idx > 0,
               let a = lastPathSteps[idx - 1].position, let b = target.position,
               let ax = a.x, let ay = a.y, let bx = b.x, let by = b.y {
                let dx = bx - ax
                let dy = by - ay
                return (dx * dx + dy * dy).squareRoot()
            }
            return 0
        }()

        let approxSteps = max(1, Int((dist / Self.walkStrideM).rounded()))

        // 잔여 총 거리 — 카메라 ↔ target + (target↔end 인접 segment 합)
        var remainingTotal: Double = dist
        if idx < lastIdx {
            for i in idx..<lastIdx {
                guard let a = lastPathSteps[i].position,
                      let b = lastPathSteps[i + 1].position,
                      let ax = a.x, let ay = a.y,
                      let bx = b.x, let by = b.y else { continue }
                let dx = bx - ax
                let dy = by - ay
                remainingTotal += (dx * dx + dy * dy).squareRoot()
            }
        }

        let remainingMinutes = max(1, Int((remainingTotal / Self.walkSpeedMps / 60.0).rounded()))
        let remainingExtraStepsCount = max(0, lastIdx - idx)
        let destinationFloorLevel = lastPathSteps.last?.floorLevel
        let nativeAction: NavigationActionKind = isLast ? .arrive : action(at: idx)
        let resolvedAction: NavigationActionKind = {
            if isTurn(nativeAction) {
                return dist <= 10.0 ? nativeAction : .straight
            }
            if nativeAction == .arrive {
                return dist <= 2.0 ? .arrive : .straight
            }
            return nativeAction
        }()

        return NavigationStepViewModel(
            action: resolvedAction,
            distanceMeters: dist,
            approxSteps: approxSteps,
            remainingTotalMeters: remainingTotal,
            remainingMinutes: remainingMinutes,
            remainingExtraStepsCount: remainingExtraStepsCount,
            destinationFloorLevel: destinationFloorLevel,
            destinationName: self.destinationName
        )
    }

    /// `currentStepIndex` advance: 카메라가 target step 의 advanceThreshold 이내에 들어오면 +1.
    /// while 루프로 한 tick 에 여러 step 을 한꺼번에 통과 가능 (시작점 근처에서 step[0] 즉시 통과 등).
    /// localizedFloorLevel 과 다른 floor step 은 한 칸씩 그냥 advance (층 전환 모달이 별도 처리).
    private func recomputeCurrentStepIndex(cameraPos: simd_float3) {
        guard !lastPathSteps.isEmpty else { return }
        guard let arPose = matchedARPose, let pose = localizedPose else { return }

        let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
        let quat = simd_quatf(
            ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
            iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose
        )

        // ARMarkerController.resolveKind 의 3m passed 임계와 정합 — controller 가 마커를 fadeOut
        // 시킨 시점에 logic 도 즉시 step 진행시켜 다음 turn step 의 ARMarkerNode 후보가
        // 끊김 없이 발신되도록. (이전 2.0m 일 때 3m~2m 구간 데드존 발생)
        let advanceThreshold: Float = 3.0
        let lastIdx = lastPathSteps.count - 1
        while currentStepIndex < lastIdx {
            let target = lastPathSteps[currentStepIndex]
            // 다른 floor 의 step 은 도달 판정 불가 → 한 칸 advance (현재 floor 의 다음 step 으로 진행).
            if let stepFloor = target.floorLevel, let curFloor = localizedFloorLevel,
               stepFloor != curFloor {
                currentStepIndex += 1
                continue
            }
            guard let pos = target.position,
                  let sx = pos.x, let sy = pos.y, let sz = pos.z else {
                // 좌표 누락 step 은 통과
                currentStepIndex += 1
                continue
            }
            let serverPoint = simd_float3(Float(sx), Float(sy), Float(sz))
            let arPoint = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            let dx = cameraPos.x - arPoint.x
            let dz = cameraPos.z - arPoint.z
            let d = sqrt(dx * dx + dz * dz)
            if d < advanceThreshold {
                currentStepIndex += 1
            } else {
                break
            }
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

    // MARK: - 경로 단순화 (RDP)

    /// XZ 2D RDP(Ramer-Douglas-Peucker) 단순화. spline 입력 사전 정제용.
    /// 시각 경로/턴 판정 모두 단순화 결과 기반 — 양자화 격자(0.25m)·미세 단차로 인한
    /// 코너 오탐과 경로 노이즈를 흡수. 시작/끝 점은 항상 보존.
    private func simplifyXZ(points: [simd_float3], epsilon: Float) -> [simd_float3] {
        if points.count < 3 { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        rdpRecurse(points, 0, points.count - 1, epsilon, &keep)
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    private func rdpRecurse(_ pts: [simd_float3], _ start: Int, _ end: Int, _ eps: Float, _ keep: inout [Bool]) {
        guard end > start + 1 else { return }
        var maxDist: Float = 0
        var maxIdx: Int = start
        for i in (start + 1)..<end {
            let d = perpendicularDistanceXZ(point: pts[i], lineStart: pts[start], lineEnd: pts[end])
            if d > maxDist { maxDist = d; maxIdx = i }
        }
        if maxDist > eps {
            keep[maxIdx] = true
            rdpRecurse(pts, start, maxIdx, eps, &keep)
            rdpRecurse(pts, maxIdx, end, eps, &keep)
        }
    }

    private func perpendicularDistanceXZ(point p: simd_float3, lineStart a: simd_float3, lineEnd b: simd_float3) -> Float {
        let abx = b.x - a.x, abz = b.z - a.z
        let apx = p.x - a.x, apz = p.z - a.z
        let lineLen = sqrt(abx * abx + abz * abz)
        if lineLen < 1e-5 {
            return sqrt(apx * apx + apz * apz)
        }
        let cross = abs(abx * apz - abz * apx)
        return cross / lineLen
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

    // MARK: - 목적지 3D 핀 마커 (Phase 8 단일 checkpointNode 로 대체 — createDestinationPin 폐기)

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
            guidanceDirector.reset()
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
