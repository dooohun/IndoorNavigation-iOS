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

/// 캡처/측위 진행 단계. nil 전달 시 진행 표시 hide.
/// - capturing: 사진 캡처 중 (0 → 35% 자동 애니메이션)
/// - localizing: 서버 V3 측위 요청 in-flight (35 → 95% 자동 애니메이션, 응답 시 100% snap)
enum CaptureProgressPhase {
    case capturing
    case localizing
}

protocol ARNavigationLogicDelegate: AnyObject {
    func updateStatus(_ message: String, color: UIColor)
    func setLoading(_ loading: Bool)
    func setCaptureProgress(phase: CaptureProgressPhase?)
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
    func showFloorNavigationMap(_ map: FloorMapResponse, routeSteps: [PathStep], currentPosition: Position?, currentHeadingDegrees: Float?, destinationName: String?, destinationWorldPoint: CGPoint?)
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

    #if DEBUG
    /// Mock localize fixture 사용 (2026-05-13 사용자 JSON). true 면 스캔→캡처/네트워크 모두 우회.
    /// 즉시 fixture 데이터로 handleLocalizeV3Success 동등 상태 세팅 + drawPathFromSteps 호출.
    /// real 흐름 복귀: false 로 토글.
    static let useMockLocalizeFixture: Bool = false
    #endif

    weak var delegate: ARNavigationLogicDelegate?
    weak var arSession: ARSession?
    weak var scene: SCNScene?

    let buildingId: String
    let floorId: String
    let destinationName: String
    let destinationId: String
    let goal: Coordinate
    /// 사용자가 시작 화면에서 선택한 현재 위치 층의 floorId. localize V3 의 첫 hint 로 사용.
    /// nil ("모르겠어요") 이면 서버 ANY 매칭으로 폴백.
    let userCurrentFloorId: String?
    let userCurrentFloorLevel: Int?
    /// 수직 이동 수단 (엘리베이터 / 계단) 우선순위. POI 선택 시 사용자 토글로 결정 → pathfinding 요청에 그대로 전달.
    let verticalPreference: VerticalPreference

    init(buildingId: String,
         floorId: String,
         destinationName: String,
         destinationId: String,
         goal: Coordinate,
         userCurrentFloorId: String? = nil,
         userCurrentFloorLevel: Int? = nil,
         verticalPreference: VerticalPreference = .elevator) {
        self.buildingId = buildingId
        self.floorId = floorId
        self.destinationName = destinationName
        self.destinationId = destinationId
        self.goal = goal
        self.userCurrentFloorId = userCurrentFloorId
        self.userCurrentFloorLevel = userCurrentFloorLevel
        self.verticalPreference = verticalPreference
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
    private var localizedAreaId: String?  // V3 응답 areaId — pathfinding/map 호출에 동반.
    private var capturedImages: [UIImage] = []
    private var capturedARPoses: [simd_float4x4] = []
    /// LiDAR sceneDepth FP32 raw bytes. capturedImages 와 같은 인덱스로 채움.
    /// LiDAR 미지원 단말 / sceneDepth 미활성이면 빈 배열 — server multipart 에 첨부 안 함.
    private var capturedDepths: [Data] = []
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
    private var allSteps: [PathStep] = []
    private var allARPoints: [simd_float3] = []
    private var destinationPinNode: SCNNode?

    // PathChevron 시스템 (sphere + line path 시각화 대체)
    private let pathChevronController = PathChevronController()
    /// 최근 1Hz tick 시점의 카메라 XZ 위치 캐시 — drawPathFromSteps 가 chevron 분포 카메라 기준 spawn cursor 결정에 사용.
    private var lastCameraPos: simd_float3?

    // 층 이동 인터렉션
    private var hasActiveFloorTransition: Bool = false
    private var pendingRemainingSteps: [PathStep] = []
    private var pendingTargetFloor: Int? = nil
    /// 층 전환 트리거 시 cached floor map 의 connectors[].stops[] 에서 lookup 한 target 층 floorId.
    /// 다음 측위(restartFromFloorTransition 직후)의 floor hint 로 사용 — 옛 userCurrentFloorId 가 stale 인 문제 해결.
    private var pendingTargetFloorId: String? = nil
    private var isFloorTransitionRestart: Bool = false
    /// 층 전환 모달 트리거 거리 (m). stairs/elevator 노드 step 위치와 카메라 사이 XZ 거리.
    /// 이 값 이내일 때만 detectFloorTransition 이 트리거. 너무 빡빡하면 빨리 걷는 사용자가 통과 가능, 너무 넓으면 일찍 뜸.
    private let floorTransitionTriggerDistance: Float = 2.0

    // 경로 시작점 진단
    private var lastStartSnapDistance: Double?

    // 방향 안내 (Phase 5)
    private let guidanceDirector = GuidanceDirector()

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

    // MARK: - Wall centering (drift 보정 — LiDAR mesh 기반)
    private var wallCenteringController: WallCenteringController?
    private var floorMapPolygonRingsCache: [[CGPoint]] = []

    // MARK: - 주기 재측위 (V3 only)
    /// LightGlue 기반 추적이 비활성된 상태에서 ARKit pose 누적 drift 를 보정하는 주기적 V3 측위.
    /// `startPeriodicRelocalize` 가 초기 측위 성공 후 타이머 시작 → cadence 마다 3장 캡처 → V3 호출.
    /// 응답 pose 는 기존 `localizedPose` 와 `blendAlpha` 로 SLERP/lerp blend (서서히 보정).
    /// `matchedARPose` 도 같은 alpha 로 blend 해 서버 pose 와 AR pose pair 의 정합성을 유지.
    private let periodicRelocalizeIntervalSec: TimeInterval = 2.0
    private let periodicRelocalizeImageCount: Int = 3
    private let periodicRelocalizeCaptureInterval: TimeInterval = 0.4
    /// 한 번 점프 크기 축소 — 1단계 quick win (0.3 → 0.18). 더 자주 blend 되더라도 한 번 변화량 작게.
    private let periodicRelocalizeBlendAlpha: Float = 0.18
    /// 주기 V3 재측위 응답이 prev 와 이만큼(XYZ) 차이나면 blend 우회하고 hard-set. 큰 변화는 정확한 측위로 간주하고 즉시 반영.
    /// 좌회전 후 첫 측위 같은 케이스 — blend 끌어당김으로 인한 wrong-jump 회피.
    /// 1단계 quick win — 2.0 → 3.0 상향. hard-set(즉시 점프) 발동 빈도 감소.
    private let periodicRelocalizeHardSetThresholdM: Float = 3.0
    /// 주기 V3 재측위 confidence 가드. 초기 측위와 같은 기준으로 wrong-match 위험 응답을 무시.
    private let periodicRelocalizeMinConfidence: Double = 0.65
    /// 주기 V3 재측위 feature match 수 가드. confidence 만으로는 pose jump 를 충분히 설명하지 못해 병행 검증.
    private let periodicRelocalizeMinMatches: Int = 80
    /// 이전 pose 대비 서버 회전 변화가 이 값보다 크면 wrong-match 가능성이 높아 무시.
    private let periodicRelocalizeMaxRotationDeltaDeg: Float = 45.0
    /// 서버 pose 이동량이 ARKit 캡처 pose 이동량보다 이 값 이상 더 크고 ratio 도 크면 무시.
    private let periodicRelocalizeMaxServerARDistanceGapM: Float = 2.5
    private let periodicRelocalizeMaxServerARDistanceRatio: Float = 2.5
    /// 직전 주기 측위 발사 시점 카메라 위치(XZ) 와의 최소 이동 거리. 정지 상태 V3 호출 회피.
    private static let periodicRelocalizeMinTravelM: Float = 2.0
    /// 캡처 시작 후 N장 도달까지 허용 timeout. limited tracking 무한 대기 → in-flight 락 영구 점유 방지.
    private static let periodicRelocalizeCaptureTimeoutSec: TimeInterval = 5.0
    private var periodicRelocalizeTimer: Timer?
    private var periodicRelocalizeCaptureTimer: Timer?
    private var isPeriodicRelocalizeInFlight: Bool = false
    private var periodicCapturedImages: [UIImage] = []
    private var periodicCapturedARPoses: [simd_float4x4] = []
    /// 주기 V3 재측위용 LiDAR sceneDepth FP32 raw bytes. periodicCapturedImages 와 짝.
    private var periodicCapturedDepths: [Data] = []
    /// 직전 주기 측위 발사 시점 카메라 위치 캐시(XZ만 사용). nil 이면 첫 cadence 강제 통과.
    private var lastPeriodicRelocalizeCameraPos: simd_float3?
    /// 캡처 시작 시각(Date timeIntervalSince1970). timeout 판정에 사용. 정상/abort 시 nil 로 정리.
    private var periodicCaptureStartTime: TimeInterval?

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

    /// PathChevron 시스템 부모 노드 등록. ViewController 가 sceneView 준비 후 1회 호출.
    func attachChevronParent(_ parent: SCNNode) {
        pathChevronController.attach(to: parent)
    }

    /// PathChevron 가시성 토글. setHUDVisible(false) 와 짝으로 호출 — chevron 도 동반 숨김.
    func setChevronHidden(_ hidden: Bool) {
        pathChevronController.setHidden(hidden)
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
                // Floor-transition 자동 트리거: currentStepIndex 가 floor 변경 직전 step 도달 시 모달 표시
                if !hasActiveFloorTransition,
                   let info = detectFloorTransition(currentStepIdx: currentStepIndex, cameraPos: cam) {
                    triggerFloorTransition(type: info.type, targetFloor: info.targetFloor, currentStepIdx: currentStepIndex)
                }
                if let vm = makeNavigationStepViewModel(cameraPos: cam) {
                    delegate?.updateNavigationStep(vm)
                }
                let turnVM = makeTurnArrowViewModel(cameraPos: cam)
                delegate?.updateTurnArrow(turnVM)
                let markers = makeActiveMarkerList(cameraPos: cam)
                delegate?.updateMarkers(markers)
                // PathChevron: 가장 앞 chevron 통과 시 제거 + 신규 spawn.
                pathChevronController.tickCamera(cameraPos: cam)
                // 다음 drawPathFromSteps (PnP 재호출 등) 가 chevron 분포 cursor 결정에 사용할 카메라 캐시.
                lastCameraPos = cam
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
        checkpointNode?.removeFromParentNode()
        checkpointNode = nil
        destinationPinNode = nil
        pathChevronController.clear()
        delegate?.updateTurnArrow(nil)
        delegate?.updateMarkers([])

        // timer 정지
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        captureTimer?.invalidate()
        captureTimer = nil
        stopPeriodicRelocalize()
        wallCenteringController?.stop()
        wallCenteringController = nil
        floorMapPolygonRingsCache = []

        // 상태 클리어
        allSteps = []
        allARPoints = []
        matchedARPose = nil
        localizedPose = nil
        localizedAreaId = nil
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
        capturedDepths = []
        lastCaptureTimestamp = nil

        // GuidanceDirector 도 reset (Phase 5 dead path 지만 호출 부수효과 없게)
        guidanceDirector.reset()
    }

    func startLocalizationFlow() {
        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        // 이미 측위 진행 중(=localizedPose 존재 + 활성 경로 보유)이면 hard reset 금지.
        // 사용자가 locate 버튼을 재탭한 경우 path/marker/chevron/currentStepIndex 전부 유지하고
        // 즉시 1회 주기 측위만 강제 트리거해서 ARKit world origin drift 를 보정한다.
        // (resetForNewTrial → 서버 wrong-match → 새 19-step 경로 발급으로 인한 60m 오안내 방지)
        if localizedPose != nil && !lastPathSteps.isEmpty {
            forcePeriodicRelocalizeNow()
            return
        }

        #if DEBUG
        if Self.useMockLocalizeFixture {
            trialNumber += 1
            resetForNewTrial()
            injectMockLocalizeFixture()
            return
        }
        #endif

        trialNumber += 1
        resetForNewTrial()

        delegate?.setLocateButtonVisible(false)
        delegate?.setLoading(true)
        delegate?.setScanningOverlay(visible: true)
        delegate?.updateStatus("천천히 주변을 둘러보세요", color: .white)
        delegate?.setCaptureProgress(phase: .capturing)

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
        if let depthPB = frame.sceneDepth?.depthMap,
           let depthData = Self.depthMapData(from: depthPB) {
            capturedDepths.append(depthData)
        }
        lastCaptureTimestamp = frame.timestamp

        let count = capturedImages.count
        // count 기반 progress 미사용 — VC 가 시간 기반 multi-phase 자동 애니메이션 담당.
        delegate?.updateStatus("천천히 주변을 둘러보세요", color: .white)

        if count >= maxImages {
            stopCapture()
            sendToServer()
        }
    }

    /// `kCVPixelFormatType_DepthFloat32` CVPixelBuffer → FP32 raw little-endian bytes.
    /// row stride padding 이 width*4 와 다를 수 있어 row 단위로 복사.
    /// 다른 픽셀 포맷(혹은 nil) 이면 nil 반환 — multipart 첨부 skip.
    static func depthMapData(from pixelBuffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * MemoryLayout<Float32>.size
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        var data = Data(count: height * rowBytes)
        data.withUnsafeMutableBytes { destRaw in
            guard let destBase = destRaw.baseAddress else { return }
            for row in 0..<height {
                let src = base.advanced(by: row * bytesPerRow)
                let dst = destBase.advanced(by: row * rowBytes)
                memcpy(dst, src, rowBytes)
            }
        }
        return data
    }

    func stopCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        delegate?.setCaptureProgress(phase: nil)
    }

    /// V3 측위 흐름 — multipart 업로드 + SLAMLocalizeResponse 핸들링.
    private func sendToServer() {
        guard !capturedImages.isEmpty else {
            delegate?.setLoading(false)
            delegate?.setCaptureProgress(phase: nil)
            delegate?.setScanningOverlay(visible: false)
            delegate?.showScanFailed(message: "캡처된 이미지가 없어요.\n다시 시도해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // 캡처 완료 → 서버 측위 phase 전환 (VC 가 progress bar 35→95% 자동 애니메이션)
        delegate?.setCaptureProgress(phase: .localizing)

        // 신서버 floorId 는 uuid 문자열. 우선순위:
        //   1) localizedFloorId — 최근 측위 성공 결과 (정상 흐름)
        //   2) pendingTargetFloorId — 층 전환 직후, connector 데이터에서 lookup 한 새 층 floorId (transition restart 케이스)
        //   3) userCurrentFloorId — 앱 시작 시 사용자가 선택한 시작 층 (초기 측위 케이스)
        //   4) nil — 서버 ANY 매칭
        let floorIdHint: String? = {
            if let f = localizedFloorId, !f.isEmpty { return f }
            if let f = pendingTargetFloorId, !f.isEmpty { return f }
            return (userCurrentFloorId?.isEmpty == false) ? userCurrentFloorId : nil
        }()
        let depthsForUpload: [Data]? = capturedDepths.isEmpty ? nil : capturedDepths

        NetworkManager.shared.localizeV3(
            buildingId: buildingId,
            images: capturedImages,
            depths: depthsForUpload,
            mapId: nil,
            floorId: floorIdHint
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.delegate?.setCaptureProgress(phase: nil)
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
        guard response.confidence >= 0.65 else {
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
        localizedFloorId = response.floorId ?? self.floorId
        localizedFloorLevel = response.floorLevel
        localizedAreaId = response.areaId
        // 측위 성공 시 pendingTargetFloorId 클리어 — localizedFloorId 가 권위 source 가 됨.
        pendingTargetFloorId = nil

        delegate?.showScanComplete()

        // 층 전환 후 재측위든 초기 측위든 동일 흐름 — 새 위치 기준 pathfinding 호출하여
        // 잔여 경로(같은 층 → 다음 층 전환점 / 또는 최종 목적지)를 서버에서 자동 재계산.
        // AR chevron + 2D mini-map 은 결과를 받아 drawPathFromSteps / showFloorNavigationMap 로 갱신.
        if isFloorTransitionRestart {
            isFloorTransitionRestart = false
            pendingRemainingSteps = []
        }

        delegate?.showRouteCalculating(false)
        delegate?.setLoading(false)
        delegate?.updateStatus("\(destinationName) 방향으로 이동하세요.", color: .white)
        delegate?.setHUDVisible(true)
        startV3Pathfinding(startFloorLevel: response.floorLevel,
                           translation: translation,
                           areaId: response.areaId)
        // 주기 V3 재측위 활성화 — 10s cadence + 2m 이동 가드 + blend.
        if let mPose = self.matchedARPose {
            let c = mPose.columns.3
            lastPeriodicRelocalizeCameraPos = simd_float3(c.x, c.y, c.z)
        }
        startPeriodicRelocalize()
        startWallCenteringIfNeeded()
    }

    /// LiDAR 지원 단말에서 WallCenteringController 시작 (idempotent).
    /// 첫 V3 측위 성공 또는 polygon 첫 fetch 시점에 호출.
    private func startWallCenteringIfNeeded() {
        guard let arSession else { return }
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("[Wall] LiDAR 미지원 — controller 시작 생략")
            return
        }
        if wallCenteringController == nil {
            let controller = WallCenteringController()
            controller.delegate = self
            wallCenteringController = controller
        }
        let closure: (simd_float3) -> CGPoint = { [weak self] arPos in
            guard let self,
                  let pose = self.localizedPose,
                  let arPose = self.matchedARPose,
                  let pX = pose.x, let pY = pose.y, let pZ = pose.z,
                  let qx = pose.qx, let qy = pose.qy, let qz = pose.qz, let qw = pose.qw else {
                return .zero
            }
            let input = CoordinateTransformer.Input(
                serverPosition: simd_float3(Float(pX), Float(pY), Float(pZ)),
                serverQuaternion: simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw)),
                arCameraPose: arPose
            )
            let serverPos = self.arWorldPointToServer(arPos, input: input)
            return CGPoint(x: CGFloat(serverPos.x), y: CGFloat(serverPos.y))
        }
        wallCenteringController?.start(
            session: arSession,
            polygonRings: floorMapPolygonRingsCache,
            serverFromARWorldXZ: closure
        )
    }

    #if DEBUG
    /// Mock fixture 주입 — 캡처/네트워크 우회하고 handleLocalizeV3Success 동등 상태를 즉시 세팅한다.
    /// MockLocalizeFixture.response/steps/matchedARPose 로 drawPathFromSteps 까지 직접 호출.
    private func injectMockLocalizeFixture() {
        // 1) UI 시퀀스
        delegate?.setLocateButtonVisible(false)
        delegate?.setLoading(true)
        delegate?.setScanningOverlay(visible: true)
        delegate?.updateStatus("[MOCK] fixture 주입 중…", color: .white)

        // 2) 상태 세팅 — handleLocalizeV3Success 와 동일
        let response = MockLocalizeFixture.response
        let pose = response.pose
        guard let translation = pose.translation,
              let quat = pose.rotationQuaternion else { return }

        matchedARPose = MockLocalizeFixture.matchedARPose
        lastLocalizeResponse = response
        lastMatchedImageIndex = response.matchedImageIndex
        lastMatchedImage = nil

        localizedPose = Pose(
            x: Double(translation.x), y: Double(translation.y), z: Double(translation.z),
            qx: Double(quat.imag.x), qy: Double(quat.imag.y), qz: Double(quat.imag.z), qw: Double(quat.real)
        )
        localizedFloorId = response.floorId ?? self.floorId
        localizedFloorLevel = response.floorLevel
        localizedAreaId = response.areaId
        pendingTargetFloorId = nil

        // 3) 스캔 완료 UI
        delegate?.setScanningOverlay(visible: false)
        delegate?.showScanComplete()
        delegate?.showRouteCalculating(false)
        delegate?.setLoading(false)
        delegate?.updateStatus("\(destinationName) 방향으로 이동하세요.", color: .white)
        delegate?.setHUDVisible(true)

        // 4) pathfinding 우회 — fixture steps 로 직접
        let steps = MockLocalizeFixture.steps
        lastStartSnapDistance = nil
        print("[MOCK] inject fixture: steps=\(steps.count), localizedFloorLevel=\(localizedFloorLevel ?? -999)")
        drawPathFromSteps(steps)
        refreshFloorNavigationMap(routeSteps: steps, currentFrame: arSession?.currentFrame)
        fetchBundleForPath(steps: steps, fallbackTranslation: translation, fallbackFloorLevel: response.floorLevel)
    }
    #endif

    /// 2D floor map 갱신. 신규 경로 흐름에서는 configure (showFloorNavigationMap) 로 전체 재구성.
    /// - Parameter isRelocalizeRefresh: 주기 재측위/PnP 보정 시 호출이면 true. 캐시된 map 이 있으면 configure 우회 →
    ///   updateFloorNavigationPosition 만 호출해 위치/방향 보간 메커니즘을 활용 (시각적 점프 방지).
    private func refreshFloorNavigationMap(routeSteps: [PathStep], currentFrame: ARFrame?, isRelocalizeRefresh: Bool = false) {
        let resolvedFloorId = localizedFloorId ?? floorId
        guard !resolvedFloorId.isEmpty else { return }

        // 캐시 키는 floorId#areaId 조합 — 같은 층이라도 area 가 다르면 다른 map 응답.
        let resolvedAreaId = localizedAreaId ?? ""
        let cacheKey = "\(resolvedFloorId)#\(resolvedAreaId)"

        let currentPose = currentFloorNavigationPose(frame: currentFrame)

        // 보정 모드 + map 캐시 hit: configure 우회 → updateCurrentPosition 만 호출해 보간 작동.
        if isRelocalizeRefresh, floorMapCache[cacheKey] != nil {
            delegate?.updateFloorNavigationPosition(
                currentPose?.position,
                headingDegrees: currentPose?.headingDegrees
            )
            return
        }

        let cachedFloorLevel = floorMapCache[cacheKey]?.floorLevel ?? localizedFloorLevel
        let destinationPoint: CGPoint? = {
            if let lvl = cachedFloorLevel,
               let pos = routeSteps.last(where: { $0.floorLevel == lvl })?.position,
               let x = pos.x, let y = pos.y {
                return CGPoint(x: x, y: y)
            }
            guard let pos = routeSteps.last?.position, let x = pos.x, let y = pos.y else { return nil }
            return CGPoint(x: x, y: y)
        }()

        if let cached = floorMapCache[cacheKey] {
            // 캐시 hit 라도 polygon rings 캐시는 비어있을 수 있음(이전 trial 등) — 동기화.
            let rings = Self.extractPolygonRings(fromPolygonRaw: cached.polygon.raw)
            self.floorMapPolygonRingsCache = rings
            self.wallCenteringController?.updatePolygonRings(rings)
            if self.wallCenteringController == nil {
                self.startWallCenteringIfNeeded()
            }
            delegate?.showFloorNavigationMap(
                cached,
                routeSteps: routeSteps,
                currentPosition: currentPose?.position,
                currentHeadingDegrees: currentPose?.headingDegrees,
                destinationName: self.destinationName,
                destinationWorldPoint: destinationPoint
            )
            return
        }

        floorMapRequestGeneration += 1
        let generation = floorMapRequestGeneration
        NetworkManager.shared.fetchFloorMap(floorId: resolvedFloorId, areaId: localizedAreaId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.floorMapRequestGeneration == generation else { return }
                switch result {
                case .success(let map):
                    self.floorMapCache[cacheKey] = map
                    let rings = Self.extractPolygonRings(fromPolygonRaw: map.polygon.raw)
                    self.floorMapPolygonRingsCache = rings
                    self.wallCenteringController?.updatePolygonRings(rings)
                    if self.wallCenteringController == nil {
                        self.startWallCenteringIfNeeded()
                    }
                    let currentPose = self.currentFloorNavigationPose(frame: self.arSession?.currentFrame)
                    let destinationPoint: CGPoint? = {
                        guard let pos = routeSteps.last(where: { $0.floorLevel == map.floorLevel })?.position,
                              let x = pos.x, let y = pos.y else {
                            guard let pos = routeSteps.last?.position, let x = pos.x, let y = pos.y else { return nil }
                            return CGPoint(x: x, y: y)
                        }
                        return CGPoint(x: x, y: y)
                    }()
                    self.delegate?.showFloorNavigationMap(
                        map,
                        routeSteps: routeSteps,
                        currentPosition: currentPose?.position,
                        currentHeadingDegrees: currentPose?.headingDegrees,
                        destinationName: self.destinationName,
                        destinationWorldPoint: destinationPoint
                    )
                case .failure(let error):
                    print("[FloorMap] fetch failed floorId=\(resolvedFloorId) areaId=\(self.localizedAreaId ?? "nil"): \(error)")
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
    private func startV3Pathfinding(startFloorLevel: Int?,
                                    translation: simd_float3,
                                    areaId: String? = nil,
                                    isRelocalizeRefresh: Bool = false) {
        // 서버 PathfindingRequest: startFloorLevel 필요 — nil 이면 422 START_NOT_SPECIFIED
        guard startFloorLevel != nil else {
            // 주기 refresh 인 경우 UI 차단/에러 발화 안 함 — 다음 tick 까지 대기.
            if isRelocalizeRefresh {
                print("[V3-PATH] periodic refresh — startFloorLevel nil, skip")
                return
            }
            delegate?.setLoading(false)
            delegate?.showRouteCalculating(false)
            delegate?.showScanFailed(message: "측위 결과가 부족해요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }
        // 서버 spec:
        //   preference: SHORTEST / ELEVATOR_FIRST / STAIRCASE_FIRST
        //   verticalPreference: ELEVATOR / STAIRS
        // 사용자 토글에 맞춰 preference 도 _FIRST 변형으로 강제 — 서버가 두 값 일관되게 받음.
        let routePreference: RoutePreference = (self.verticalPreference == .stairs) ? .staircaseFirst : .elevatorFirst
        let req = PathfindingRequest(
            startFloorLevel: startFloorLevel,
            startX: Double(translation.x),
            startY: Double(translation.y),
            startZ: Double(translation.z),
            destinationId: self.destinationId,
            destinationName: self.destinationName,
            preference: routePreference,
            verticalPreference: self.verticalPreference,
            startAreaId: areaId
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
                    self.drawPathFromSteps(steps, isRelocalizeRefresh: isRelocalizeRefresh)
                    self.refreshFloorNavigationMap(routeSteps: steps,
                                                   currentFrame: self.arSession?.currentFrame,
                                                   isRelocalizeRefresh: isRelocalizeRefresh)
                    if !isRelocalizeRefresh {
                        self.dumpLocalizeDebug(rawSteps: resp.steps)
                    }
                    // steps[].position 좌표를 lookup multi-query 로 사용 → 경로 전체 영역 keyframe pack 받음.
                    self.fetchBundleForPath(steps: steps, fallbackTranslation: translation, fallbackFloorLevel: startFloorLevel)
                case .failure(let err):
                    let msg = String(describing: err)
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
        // 주기 재측위 정책 전환 — lookup 기반 추적(LightGlue) 폐기. 본 함수는 본문 보존하되 early return.
        // 후속 UI 상태 직접 정리 (loading off + status update) — 호출자가 기대하던 상태로 복귀.
        if !Self.useLightGlueMatcher {
            print("[NetworkBundle] lookup disabled — 주기 재측위 정책 (early return)")
            self.delegate?.showRouteCalculating(false)
            self.delegate?.setLoading(false)
            self.delegate?.updateStatus("\(self.destinationName) 방향으로 이동하세요.", color: .white)
            return
        }

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

        // lookup 호출 비활성화 — 측위/path 렌더링 까지만 진행, keyframe 추적 미실행.
        print("[NetworkBundle] lookup 호출 SKIP (queries=\(queryPoints.count))")
        self.delegate?.showRouteCalculating(false)
        self.delegate?.setLoading(false)
    }

    // MARK: - AR 경로 렌더링 (PathChevron 시스템 — drawPathFromSteps 가 직접 PathChevronController 호출)
    //
    // 이전 sphere + cylinder line 시각화는 PathChevron 시스템(바닥 ^ chevron, 2.5m 간격, sequential pulse)으로 대체.
    // 보조 헬퍼(simplifyXZ / rdpRecurse / perpendicularDistanceXZ / catmullRomSpline / lineSegmentNode /
    // createCheckpointNode / computeRemainingDistance) 는 본 PR 에서 제거.
    // tracking 추적 모델(trackingKeyframeCandidates + checkpointNode placeholder)은 LightGlue 비활성 상태라 dead path 지만 보존.

    // MARK: - 경로 진행 추적 (Phase 8 keyframe 단계 추적 모델로 대체 — dead path)
    //
    // tickPathProgress / startPathProgressTracking / pathProgressTimer 는 PathChevron 시스템 도입 시 제거.
    // ViewController.viewWillDisappear 에서 호출하는 stopPathProgressTracking() 만 no-op 으로 보존.

    /// ViewController.viewWillDisappear 에서 호출 — 안전한 no-op.
    func stopPathProgressTracking() {
        // 본 함수는 호환성 위해 유지. body 는 빈 상태.
    }

    // MARK: - 층 이동 인터렉션

    /// 현재 step (또는 다음 step) 이 층 이동 노드(계단/엘리베이터)인지 감지.
    /// - 매칭 기준: floorLevel 변화 OR instruction 키워드 (TAKE_STAIRS / STAIRS / 계단 / ST- / TAKE_ELEVATOR / ELEVATOR / 엘리베이터 / EV-)
    /// - `cameraPos` 가 주어지면 trigger step (= stairs/elevator 노드) 까지 AR 거리가 `floorTransitionTriggerDistance` 이내일 때만 트리거.
    /// - currentStepIdx 가 마지막 step 인 경우(advance 가 stairs step 까지 cascade) 도 cur 자체로 트리거 가능.
    private func detectFloorTransition(currentStepIdx: Int, cameraPos: simd_float3? = nil) -> (type: String, targetFloor: Int?)? {
        guard currentStepIdx >= 0, currentStepIdx < lastPathSteps.count else { return nil }
        let cur = lastPathSteps[currentStepIdx]
        let nxt: PathStep? = (currentStepIdx + 1 < lastPathSteps.count) ? lastPathSteps[currentStepIdx + 1] : nil

        let curInstr = cur.instruction ?? ""
        let nxtInstr = nxt?.instruction ?? ""
        let combined = curInstr + " " + nxtInstr

        // "ST-A1", "ST-B2" 등 서버 계단 노드 식별자 prefix 매칭. "Start" 와 충돌 회피 위해 hyphen 포함.
        let stairsKeywords = ["TAKE_STAIRS", "STAIRS", "계단", "ST-"]
        let elevatorKeywords = ["TAKE_ELEVATOR", "ELEVATOR", "엘리베이터", "EV-"]

        let hasStairs = stairsKeywords.contains { combined.contains($0) }
        let hasElevator = elevatorKeywords.contains { combined.contains($0) }

        // floorLevel 변화 — cur ↔ nxt 또는 cur ↔ localizedFloorLevel.
        let floorChanged: Bool = {
            if let cf = cur.floorLevel, let nf = nxt?.floorLevel, cf != nf { return true }
            if let cf = cur.floorLevel, let lf = localizedFloorLevel, cf != lf { return true }
            return false
        }()

        guard floorChanged || hasStairs || hasElevator else { return nil }

        // trigger step 선정 — cur 자체가 stairs/elevator 키워드 갖고 있으면 cur, 아니면 nxt (있을 때).
        // cur 이 키워드 갖고 있고 nxt 도 갖고 있으면 cur 우선 (advance 가 cascade 한 경우엔 cur 이 stairs).
        let curHasKw = stairsKeywords.contains { curInstr.contains($0) } || elevatorKeywords.contains { curInstr.contains($0) }
        let triggerStep: PathStep = curHasKw ? cur : (nxt ?? cur)

        // 거리 가드 — cameraPos 가 있으면 triggerStep 까지 AR 거리 측정.
        // floorTransitionTriggerDistance 초과면 트리거 보류 (사용자가 실제 근접할 때까지 대기).
        if let cameraPos,
           let arPose = matchedARPose,
           let pose = localizedPose,
           let tPos = triggerStep.position,
           let tx = tPos.x, let ty = tPos.y, let tz = tPos.z {
            let serverPos = simd_float3(Float(pose.x ?? 0), Float(pose.y ?? 0), Float(pose.z ?? 0))
            let quat = simd_quatf(
                ix: Float(pose.qx ?? 0), iy: Float(pose.qy ?? 0),
                iz: Float(pose.qz ?? 0), r: Float(pose.qw ?? 1)
            )
            let input = CoordinateTransformer.Input(serverPosition: serverPos, serverQuaternion: quat, arCameraPose: arPose)
            let tAR = CoordinateTransformer.transform(
                serverPoint: simd_float3(Float(tx), Float(ty), Float(tz)),
                input: input
            )
            let dx = cameraPos.x - tAR.x
            let dz = cameraPos.z - tAR.z
            let d = sqrt(dx * dx + dz * dz)
            guard d <= floorTransitionTriggerDistance else { return nil }
        }

        // type 우선순위: instruction 키워드 매칭 결과로 결정. 없으면 기본 STAIRS.
        let type: String
        if hasElevator {
            type = "ELEVATOR"
        } else if hasStairs {
            type = "STAIRS"
        } else {
            type = "STAIRS"
        }

        // targetFloor: nxt 있으면 nxt 의 floor, 없으면 cur 의 floor (stairs/elevator step 자체가 새 층 노드일 수 있음).
        let targetFloor = nxt?.floorLevel ?? cur.floorLevel
        return (type, targetFloor)
    }

    /// cached floor map 들의 connectors[].stops[] 에서 `transitionType` 과 `targetFloor` 에 매칭하는
    /// floorId 를 lookup. 같은 connector 가 모든 stop 의 floorId 를 알려주므로, 어느 층의 floor map
    /// 이라도 캐시돼있으면 다른 층 floorId 도 추출 가능.
    /// - transitionType: "STAIRS" / "ELEVATOR" (내부 표기). 서버 type 은 "stairs"/"elevator" 소문자라 case-insensitive 비교.
    private func lookupTargetFloorId(transitionType: String, targetFloor: Int?) -> String? {
        guard let targetFloor else { return nil }
        let typeLower = transitionType.lowercased()
        for (_, map) in floorMapCache {
            guard let connectors = map.connectors else { continue }
            for connector in connectors {
                guard let cType = connector.type?.lowercased(), cType == typeLower else { continue }
                guard let stops = connector.stops else { continue }
                for stop in stops {
                    if stop.floorLevel == targetFloor, let fid = stop.floorId, !fid.isEmpty {
                        return fid
                    }
                }
            }
        }
        return nil
    }

    private func triggerFloorTransition(type: String, targetFloor: Int?, currentStepIdx: Int) {
        hasActiveFloorTransition = true

        // 잔여 steps 추출
        let remaining: [PathStep]
        if currentStepIdx + 1 < lastPathSteps.count {
            remaining = Array(lastPathSteps[(currentStepIdx + 1)...])
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
        pendingTargetFloorId = lookupTargetFloorId(transitionType: type, targetFloor: targetFloor)
        if let f = pendingTargetFloorId {
            print("[FloorTransition] pendingTargetFloorId 확정 = \(f) (type=\(type), targetFloor=\(targetFloor ?? -999))")
        } else {
            print("[FloorTransition] pendingTargetFloorId lookup 실패 — connector stops 에 매칭 없음 (type=\(type), targetFloor=\(targetFloor ?? -999))")
        }

        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
        stopPeriodicRelocalize()

        // AR 경로 chevron 숨김 (세션은 유지)
        pathChevronController.setHidden(true)

        // Phase 5: 층 전환 중에는 방향 안내 UI 일시 정지
        guidanceDirector.pause()

        delegate?.setHUDVisible(false)
        delegate?.showFloorTransition(transitionType: type, targetFloor: targetFloor, currentFloor: lastPathSteps[currentStepIdx].floorLevel)
    }

    func restartFromFloorTransition() {
        guard hasActiveFloorTransition else { return }
        delegate?.hideFloorTransition()

        // 기존 노드 정리
        pathChevronController.clear()
        destinationPinNode = nil
        matchedARPose = nil
        localizedPose = nil
        // 옛 층 정보는 새 측위 전에 비워야 floorIdHint 가 옛 층(2층)을 새 층(3층) 측위에 끌고 들어가지 않음.
        localizedFloorId = nil
        localizedFloorLevel = nil
        localizedAreaId = nil
        destinationARPosition = nil
        hasNotifiedArrival = false
        lastStartSnapDistance = nil
        wallCenteringController?.stop()
        wallCenteringController = nil
        floorMapPolygonRingsCache = []

        // Phase 5: director 상태도 초기화. 새 setRoute가 들어오면 isPaused 자동 해제.
        guidanceDirector.reset()

        hasActiveFloorTransition = false
        isFloorTransitionRestart = true

        // 재스캔 안내 UI 복귀 + 캡처 재시작
        delegate?.setLocateButtonVisible(false)
        delegate?.setLoading(true)
        delegate?.setScanningOverlay(visible: true)
        delegate?.updateStatus("천천히 주변을 둘러보세요", color: .white)
        delegate?.setCaptureProgress(phase: .capturing)

        capturedImages = []
        capturedARPoses = []
        capturedDepths = []
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

    // MARK: - 주기 재측위

    /// 사용자가 측위 진행 중 locate 버튼을 재탭했을 때 호출. 2m 이동 가드만 우회하고
    /// 즉시 한 cadence 분량의 주기 측위를 발사. path/marker/state 는 그대로 유지되며
    /// `runPeriodicRelocalizeTick()` 내부 blend 또는 hard-set 분기가 보정한다.
    /// in-flight / 층 전환 / 도착 / AR 세션 미준비 가드는 tick 내부에서 그대로 적용됨.
    private func forcePeriodicRelocalizeNow() {
        print("[PeriodicV3] force tick — locate 버튼 재진입 (resetForNewTrial 우회)")
        // 2m 이동 가드 우회: 캐시 nil → tick 내부 "첫 cadence (캐시 nil) 는 강제 통과" 분기 재사용.
        lastPeriodicRelocalizeCameraPos = nil
        // status 한 줄 토스트만 — 캡처 overlay / loading / progress phase 는 silent 유지.
        delegate?.updateStatus("위치를 다시 확인 중...", color: .white)
        runPeriodicRelocalizeTick()
    }

    /// 초기 V3 측위 성공 직후 호출. cadence 마다 5장 캡처 → V3 호출 → blend.
    /// 층 전환 / 도착 / 화면 dismiss / 새 trial 시 정지.
    private func startPeriodicRelocalize() {
        periodicRelocalizeTimer?.invalidate()
        periodicRelocalizeTimer = Timer.scheduledTimer(
            withTimeInterval: periodicRelocalizeIntervalSec, repeats: true
        ) { [weak self] _ in
            self?.runPeriodicRelocalizeTick()
        }
        print("[PeriodicV3] 시작 — cadence=\(periodicRelocalizeIntervalSec)s, images=\(periodicRelocalizeImageCount)")
    }

    func stopPeriodicRelocalize() {
        periodicRelocalizeTimer?.invalidate()
        periodicRelocalizeTimer = nil
        periodicRelocalizeCaptureTimer?.invalidate()
        periodicRelocalizeCaptureTimer = nil
        periodicCapturedImages = []
        periodicCapturedARPoses = []
        periodicCapturedDepths = []
        isPeriodicRelocalizeInFlight = false
        lastPeriodicRelocalizeCameraPos = nil
        periodicCaptureStartTime = nil
    }

    /// 한 cadence tick — 캡처 타이머 시작. 이미 진행 중이면 skip.
    private func runPeriodicRelocalizeTick() {
        guard !isPeriodicRelocalizeInFlight else {
            print("[PeriodicV3] tick skip — 직전 측위 미완료")
            return
        }
        guard !hasActiveFloorTransition else {
            print("[PeriodicV3] tick skip — 층 전환 활성")
            return
        }
        guard !hasNotifiedArrival else {
            print("[PeriodicV3] tick skip — 도착 후")
            return
        }
        guard let frame = arSession?.currentFrame else {
            print("[PeriodicV3] tick skip — AR 세션 미준비")
            return
        }

        // 이동 거리 가드 — 정지 상태(직전 발사 위치 대비 2m 미만) 면 skip.
        // 첫 cadence (캐시 nil) 는 강제 통과 후 캐시 채움.
        let camCol = frame.camera.transform.columns.3
        let curCamPos = simd_float3(camCol.x, camCol.y, camCol.z)
        if let lastPos = lastPeriodicRelocalizeCameraPos {
            let dx = curCamPos.x - lastPos.x
            let dz = curCamPos.z - lastPos.z
            let dist = sqrt(dx * dx + dz * dz)
            guard dist >= Self.periodicRelocalizeMinTravelM else {
                print("[PeriodicV3] skip — 이동 \(String(format: "%.2f", dist))m < \(Self.periodicRelocalizeMinTravelM)m")
                return
            }
        }
        lastPeriodicRelocalizeCameraPos = curCamPos

        isPeriodicRelocalizeInFlight = true
        wallCenteringController?.suspend()
        periodicCapturedImages = []
        periodicCapturedARPoses = []
        periodicCapturedDepths = []
        periodicCaptureStartTime = Date().timeIntervalSince1970

        periodicRelocalizeCaptureTimer?.invalidate()
        periodicRelocalizeCaptureTimer = Timer.scheduledTimer(
            withTimeInterval: periodicRelocalizeCaptureInterval, repeats: true
        ) { [weak self] _ in
            self?.capturePeriodicFrame()
        }
    }

    private func capturePeriodicFrame() {
        // Timeout 가드 — limited tracking 등으로 N장 영영 못 채울 경우 in-flight 락이
        // 영구 점유되는 데드락 방지. abort 후 다음 cadence 에서 재시도.
        if let start = periodicCaptureStartTime,
           Date().timeIntervalSince1970 - start > Self.periodicRelocalizeCaptureTimeoutSec {
            print("[PeriodicV3] 캡처 timeout (\(Self.periodicRelocalizeCaptureTimeoutSec)s) — abort")
            periodicRelocalizeCaptureTimer?.invalidate()
            periodicRelocalizeCaptureTimer = nil
            periodicCapturedImages.removeAll()
            periodicCapturedARPoses.removeAll()
            periodicCapturedDepths.removeAll()
            periodicCaptureStartTime = nil
            isPeriodicRelocalizeInFlight = false
            wallCenteringController?.resume(resetCumulative: false)
            return
        }

        guard let frame = arSession?.currentFrame else { return }

        // ARKit 모션 가드 — limited 면 skip (다음 tick 까지 대기). 본 frame 은 누락.
        if case .limited = frame.camera.trackingState {
            return
        }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        periodicCapturedImages.append(uiImage)
        periodicCapturedARPoses.append(frame.camera.transform)
        if let depthPB = frame.sceneDepth?.depthMap,
           let depthData = Self.depthMapData(from: depthPB) {
            periodicCapturedDepths.append(depthData)
        }

        if periodicCapturedImages.count >= periodicRelocalizeImageCount {
            periodicRelocalizeCaptureTimer?.invalidate()
            periodicRelocalizeCaptureTimer = nil
            periodicCaptureStartTime = nil
            sendPeriodicRelocalize()
        }
    }

    private func sendPeriodicRelocalize() {
        guard !periodicCapturedImages.isEmpty else {
            isPeriodicRelocalizeInFlight = false
            wallCenteringController?.resume(resetCumulative: false)
            return
        }

        let images = periodicCapturedImages
        let poses = periodicCapturedARPoses
        let depths = periodicCapturedDepths
        let depthsForUpload: [Data]? = depths.isEmpty ? nil : depths
        // 자동 주기 재측위는 첫 측위 성공 후에만 발사되므로 localizedFloorId 가 항상 채워져 있어
        // 폴백 분기 도달 X — 단, 일관성/방어를 위해 수동 측위와 동일 패턴 유지.
        let floorIdHint: String? = {
            if let f = localizedFloorId, !f.isEmpty { return f }
            if let f = pendingTargetFloorId, !f.isEmpty { return f }
            return (userCurrentFloorId?.isEmpty == false) ? userCurrentFloorId : nil
        }()
        print("[PeriodicV3] V3 측위 호출 — images=\(images.count) depths=\(depths.count)")

        NetworkManager.shared.localizeV3(
            buildingId: buildingId,
            images: images,
            depths: depthsForUpload,
            mapId: nil,
            floorId: floorIdHint
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let response):
                    self.handlePeriodicRelocalizeSuccess(response: response, capturedPoses: poses, capturedImages: images)
                case .failure(let error):
                    print("[PeriodicV3] V3 측위 실패 — \(error). 다음 tick 까지 대기.")
                    self.isPeriodicRelocalizeInFlight = false
                    self.wallCenteringController?.resume(resetCumulative: false)
                }
            }
        }
    }

    /// 주기 V3 측위 응답 핸들러. UI 토스트/HUD 변경 없이 silent blend.
    /// - `localizedPose`: 큰 변화는 hard-set, 그 외는 기존 ↔ 새 응답 사이 `blendAlpha` 로 lerp (translation) + slerp (quaternion).
    /// - `matchedARPose`: `localizedPose` 와 같은 alpha 로 캡처 시점 ARFrame pose 를 향해 보정.
    /// - 다른 층 응답이면 무시 (가드).
    /// - confidence / numMatches / 회전 변화 / ARKit 이동량 대비 서버 이동량 가드로 wrong-match 위험 응답 무시.
    /// - reject 케이스도 디버그 dump (사유 식별용) — `dumpPeriodicRelocalizeReject` 호출.
    private func handlePeriodicRelocalizeSuccess(response: SLAMLocalizeResponse, capturedPoses: [simd_float4x4], capturedImages: [UIImage]) {
        defer { self.isPeriodicRelocalizeInFlight = false }
        defer { self.wallCenteringController?.resume(resetCumulative: true) }

        // 진입 직후 prev snapshot — dump 용 (blend 적용 전 값 보존)
        let prevLocalizedPoseSnapshot = self.localizedPose
        let prevMatchedARPoseSnapshot = self.matchedARPose

        guard response.confidence >= periodicRelocalizeMinConfidence else {
            print("[PeriodicV3] confidence \(response.confidence) < \(periodicRelocalizeMinConfidence) — 결과 무시")
            self.dumpPeriodicRelocalizeReject(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                reason: "confidence_below_threshold"
            )
            return
        }

        let numMatches = response.numMatches ?? 0
        guard numMatches >= periodicRelocalizeMinMatches else {
            print("[PeriodicV3] numMatches \(numMatches) < \(periodicRelocalizeMinMatches) — 결과 무시")
            self.dumpPeriodicRelocalizeReject(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                reason: "num_matches_below_threshold"
            )
            return
        }

        if let respFloor = response.floorLevel,
           let curFloor = self.localizedFloorLevel,
           respFloor != curFloor {
            print("[PeriodicV3] 다른 층 응답 (current=\(curFloor) vs response=\(respFloor)) — 결과 무시")
            self.dumpPeriodicRelocalizeReject(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                reason: "different_floor"
            )
            return
        }

        guard let translation = response.pose.translation,
              let quat = response.pose.rotationQuaternion else {
            print("[PeriodicV3] pose translation/quat 누락 — 결과 무시")
            self.dumpPeriodicRelocalizeReject(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                reason: "pose_missing"
            )
            return
        }

        guard !capturedPoses.isEmpty else {
            print("[PeriodicV3] capturedPoses 비어있음 — 결과 무시")
            self.dumpPeriodicRelocalizeReject(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                reason: "captured_poses_empty"
            )
            return
        }
        let arPoseIndex: Int = {
            if let idx = response.matchedImageIndex, capturedPoses.indices.contains(idx) {
                return idx
            }
            return capturedPoses.count - 1
        }()
        let newMatchedARPose = capturedPoses[arPoseIndex]

        // 기존 pose 가 없으면 hard-set (첫 호출 방어, 정상 흐름에선 도달 X)
        guard let prev = self.localizedPose,
              let px = prev.x, let py = prev.y, let pz = prev.z,
              let pqx = prev.qx, let pqy = prev.qy, let pqz = prev.qz, let pqw = prev.qw else {
            self.localizedPose = Pose(
                x: Double(translation.x), y: Double(translation.y), z: Double(translation.z),
                qx: Double(quat.imag.x), qy: Double(quat.imag.y),
                qz: Double(quat.imag.z), qw: Double(quat.real)
            )
            self.matchedARPose = newMatchedARPose
            self.localizedAreaId = response.areaId ?? self.localizedAreaId
            print("[PeriodicV3] hard-set (이전 pose 없음)")
            self.dumpPeriodicRelocalizeDebug(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                arPoseIndex: arPoseIndex,
                newMatchedARPose: newMatchedARPose,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                blendedPose: self.localizedPose,
                alpha: 1.0
            )
            return
        }

        let prevTranslation = simd_float3(Float(px), Float(py), Float(pz))
        let newTranslation = translation

        // 큰 변화 감지 — blend 우회 판정용 (blend 적용 전 미리 산출)
        let dxPre = newTranslation.x - prevTranslation.x
        let dyPre = newTranslation.y - prevTranslation.y
        let dzPre = newTranslation.z - prevTranslation.z
        let deltaTranslationM = sqrt(dxPre*dxPre + dyPre*dyPre + dzPre*dzPre)
        let prevQuat = simd_quatf(ix: Float(pqx), iy: Float(pqy), iz: Float(pqz), r: Float(pqw))
        let deltaRotationDeg = Self.rotationDeltaDegrees(from: prevQuat, to: quat)

        guard deltaRotationDeg <= periodicRelocalizeMaxRotationDeltaDeg else {
            print(String(format: "[PeriodicV3] rotation delta %.1f° > %.1f° — 결과 무시",
                         deltaRotationDeg, periodicRelocalizeMaxRotationDeltaDeg))
            self.dumpPeriodicRelocalizeReject(
                response: response,
                capturedImages: capturedImages,
                capturedPoses: capturedPoses,
                prevLocalizedPose: prevLocalizedPoseSnapshot,
                prevMatchedARPose: prevMatchedARPoseSnapshot,
                reason: "rotation_delta_above_threshold"
            )
            return
        }

        if let prevMatchedARPoseSnapshot {
            let prevAR = simd_float3(prevMatchedARPoseSnapshot.columns.3.x,
                                     prevMatchedARPoseSnapshot.columns.3.y,
                                     prevMatchedARPoseSnapshot.columns.3.z)
            let newAR = simd_float3(newMatchedARPose.columns.3.x,
                                    newMatchedARPose.columns.3.y,
                                    newMatchedARPose.columns.3.z)
            let arDeltaM = simd_distance(prevAR, newAR)
            let gap = deltaTranslationM - arDeltaM
            let ratio = deltaTranslationM / max(arDeltaM, 0.25)
            if gap > periodicRelocalizeMaxServerARDistanceGapM ||
                ratio > periodicRelocalizeMaxServerARDistanceRatio {
                print(String(format: "[PeriodicV3] server/AR delta mismatch — server=%.2fm ar=%.2fm gap=%.2fm ratio=%.2f. 결과 무시",
                             deltaTranslationM, arDeltaM, gap, ratio))
                self.dumpPeriodicRelocalizeReject(
                    response: response,
                    capturedImages: capturedImages,
                    capturedPoses: capturedPoses,
                    prevLocalizedPose: prevLocalizedPoseSnapshot,
                    prevMatchedARPose: prevMatchedARPoseSnapshot,
                    reason: "server_ar_delta_mismatch"
                )
                return
            }
        }

        let useHardSet = deltaTranslationM > periodicRelocalizeHardSetThresholdM
        let appliedAlpha: Float = useHardSet ? 1.0 : periodicRelocalizeBlendAlpha

        let blendedTranslation: simd_float3
        let blendedQuat: simd_quatf
        if useHardSet {
            blendedTranslation = newTranslation
            blendedQuat = quat
        } else {
            blendedTranslation = simd_mix(prevTranslation, newTranslation, simd_float3(repeating: appliedAlpha))
            blendedQuat = simd_slerp(prevQuat, quat, appliedAlpha)
        }

        self.localizedPose = Pose(
            x: Double(blendedTranslation.x),
            y: Double(blendedTranslation.y),
            z: Double(blendedTranslation.z),
            qx: Double(blendedQuat.imag.x),
            qy: Double(blendedQuat.imag.y),
            qz: Double(blendedQuat.imag.z),
            qw: Double(blendedQuat.real)
        )
        // matchedARPose 도 같은 α 로 blend — localizedPose 만 blend 하고 matchedARPose 만 hard-set 하면
        // CoordinateTransformer 가 가정하는 "같은 순간의 페어" 가 깨져 chevron/marker 가 일관 오프셋 만큼
        // 어긋남. 두 값을 동일 α 로 lerp/slerp 해 변환식 consistency 유지.
        // useHardSet (Δpose > threshold) 케이스는 appliedAlpha=1.0 → 자동으로 new 값 그대로.
        self.matchedARPose = Self.blendMatrix(prev: prevMatchedARPoseSnapshot ?? newMatchedARPose,
                                              new: newMatchedARPose,
                                              alpha: appliedAlpha)
        // areaId: 응답에 있으면 갱신, 없으면 prev 유지 (서버 응답 누락 방어)
        self.localizedAreaId = response.areaId ?? self.localizedAreaId

        print(String(format: "[PeriodicV3] %@ — alpha=%.2f Δpose=%.2fm conf=%.2f matches=%d",
                     useHardSet ? "hard-set (큰 변화)" : "blended",
                     appliedAlpha, deltaTranslationM, response.confidence, response.numMatches ?? -1))

        // 경로/마커 재렌더 (PnP 보정 패턴 따름) — 보정 모드: 진행 상태(currentStepIndex / turn arrow / marker) 유지.
        // useHardSet (Δpose > threshold) 케이스는 새 pose 와 옛 lastPathSteps 의 step 좌표가 어긋나
        // chevron 이 잘못된 위치에 잠깐 잔존 → skip. 직후 startV3Pathfinding 응답이 오면
        // drawPathFromSteps(newSteps) 가 호출돼 올바른 위치로 갱신됨.
        if !useHardSet {
            self.drawPathFromSteps(self.lastPathSteps, isRelocalizeRefresh: true)
            self.refreshFloorNavigationMap(routeSteps: self.lastPathSteps, currentFrame: self.arSession?.currentFrame, isRelocalizeRefresh: true)
        }

        // 주기 pathfinding 재호출 — 보정된 pose 기준 새 경로 받아 lastPathSteps 갱신.
        // isRelocalizeRefresh=true 라 navigation 상태(currentStepIndex / arrival timer / UI) 는 유지됨.
        self.startV3Pathfinding(startFloorLevel: response.floorLevel,
                                translation: blendedTranslation,
                                areaId: response.areaId ?? self.localizedAreaId,
                                isRelocalizeRefresh: true)

        // 디버그 dump — drawPath / refreshMap 호출 직후 (좌회전 후 wrong-match 진단용)
        self.dumpPeriodicRelocalizeDebug(
            response: response,
            capturedImages: capturedImages,
            capturedPoses: capturedPoses,
            arPoseIndex: arPoseIndex,
            newMatchedARPose: newMatchedARPose,
            prevLocalizedPose: prevLocalizedPoseSnapshot,
            prevMatchedARPose: prevMatchedARPoseSnapshot,
            blendedPose: self.localizedPose,
            alpha: appliedAlpha
        )
    }

    /// 주기 V3 재측위 응답마다 prev/new/blended pose + 변환 결과 일괄 dump.
    /// 좌회전 후 wrong-match 케이스에서 응답 자체 문제인지 blend 끌어당김인지 분리하기 위해
    /// 3가지 pose 로 step 좌표를 각각 변환해 저장한다.
    private func dumpPeriodicRelocalizeDebug(
        response: SLAMLocalizeResponse,
        capturedImages: [UIImage],
        capturedPoses: [simd_float4x4],
        arPoseIndex: Int,
        newMatchedARPose: simd_float4x4,
        prevLocalizedPose: Pose?,
        prevMatchedARPose: simd_float4x4?,
        blendedPose: Pose?,
        alpha: Float
    ) {
        // step 좌표 → (pos, quat) 입력으로 변환 헬퍼
        func computeTransform(serverPos: simd_float3, serverQuat: simd_quatf) -> [(Int, simd_float3)] {
            let input = CoordinateTransformer.Input(
                serverPosition: serverPos,
                serverQuaternion: serverQuat,
                arCameraPose: newMatchedARPose
            )
            return lastPathSteps.enumerated().compactMap { (idx, step) -> (Int, simd_float3)? in
                guard let pos = step.position,
                      let x = pos.x, let y = pos.y, let z = pos.z else { return nil }
                let ar = CoordinateTransformer.transform(
                    serverPoint: simd_float3(Float(x), Float(y), Float(z)),
                    input: input
                )
                return (step.stepNumber, ar)
            }
        }

        // prev pose 변환 (있으면)
        let transformedByPrev: [(Int, simd_float3)] = {
            guard let p = prevLocalizedPose,
                  let x = p.x, let y = p.y, let z = p.z,
                  let qx = p.qx, let qy = p.qy, let qz = p.qz, let qw = p.qw else { return [] }
            let pos = simd_float3(Float(x), Float(y), Float(z))
            let q = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
            return computeTransform(serverPos: pos, serverQuat: q)
        }()

        // new server pose 변환
        let transformedByNew: [(Int, simd_float3)] = {
            guard let pos = response.pose.translation,
                  let q = response.pose.rotationQuaternion else { return [] }
            return computeTransform(serverPos: pos, serverQuat: q)
        }()

        // blended pose 변환
        let transformedByBlended: [(Int, simd_float3)] = {
            guard let p = blendedPose,
                  let x = p.x, let y = p.y, let z = p.z,
                  let qx = p.qx, let qy = p.qy, let qz = p.qz, let qw = p.qw else { return [] }
            let pos = simd_float3(Float(x), Float(y), Float(z))
            let q = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
            return computeTransform(serverPos: pos, serverQuat: q)
        }()

        // Δtranslation, Δrotation
        let deltaT: Float = {
            guard let p = prevLocalizedPose,
                  let px = p.x, let py = p.y, let pz = p.z,
                  let nt = response.pose.translation else { return 0 }
            let pv = simd_float3(Float(px), Float(py), Float(pz))
            return simd_length(nt - pv)
        }()
        let deltaRotDeg: Float = {
            guard let p = prevLocalizedPose,
                  let pqx = p.qx, let pqy = p.qy, let pqz = p.qz, let pqw = p.qw,
                  let nq = response.pose.rotationQuaternion else { return 0 }
            let pq = simd_quatf(ix: Float(pqx), iy: Float(pqy), iz: Float(pqz), r: Float(pqw))
            let diff = pq.inverse * nq
            // simd_quatf.angle 은 [0, 2π], 단위 quaternion 보장 안 되면 clamp 처리
            let w = max(-1.0, min(1.0, diff.real))
            let angleRad = 2.0 * acos(abs(w))
            return Float(angleRad * 180.0 / .pi)
        }()

        let blendedSLAMPose: SLAMPose? = {
            guard let b = blendedPose else { return nil }
            return SLAMPose(
                x: b.x, y: b.y, z: b.z,
                qx: b.qx, qy: b.qy, qz: b.qz, qw: b.qw
            )
        }()
        let prevSLAMPose: SLAMPose? = {
            guard let p = prevLocalizedPose else { return nil }
            return SLAMPose(
                x: p.x, y: p.y, z: p.z, qx: p.qx, qy: p.qy, qz: p.qz, qw: p.qw
            )
        }()

        let arCamPos: simd_float3? = {
            guard capturedPoses.indices.contains(arPoseIndex) else { return nil }
            let m = capturedPoses[arPoseIndex]
            return simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }()

        let snapshot = LocalizeDebugLogger.PeriodicSnapshot(
            capturedImages: capturedImages,
            capturedARPoses: capturedPoses,
            matchedImageIndex: response.matchedImageIndex,
            prevLocalizedPose: prevSLAMPose,
            newServerPose: response.pose,
            blendedLocalizedPose: blendedSLAMPose,
            prevMatchedARPose: prevMatchedARPose,
            newMatchedARPose: newMatchedARPose,
            confidence: response.confidence,
            numMatches: response.numMatches,
            floorLevel: response.floorLevel,
            floorId: response.floorId,
            blendAlpha: alpha,
            deltaTranslationM: deltaT,
            deltaRotationDeg: deltaRotDeg,
            arCameraPosAtCapture: arCamPos,
            steps: self.lastPathSteps,
            transformedStepsByPrev: transformedByPrev,
            transformedStepsByNew: transformedByNew,
            transformedStepsByBlended: transformedByBlended,
            rejectReason: nil
        )
        LocalizeDebugLogger.dumpPeriodic(snapshot)
    }

    /// 가드 fail 케이스용 dump. reject 사유와 함께 dump → 응답 자체가 어떤 모양이었는지 사후 추적.
    /// - blendedLocalizedPose / transformedStepsByBlended 는 nil/빈 배열 (적용 안 됨)
    /// - translation 누락 케이스에서는 transformedStepsByNew 도 빈 배열로 폴백
    /// - matchedARPose 는 prev 의 값 또는 capturedPoses 마지막 인덱스
    private func dumpPeriodicRelocalizeReject(
        response: SLAMLocalizeResponse,
        capturedImages: [UIImage],
        capturedPoses: [simd_float4x4],
        prevLocalizedPose: Pose?,
        prevMatchedARPose: simd_float4x4?,
        reason: String
    ) {
        // arPoseIndex / newMatchedARPose: capturedPoses 있으면 응답 인덱스 또는 마지막, 없으면 identity placeholder
        let arPoseIndex: Int = {
            if let idx = response.matchedImageIndex, capturedPoses.indices.contains(idx) {
                return idx
            }
            return max(0, capturedPoses.count - 1)
        }()
        let newMatchedARPose: simd_float4x4 = {
            if capturedPoses.indices.contains(arPoseIndex) {
                return capturedPoses[arPoseIndex]
            }
            return matrix_identity_float4x4
        }()

        // transformed step 계산 — reject 케이스에서는 어느 pose 도 신뢰 못함. 전부 빈 배열.
        let transformedByPrev: [(stepNumber: Int, ar: simd_float3)] = []
        let transformedByNew: [(stepNumber: Int, ar: simd_float3)] = []
        let transformedByBlended: [(stepNumber: Int, ar: simd_float3)] = []

        // Δtranslation / Δrotation — prev + new 가 모두 있을 때만 산출
        let deltaT: Float = {
            guard let p = prevLocalizedPose,
                  let px = p.x, let py = p.y, let pz = p.z,
                  let nt = response.pose.translation else { return 0 }
            let pv = simd_float3(Float(px), Float(py), Float(pz))
            return simd_length(nt - pv)
        }()
        let deltaRotDeg: Float = {
            guard let p = prevLocalizedPose,
                  let pqx = p.qx, let pqy = p.qy, let pqz = p.qz, let pqw = p.qw,
                  let nq = response.pose.rotationQuaternion else { return 0 }
            let pq = simd_quatf(ix: Float(pqx), iy: Float(pqy), iz: Float(pqz), r: Float(pqw))
            let diff = pq.inverse * nq
            let w = max(-1.0, min(1.0, diff.real))
            let angleRad = 2.0 * acos(abs(w))
            return Float(angleRad * 180.0 / .pi)
        }()

        let prevSLAMPose: SLAMPose? = {
            guard let p = prevLocalizedPose else { return nil }
            return SLAMPose(
                x: p.x, y: p.y, z: p.z, qx: p.qx, qy: p.qy, qz: p.qz, qw: p.qw
            )
        }()

        let arCamPos: simd_float3? = {
            guard capturedPoses.indices.contains(arPoseIndex) else { return nil }
            let m = capturedPoses[arPoseIndex]
            return simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }()

        let snapshot = LocalizeDebugLogger.PeriodicSnapshot(
            capturedImages: capturedImages,
            capturedARPoses: capturedPoses,
            matchedImageIndex: response.matchedImageIndex,
            prevLocalizedPose: prevSLAMPose,
            newServerPose: response.pose,
            blendedLocalizedPose: nil,
            prevMatchedARPose: prevMatchedARPose,
            newMatchedARPose: newMatchedARPose,
            confidence: response.confidence,
            numMatches: response.numMatches,
            floorLevel: response.floorLevel,
            floorId: response.floorId,
            blendAlpha: 0.0,
            deltaTranslationM: deltaT,
            deltaRotationDeg: deltaRotDeg,
            arCameraPosAtCapture: arCamPos,
            steps: self.lastPathSteps,
            transformedStepsByPrev: transformedByPrev,
            transformedStepsByNew: transformedByNew,
            transformedStepsByBlended: transformedByBlended,
            rejectReason: reason
        )
        LocalizeDebugLogger.dumpPeriodic(snapshot)
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

        // 보정된 pose 로 path / checkpoint 재렌더 — 보정 모드: 진행 상태 유지
        self.drawPathFromSteps(self.lastPathSteps, isRelocalizeRefresh: true)
        self.refreshFloorNavigationMap(routeSteps: self.lastPathSteps, currentFrame: arSession?.currentFrame, isRelocalizeRefresh: true)
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

    /// pathfinding steps[].position 들을 server world → AR world 변환 후 PathChevronController 로 시각화.
    /// V3 측위 + lookup 직후 1회 호출. 매 tick 갱신 X (단, PnP 보정 시 재호출됨 — cameraPos 기준 spawn cursor 결정).
    /// - Parameter isRelocalizeRefresh: 주기 재측위/PnP 보정으로 인한 재렌더 여부. true 면 currentStepIndex / turn arrow / marker
    ///   초기화 단계를 건너뛰어 깜빡임을 방지한다. 다음 1Hz tick 에서 자연스럽게 재산정된다.
    private func drawPathFromSteps(_ steps: [PathStep], isRelocalizeRefresh: Bool = false) {
        lastPathSteps = steps
        print("[NAV] path with \(lastPathSteps.count) steps:")
        for (i, s) in lastPathSteps.enumerated() {
            let kind = Self.navigationActionKind(steps: lastPathSteps, at: i)
            let pStr = s.position.map { p in "(\(p.x ?? -999),\(p.y ?? -999))" } ?? "nil"
            print("[NAV]  [\(i)] floor=\(s.floorLevel ?? -1) pos=\(pStr) kind=\(kind) instruction=\"\(s.instruction ?? "")\"")
        }
        // 구 path 노드(sphere/line) 잔재 제거 — Phase 8 호환성 위해 pathNodes 참조 보존.
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

        // 현재 측위된 floor 의 step 만 필터해서 chevron 분포. 층 전환 step 은 별도 모달이 담당.
        let curFloor = localizedFloorLevel
        let filteredARPoints: [simd_float3] = steps.compactMap { step in
            // 다른 floor step 은 제외 (현재 floor 미상이면 모두 포함)
            if let stepFloor = step.floorLevel, let cf = curFloor, stepFloor != cf {
                return nil
            }
            guard let pos = step.position,
                  let x = pos.x, let y = pos.y, let z = pos.z else { return nil }
            let p = CoordinateTransformer.transform(
                serverPoint: simd_float3(Float(x), Float(y), Float(z)),
                input: input
            )
            return simd_float3(p.x, floorY, p.z)
        }
        guard filteredARPoints.count >= 2 else {
            pathChevronController.clear()
            return
        }

        pathChevronController.setRoute(
            arPoints: filteredARPoints,
            floorY: floorY,
            cameraPos: lastCameraPos
        )
        print("[Path] drew \(steps.count) steps as \(filteredARPoints.count) chevron-distribution points (filtered to current floor)")

        // 도착 감지용 destination AR 좌표 갱신. 매 drawPathFromSteps 호출마다 최신 값으로 set
        // (재측위 시에도 갱신되어 transform drift 보정 반영). 마지막 PathStep.position 기준.
        if let lastStep = steps.last, let p = lastStep.position,
           let lx = p.x, let ly = p.y, let lz = p.z {
            let serverDest = simd_float3(Float(lx), Float(ly), Float(lz))
            let arDest = CoordinateTransformer.transform(serverPoint: serverDest, input: input)
            destinationARPosition = simd_float3(arDest.x, floorY, arDest.z)
            print("[Arrival] destinationARPosition = \(destinationARPosition!) (threshold=\(arrivalThreshold)m)")
        }

        if isRelocalizeRefresh {
            // 보정 모드: currentStepIndex / turn arrow / marker 유지. 다음 1Hz tick 이 자연스럽게 재산정.
            return
        }

        // 새 경로 → 도착 감지 타이머 시작 (재측위 분기 이후에만 — 첫 측위 1회만 invalidate→reschedule)
        startArrivalCheck()

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
            numMatches: response.numMatches,
            floorId: response.floorId,
            floorLevel: response.floorLevel,
            steps: rawSteps,
            transformedSteps: transformed
        )
        LocalizeDebugLogger.dump(snapshot)
    }

    /// 후보 1개 이하 도달 시 — 다음 query 좌표(또는 목적지) 로 새 lookup. 결과로 후보 갱신.
    private func triggerNewLookup() {
        // 주기 재측위 정책 전환 — lookup 기반 추적(LightGlue) 폐기. 본 함수는 본문 보존하되 early return.
        if !Self.useLightGlueMatcher {
            print("[NetworkBundle] triggerNewLookup disabled — 주기 재측위 정책 (early return)")
            return
        }

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
    /// 두 4x4 변환행렬을 `alpha` 비율로 보간. translation 은 lerp, rotation 은 slerp 후 재조립.
    /// 주기 V3 재측위에서 localizedPose 와 matchedARPose 를 같은 α 로 blend 해 변환식 정합성 유지.
    /// alpha=0 → prev 그대로, alpha=1 → new 그대로, 그 사이는 중간값.
    private static func blendMatrix(prev: simd_float4x4, new: simd_float4x4, alpha: Float) -> simd_float4x4 {
        let a = max(0, min(1, alpha))
        // Translation: 4번째 열의 (x, y, z)
        let prevTrans = simd_float3(prev.columns.3.x, prev.columns.3.y, prev.columns.3.z)
        let newTrans = simd_float3(new.columns.3.x, new.columns.3.y, new.columns.3.z)
        let blendedTrans = simd_mix(prevTrans, newTrans, simd_float3(repeating: a))

        // Rotation: 3x3 부분을 쿼터니언으로 추출 → slerp → matrix 재구성
        let prevQuat = simd_quatf(prev)
        let newQuat = simd_quatf(new)
        let blendedQuat = simd_slerp(prevQuat, newQuat, a)

        var result = simd_float4x4(blendedQuat)
        result.columns.3 = SIMD4<Float>(blendedTrans.x, blendedTrans.y, blendedTrans.z, 1)
        return result
    }

    private static func rotationDeltaDegrees(from prev: simd_quatf, to new: simd_quatf) -> Float {
        let diff = prev.inverse * new
        let w = max(-1.0, min(1.0, diff.real))
        let angleRad = 2.0 * acos(abs(w))
        return Float(angleRad * 180.0 / .pi)
    }

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

    // MARK: - AR 마커 후보 발신 (단순화 정책)
    /// 1Hz tick 마다 호출. 단일 마커 1개만 발신.
    ///
    /// 정책:
    ///   - 타겟 step = currentStepIndex (다음 도달 step). 그 액션이 straight/unknown 이면
    ///     lookahead 로 다음 의미 있는 step(turn*/stairs*/elevator/arrive) 까지 진행. 끝까지 없으면 lastIdx.
    ///   - 전역 거리 컷오프 없음. 항상 1개 발신 (uTurn 만 hidden 으로 빈 배열).
    ///   - arrive → destination (instruction 키워드로 stairs/elevator override). 거리 무관 즉시 표시.
    ///   - stairsUp/Down → stairs (instruction "ELEVATOR/엘리베이터" 키워드면 elevator override)
    ///   - elevator → elevator
    ///   - turn(좌/우): ≤10m → .nextTurn(화살표), >10m → .distance(거리 마커)
    ///   - uturn → hidden (빈 배열)
    ///   - straight/unknown → 정상 흐름에선 lookahead 가 처리. 방어적으로 빈 배열.
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
        let markerY = floorY + 1.0

        // 타겟 step 선정: currentStepIndex 그대로 시작. straight/unknown 이면 lookahead.
        // lookahead 는 turn 너머에 stairs/elevator/arrive 가 있을 때를 위해 turn 에 거리 가드(≤7m) 를 둔다.
        //  - turn 이 7m 이내: 즉시 break (사용자가 곧 회전 → turn 마커 우선)
        //  - turn 이 7m 초과: skip 하고 다음 step 으로 lookahead 계속 (PathChevron 이 원거리 회전 안내 담당.
        //    turn 마커를 강제로 잡으면 후속 switch 의 d>7.0 가드에 걸려 stairs 까지 통째로 사라짐)
        //  - stairs/elevator/arrive: 거리 무관 즉시 break (Phase4·Phase5 UX 상 항상 우선 표시)
        //  - uturn: 거리 무관 즉시 break (현재 always-hidden 동작 보존 — 후속 switch 에서 빈 배열 반환)
        let lastIdx = lastPathSteps.count - 1
        var nextIdx = max(0, min(currentStepIndex, lastIdx))
        let initialKind = Self.navigationActionKind(steps: lastPathSteps, at: nextIdx)
        if initialKind == .straight || initialKind == .unknown {
            // 다음 의미 있는 step 검색
            if nextIdx + 1 <= lastIdx {
                lookahead: for i in (nextIdx + 1)...lastIdx {
                    let k = Self.navigationActionKind(steps: lastPathSteps, at: i)
                    switch k {
                    case .stairsUp, .stairsDown, .elevator, .arrive:
                        // 거리 무관 즉시 채택. stairs/elevator/arrive 는 항상 표시 우선순위 최상.
                        nextIdx = i
                        break lookahead

                    case .uturn:
                        // uturn 은 후속 switch 에서 hidden 처리(빈 배열). 거리 가드 의미 없음 — 기존 break 동작 유지.
                        nextIdx = i
                        break lookahead

                    case .turnLeft, .turnRight, .turnSlightLeft, .turnSlightRight:
                        // turn 거리 산출: step i 의 server 좌표 → AR world → cameraPos 와 XZ 거리.
                        // ≤7m 면 곧 회전이므로 즉시 break. >7m 면 PathChevron 에 양보하고 lookahead 계속 진행해
                        // 너머의 stairs/elevator/arrive 까지 발견되도록 한다.
                        guard let p = lastPathSteps[i].position,
                              let sx = p.x, let sy = p.y, let sz = p.z else {
                            // 좌표 결손 시 거리 판단 불가 → 보수적으로 continue (skip).
                            // 다음 step 이 stairs/arrive 라면 자연히 그쪽이 채택됨.
                            continue
                        }
                        let sp = simd_float3(Float(sx), Float(sy), Float(sz))
                        let ap = CoordinateTransformer.transform(serverPoint: sp, input: input)
                        let tdx = cameraPos.x - ap.x
                        let tdz = cameraPos.z - ap.z
                        let td = sqrt(tdx * tdx + tdz * tdz)
                        if td <= 7.0 {
                            nextIdx = i
                            break lookahead
                        } else {
                            continue
                        }

                    case .straight, .unknown:
                        continue
                    }
                }
            }
        }

        // 타겟 step 의 server 좌표 → AR world 좌표 변환
        guard let endP = lastPathSteps[nextIdx].position,
              let sx = endP.x, let sy = endP.y, let sz = endP.z else {
            return []
        }
        let serverPoint = simd_float3(Float(sx), Float(sy), Float(sz))
        let arPoint = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
        let worldPos = simd_float3(arPoint.x, markerY, arPoint.z)

        // turn 분기에서 nextTurn ↔ distance 임계 판정용 카메라 ↔ 타겟 XZ 거리.
        let dx = cameraPos.x - worldPos.x
        let dz = cameraPos.z - worldPos.z
        let d = sqrt(dx * dx + dz * dz)

        // 타겟 step 의 액션 종류 + instruction 키워드로 마커 종류 결정
        let targetActionKind = Self.navigationActionKind(steps: lastPathSteps, at: nextIdx)
        let targetInstr = lastPathSteps[nextIdx].instruction ?? ""
        let upper = targetInstr.uppercased()
        // 서버 식별자 ("ST-A1", "EV-A1") 도 stairs/elevator 로 인식. "Start" 충돌 회피 위해 hyphen 포함.
        let hasStairsKw = upper.contains("STAIRS") || targetInstr.contains("계단") || upper.contains("ST-")
        let hasElevatorKw = upper.contains("ELEVATOR") || targetInstr.contains("엘리베이터") || upper.contains("EV-")

        let kind: MarkerKind
        switch targetActionKind {
        case .arrive:
            // 마지막 step. 키워드 매칭 시 stairs/elevator 우선, 그 외 destination.
            if hasElevatorKw { kind = .elevator }
            else if hasStairsKw { kind = .stairs }
            else { kind = .destination }
        case .stairsUp, .stairsDown:
            kind = hasElevatorKw ? .elevator : .stairs
        case .elevator:
            kind = .elevator
        case .turnLeft, .turnSlightLeft:
            // ≤7m 일 때만 화살표 마커 발신. PathChevron 시스템이 원거리 안내 담당이라 distance 강등 폐기.
            if d > 7.0 { return [] }
            kind = .nextTurn(direction: .left)
        case .turnRight, .turnSlightRight:
            if d > 7.0 { return [] }
            kind = .nextTurn(direction: .right)
        case .uturn:
            return []  // hidden
        case .straight, .unknown:
            // lookahead 가 처리해야 하지만 lookahead 가 의미 있는 step 을 못 찾았을 때(=경로 끝까지 straight)
            // 도달. 방어적으로 빈 배열.
            return []
        }

        return [ARMarkerNode(
            id: "step_\(nextIdx)",
            worldPosition: worldPos,
            kind: kind
        )]
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
    // destination/elevator/stairs 마커는 본 로직의 advance 가드(다른 floor 의 step 은 자동 통과, 도착 step 은 lastIdx 정체) 로 자연스럽게 유지/교체된다.
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
            // 층 전환 경계 halt — 다음 step 이 다른 floor 면 여기서 멈춤. detectFloorTransition 이
            // 이 step 을 cur 로 받아 모달 트리거. cascade-advance 로 경계 지나치는 문제 방지.
            if currentStepIndex + 1 < lastPathSteps.count {
                let nxt = lastPathSteps[currentStepIndex + 1]
                if let cf = target.floorLevel, let nf = nxt.floorLevel, cf != nf {
                    break
                }
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
            stopPeriodicRelocalize()
            DispatchQueue.main.async {
                self.delegate?.showArrivalNotification()
            }
        }
    }

    func stopArrivalCheck() {
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
    }

    // MARK: - Polygon 파싱 (Wall centering 용)

    /// FloorMapResponse.polygon.raw (GeoJSON) 에서 polygon ring 들을 추출. 우선 `floor_union` kind 만,
    /// 없으면 전체 feature 의 polygon ring 합집합. WallCenteringController 가 사용자 위치 contains 검사에 사용.
    private static func extractPolygonRings(fromPolygonRaw raw: Data) -> [[CGPoint]] {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }

        var floorUnion: [[CGPoint]] = []
        var allRings: [[CGPoint]] = []
        for feature in features {
            let kind = (feature["properties"] as? [String: Any])?["kind"] as? String
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            let rings = ringsFromGeoJSON(geometry: geometry)
            if rings.isEmpty { continue }
            if kind == "floor_union" {
                floorUnion.append(contentsOf: rings)
            }
            allRings.append(contentsOf: rings)
        }
        return floorUnion.isEmpty ? allRings : floorUnion
    }

    private static func ringsFromGeoJSON(geometry: [String: Any]) -> [[CGPoint]] {
        guard let type = geometry["type"] as? String,
              let coordinates = geometry["coordinates"] as? [Any] else { return [] }
        switch type {
        case "Polygon":
            return coordinates.compactMap { ring in
                guard let r = ring as? [Any] else { return nil }
                return pointsFromGeoJSONRing(r)
            }
        case "MultiPolygon":
            return coordinates.flatMap { polygon -> [[CGPoint]] in
                guard let p = polygon as? [Any] else { return [] }
                return p.compactMap { ring in
                    guard let r = ring as? [Any] else { return nil }
                    return pointsFromGeoJSONRing(r)
                }
            }
        default: return []
        }
    }

    private static func pointsFromGeoJSONRing(_ ring: [Any]) -> [CGPoint] {
        ring.compactMap { item in
            guard let pair = item as? [Any], pair.count >= 2,
                  let x = doubleValueGeoJSON(pair[0]),
                  let y = doubleValueGeoJSON(pair[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    private static func doubleValueGeoJSON(_ value: Any) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - WallCenteringControllerDelegate

extension ARNavigationLogic: WallCenteringControllerDelegate {
    func wallCenteringDidApplyShift(_ shift: simd_float3) {
        // setWorldOrigin(relativeTransform: T) — 새 world = T^-1 * 옛 world.
        // 캐시한 matchedARPose 는 옛 world 좌표 → -shift translation 적용.
        guard let pose = self.matchedARPose else { return }
        var T = matrix_identity_float4x4
        T.columns.3 = SIMD4<Float>(shift.x, 0, shift.z, 1)
        self.matchedARPose = T.inverse * pose

        // 보정 후 경로/미니맵 재렌더 (PnP 보정 / V3 재측위 패턴 따름)
        self.drawPathFromSteps(self.lastPathSteps, isRelocalizeRefresh: true)
        self.refreshFloorNavigationMap(
            routeSteps: self.lastPathSteps,
            currentFrame: self.arSession?.currentFrame,
            isRelocalizeRefresh: true
        )
    }
}
