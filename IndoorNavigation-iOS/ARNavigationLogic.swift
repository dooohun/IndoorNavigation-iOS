import UIKit
import ARKit
import SceneKit

// MARK: - DebugSettings (iOS 설정 앱 기반 디버그 토글)
//
// iOS Settings.app > 앱 설정에서 런타임 토글. UserDefaults(suiteName: nil) 경유.
// 기본값은 AppDelegate에서 register(defaults:)로 false 등록 — 설정 앱을 한 번도 안 열어도 false.
enum DebugSettings {
    static let fullRouteOverlayKey = "debug_full_route_overlay"

    /// true 면 서버 raw 전체 경로를 점·선으로 AR 에 렌더(라우팅 진단용).
    /// false(기본) 면 운영 동작 — 앞쪽 chevron 화살표만 표시.
    /// 호출 시점마다 UserDefaults 를 읽어 설정 앱 변경이 즉시 반영된다.
    static var fullRouteDebugOverlay: Bool {
        UserDefaults.standard.bool(forKey: fullRouteOverlayKey)
    }
}

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
    /// 초기 측위 + pathfinding 응답까지 도착했을 때 사용자에게 "현재 위치가 {POI}이(가) 맞나요?" 모달 표시.
    /// nearPoiName 이 nil/빈 문자열이면 POI 토큰 없이 "현재 위치가 맞나요?" fallback.
    func showStartConfirmation(nearPoiName: String?)
    /// 사용자가 확인/취소를 눌렀거나 새 trial 진입으로 모달이 더 이상 유효하지 않을 때 닫기.
    func dismissStartConfirmation()
    /// 출발지 확인 → "전체 경로 안내" 화면 표시. 사용자가 "안내 시작" 누르면 logic.startNavigation 호출.
    /// items 는 [origin, step…, destination] 형태로 이미 구성됨.
    func showRouteOverview(items: [RouteOverviewItem], totalDistanceMeters: Double, destinationName: String)
    /// startNavigation / cancelRouteOverview 호출 시 화면 dismiss.
    func dismissRouteOverview()
    /// 취소 → 새 trial 진입 직전에 locateButton 라벨을 초기 상태("주변 스캔") 로 복원.
    func resetLocateButtonLabel()
}

// MARK: - Logic

class ARNavigationLogic {

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

    // 디버그: 서버 raw 경로 시각화 (바닥 투영 chevron 과 별개).
    // CoordinateTransformer 가 변환한 server world → AR world 좌표를 floorY 보정 없이
    // "그대로" 점·선으로 그린다. chevron 이 바닥에 깔려 방향 판별이 어려울 때, 서버가 보낸
    // 경로의 실제 3D 위치(높이 포함)를 눈으로 확인해 localize 방향/위치 오류를 진단하는 용도.
    private weak var debugPathParent: SCNNode?
    private var debugRawPathNode: SCNNode?
    /// 호출 시점마다 UserDefaults 를 읽어 설정 앱 변경을 즉시 반영한다.
    /// setDebugRawPathEnabled(_:) 로 외부 override 하려면 _debugRawPathOverride 를 사용한다.
    private var _debugRawPathOverride: Bool? = nil
    private var debugRawPathEnabled: Bool {
        _debugRawPathOverride ?? DebugSettings.fullRouteDebugOverlay
    }

    // 층 이동 인터렉션
    private var hasActiveFloorTransition: Bool = false
    /// triggerFloorTransition 마지막 발화 시각 (CACurrentMediaTime). 동일 step 도달 시 1Hz tick 마다
    /// 재트리거되는 것을 막는 안전망. 사용자가 모달을 닫고 restart 흐름에 진입할 때까지의 짧은 구간에
    /// detectFloorTransition 이 계속 조건 만족할 수 있어 cooldown 으로 방어.
    private var lastFloorTransitionTriggerAt: TimeInterval = 0
    private let floorTransitionRetriggerCooldownSec: TimeInterval = 5.0
    private var pendingRemainingSteps: [PathStep] = []
    private var pendingTargetFloor: Int? = nil
    /// 층 전환 트리거 시 cached floor map 의 connectors[].stops[] 에서 lookup 한 target 층 floorId.
    /// 다음 측위(restartFromFloorTransition 직후)의 floor hint 로 사용 — 옛 userCurrentFloorId 가 stale 인 문제 해결.
    private var pendingTargetFloorId: String? = nil
    private var isFloorTransitionRestart: Bool = false
    /// 층 전환 재시작 직후의 V3 측위 + pathfinding 응답이 도착 층(=startFloorLevel) 단일 층이면
    /// 출발지 확인 모달/RouteOverview 게이트를 건너뛰고 즉시 안내 진입하기 위한 1회성 플래그.
    /// startV3Pathfinding success case 에서 소비. failure / resetForNewTrial 에서도 클리어.
    private var pendingFloorTransitionRestart: Bool = false
    /// 사용자가 "안내 시작" 을 한 번이라도 누른 적이 있는지. true 가 되면 이후 모든 측위(restart / 사용자 재측위 등)
    /// 에서 출발지 확인 모달 + RouteOverview 게이트를 우회하고 즉시 안내 진입. cancelStartConfirmation /
    /// cancelRouteOverview 에서만 false 로 복귀 (사용자가 명시적으로 첫 측위로 되돌리는 경우).
    private var hasShownInitialNavigation: Bool = false
    /// pathfinding 응답의 raw steps (다층 전체). detectFloorTransition 이 prefix 끝의 transition step
    /// 에서 다음 층(targetFloor) 을 raw 에서 lookup 할 때 사용. resetForNewTrial 에서 클리어.
    private var pendingRawSteps: [PathStep] = []
    /// 층 전환 모달 트리거 거리 (m). stairs/elevator 노드 step 위치와 카메라 사이 XZ 거리.
    /// 이 값 이내일 때만 detectFloorTransition 이 트리거. 너무 빡빡하면 빨리 걷는 사용자가 통과 가능, 너무 넓으면 일찍 뜸.
    /// arrivalThreshold(2.0m) 와 경합해 모달이 안 뜨는 문제 방지 위해 3.0m 로 상향.
    private let floorTransitionTriggerDistance: Float = 3.0

    // 경로 시작점 진단
    private var lastStartSnapDistance: Double?

    // 방향 안내 (Phase 5)
    private let guidanceDirector = GuidanceDirector()

    // MARK: - Wall centering (drift 보정 — LiDAR mesh 기반)
    private var wallCenteringController: WallCenteringController?
    private var floorMapPolygonRingsCache: [[CGPoint]] = []

    // MARK: - 주기 재측위 (V3 only)
    /// ARKit pose 누적 drift 를 보정하는 주기적 V3 측위.
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
    /// 2단계 quick win — 3.0 → 5.0 상향. 실측 케이스(2026-05-21 15:41:12)에서 Δ=6.75m + 회전 18° 드리프트가
    /// 그대로 hard-set 되어 path 가 우측으로 밀림 → blend 적용 범위를 넓혀 노이즈 측위 영향 축소.
    private let periodicRelocalizeHardSetThresholdM: Float = 5.0
    /// 주기 V3 재측위 confidence 가드. 초기 측위와 같은 기준으로 wrong-match 위험 응답을 무시.
    private let periodicRelocalizeMinConfidence: Double = 0.50
    /// 주기 V3 재측위 feature match 수 가드. confidence 가 매칭 품질을 이미 반영하므로
    /// 절대값은 노이즈성 floor 만 차단하는 수준으로 낮춤 (이전 80 → 30).
    /// 빌딩 부위마다 서버측 feature 검출 수가 달라 80 은 정상 응답도 자주 떨어트림.
    private let periodicRelocalizeMinMatches: Int = 30
    /// propagated prev quat 대비 응답 quat 회전 변화 가드. propagated 기준이라 정상이면 거의 0,
    /// drift+noise 합쳐도 한 자릿수 도 수준. 45° 는 명백한 wrong-match 만 컷.
    private let periodicRelocalizeMaxRotationDeltaDeg: Float = 45.0
    /// (server pose, ARKit pose) 페어로 정의되는 server-world → ARKit-world 회전이 이전 페어 대비 이 값보다 크게
    /// 흔들리면 wrong-match 로 간주. 실측 케이스(15:41:12)에서 약 18° 회전 드리프트가 path 우측 밀림의 직접 원인.
    private let periodicRelocalizeMaxTransformRotationDeltaDeg: Float = 10.0
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

    /// pathfinding steps 시각화용 노드 (sphere + 인접 segment cylinder).
    private var pathNodes: [SCNNode] = []
    /// drawPathFromSteps 가 받은 마지막 steps — 주기 재측위 후 재렌더용.
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

    // MARK: - 출발지 확인 모달 게이트
    /// 초기 측위 + pathfinding 응답까지 도달 후 사용자 확인 대기 중인지 여부.
    /// true 동안: HUD/리본/쉐브론/미니맵 노출/주기 재측위/벽 보정 모두 보류.
    /// confirmStartLocation 호출 시 false 로 풀리고 pendingPostConfirmRender 가 실행되어 실제 렌더링 시작.
    private var isAwaitingStartConfirmation: Bool = false
    /// 확인 누를 때 실행할 렌더링/HUD/주기 측위 시작 클로저. 취소 시 nil 로 폐기.
    private var pendingPostConfirmRender: (() -> Void)?
    /// 출발지 확인 후 "전체 경로 안내" 화면 구성에 사용할 pathfinding steps.
    /// pathfinding 응답에서 채우고 startNavigation/cancelRouteOverview 호출 시 비움.
    private var pendingOverviewSteps: [PathStep] = []

    // MARK: - 외부 노출

    func setGuidanceDelegate(_ delegate: GuidanceDirectorDelegate) {
        guidanceDirector.delegate = delegate
    }

    /// PathChevron 시스템 부모 노드 등록. ViewController 가 sceneView 준비 후 1회 호출.
    func attachChevronParent(_ parent: SCNNode) {
        pathChevronController.attach(to: parent)
        debugPathParent = parent
    }

    /// 디버그 raw 경로 렌더 토글. 외부(HUD 디버그 버튼 등)에서 on/off.
    /// nil 전달 시 override 를 해제해 UserDefaults(설정 앱) 값으로 복귀.
    func setDebugRawPathEnabled(_ enabled: Bool) {
        _debugRawPathOverride = enabled
        if !enabled {
            debugRawPathNode?.removeFromParentNode()
            debugRawPathNode = nil
        }
    }

    /// PathChevron 가시성 토글. setHUDVisible(false) 와 짝으로 호출 — chevron 도 동반 숨김.
    func setChevronHidden(_ hidden: Bool) {
        pathChevronController.setHidden(hidden)
    }

    /// ARSessionDelegate.session(_:didUpdate:) 에서 매 프레임 호출.
    /// 2D 지도 위치 / step vm / chevron / 마커 / floor-transition 검출을 1Hz throttle 로 갱신.
    func processARFrame(_ frame: ARFrame) {
        guard !lastPathSteps.isEmpty else { return }

        let floorNavigationPose = currentFloorNavigationPose(frame: frame)
        delegate?.updateFloorNavigationPosition(
            floorNavigationPose?.position,
            headingDegrees: floorNavigationPose?.headingDegrees
        )

        let now = CACurrentMediaTime()
        guard now - lastNavStepTickAt >= 1.0 else { return }
        lastNavStepTickAt = now

        let cam = simd_float3(frame.camera.transform.columns.3.x,
                              frame.camera.transform.columns.3.y,
                              frame.camera.transform.columns.3.z)
        recomputeCurrentStepIndex(cameraPos: cam)
        // Floor-transition 자동 트리거: currentStepIndex 가 floor 변경 직전 step 도달 시 모달 표시.
        // cooldown 으로 매 tick 반복 트리거 방어 (안전망).
        let nowMt = CACurrentMediaTime()
        if !hasActiveFloorTransition,
           nowMt - lastFloorTransitionTriggerAt >= floorTransitionRetriggerCooldownSec,
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
        // 다음 drawPathFromSteps 가 chevron 분포 cursor 결정에 사용할 카메라 캐시.
        lastCameraPos = cam
    }

    // MARK: - 다중 프레임 캡처 후 Localize

    /// 새 trial(측위) 시작 시 잔여 상태/노드/타이머 일괄 정리. idempotent — 여러 번 호출해도 안전.
    /// 화면 더블탭으로 측위 재시작 시에도 재사용.
    private func resetForNewTrial() {
        // SCNNode 제거
        destinationPinNode = nil
        pathChevronController.clear()
        debugRawPathNode?.removeFromParentNode()
        debugRawPathNode = nil
        delegate?.updateTurnArrow(nil)
        delegate?.updateMarkers([])

        // timer 정지
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
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
        pathNodes.forEach { $0.removeFromParentNode() }
        pathNodes = []
        lastPathSteps = []
        floorMapRequestGeneration += 1
        delegate?.hideFloorNavigationMap()
        currentStepIndex = 0
        lastNavStepTickAt = 0

        // capture 버퍼 클리어
        capturedImages = []
        capturedARPoses = []
        capturedDepths = []
        lastCaptureTimestamp = nil

        // GuidanceDirector 도 reset (Phase 5 dead path 지만 호출 부수효과 없게)
        guidanceDirector.reset()

        // 출발지 확인 모달 게이트도 함께 리셋 — 새 trial 진입 시 이전 pending 렌더링/대기 상태 폐기.
        isAwaitingStartConfirmation = false
        pendingPostConfirmRender = nil
        pendingOverviewSteps = []
        pendingRawSteps = []
        // 층 전환 재시작 1회성 플래그도 리셋 — 새 trial 은 일반 흐름이라 도착 층 즉시 안내 게이트 우회 X.
        pendingFloorTransitionRestart = false
        // hasShownInitialNavigation 는 명시적 cancel 외엔 유지 — trial 갱신만으로 모달이 다시 뜨지 않게.
    }

    func startLocalizationFlow() {
        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }
        // 출발지 확인 모달이 떠 있는 동안엔 새 측위 트리거 차단 — 더블탭/외부 호출 중복 방지.
        if isAwaitingStartConfirmation { return }

        // 이미 측위 진행 중(=localizedPose 존재 + 활성 경로 보유)이면 hard reset 금지.
        // 사용자가 locate 버튼을 재탭한 경우 path/marker/chevron/currentStepIndex 전부 유지하고
        // 즉시 1회 주기 측위만 강제 트리거해서 ARKit world origin drift 를 보정한다.
        // (resetForNewTrial → 서버 wrong-match → 새 19-step 경로 발급으로 인한 60m 오안내 방지)
        if localizedPose != nil && !lastPathSteps.isEmpty {
            // 사용자 수동 측위 트리거 — 다른 층으로 이동했을 가능성 있어 옛 floorId hint 금지.
            // localizedFloorId 비워두면 floorIdHint 우선순위가 자연스럽게 nil(ANY 매칭) 또는
            // pendingTargetFloorId 로 떨어진다. drift 보정 케이스도 ANY 매칭이 같은 층 잡으므로 무해.
            localizedFloorId = nil
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
            // 층 전환 후 lookup 실패한 경우엔 옛 시작층(userCurrentFloorId) hint 금지 — wrong-match 방지.
            // 차라리 nil 로 두고 서버 ANY 매칭에 위임한다.
            if pendingFloorTransitionRestart { return nil }
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
        guard response.confidence >= 0.50 else {
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
        // updateStatus / setHUDVisible / lastPeriodicRelocalizeCameraPos / startPeriodicRelocalize /
        // startWallCenteringIfNeeded 은 출발지 확인 모달 "확인" 후 pendingPostConfirmRender 안에서 실행.
        startV3Pathfinding(startFloorLevel: response.floorLevel,
                           translation: translation,
                           areaId: response.areaId)
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
    }
    #endif

    /// 2D floor map 갱신. 신규 경로 흐름에서는 configure (showFloorNavigationMap) 로 전체 재구성.
    /// - Parameter isRelocalizeRefresh: 주기 재측위/PnP 보정 시 호출이면 true. 현재는 일반 경로(showFloorNavigationMap)
    ///   와 동일 흐름 — routeSteps 갱신을 보장하기 위함. 위치/방향 시각적 보간은 delegate 측 책임.
    /// - Parameter onMapReady: floorMapCache 적재(캐시 hit / fetch 성공 / fetch 실패) 가 끝나면 호출되는 콜백.
    ///   출발지 확인 모달 표시 타이밍 게이트로 사용 — nearestPOIName 이 destinations 를 읽으려면 캐시가 채워져 있어야 함.
    private func refreshFloorNavigationMap(routeSteps: [PathStep],
                                           currentFrame: ARFrame?,
                                           isRelocalizeRefresh: Bool = false,
                                           onMapReady: (() -> Void)? = nil) {
        let resolvedFloorId = localizedFloorId ?? floorId
        guard !resolvedFloorId.isEmpty else { return }

        // 캐시 키는 floorId#areaId 조합 — 같은 층이라도 area 가 다르면 다른 map 응답.
        let resolvedAreaId = localizedAreaId ?? ""
        let cacheKey = "\(resolvedFloorId)#\(resolvedAreaId)"

        let currentPose = currentFloorNavigationPose(frame: currentFrame)

        // 보정 모드 + 캐시 hit 분기 제거: routeSteps 갱신 없이 position 만 업데이트되면 2D 경로가 stale.
        // 캐시 hit 일반 분기(아래 showFloorNavigationMap)로 통일 — 시각적 점프 방지는 delegate 측 보간 책임.

        let cachedFloorLevel = floorMapCache[cacheKey]?.floorLevel ?? localizedFloorLevel
        let destinationPoint: CGPoint? = {
            // 현재 층의 마지막 step 이 transition (계단/엘리베이터) 이면 destinationPin 미표시 —
            // 2D 미니맵의 0.2m 가드가 같은 좌표의 계단/엘리베이터 노드 마커를 가리는 문제 방지.
            if let lvl = cachedFloorLevel,
               let lastIdxOnFloor = routeSteps.lastIndex(where: { $0.floorLevel == lvl }) {
                let lastOnFloor = routeSteps[lastIdxOnFloor]
                let lastAction = Self.navigationActionKind(steps: routeSteps, at: lastIdxOnFloor)
                if isTransitionStep(lastOnFloor, action: lastAction) { return nil }
                if let pos = lastOnFloor.position, let x = pos.x, let y = pos.y {
                    return CGPoint(x: x, y: y)
                }
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
            // 출발지 확인 모달 대기 중엔 2D 미니맵 노출 지연 — 사용자가 확인을 눌러야 보임.
            if !isAwaitingStartConfirmation {
                delegate?.showFloorNavigationMap(
                    cached,
                    routeSteps: routeSteps,
                    currentPosition: currentPose?.position,
                    currentHeadingDegrees: currentPose?.headingDegrees,
                    destinationName: self.destinationName,
                    destinationWorldPoint: destinationPoint
                )
            }
            onMapReady?()
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
                        // 현재 층 마지막 step 이 transition 이면 destinationPin 미표시 (2D 마커 가림 방지).
                        if let lastIdxOnFloor = routeSteps.lastIndex(where: { $0.floorLevel == map.floorLevel }) {
                            let lastOnFloor = routeSteps[lastIdxOnFloor]
                            let lastAction = Self.navigationActionKind(steps: routeSteps, at: lastIdxOnFloor)
                            if self.isTransitionStep(lastOnFloor, action: lastAction) { return nil }
                            if let pos = lastOnFloor.position, let x = pos.x, let y = pos.y {
                                return CGPoint(x: x, y: y)
                            }
                        }
                        guard let pos = routeSteps.last?.position, let x = pos.x, let y = pos.y else { return nil }
                        return CGPoint(x: x, y: y)
                    }()
                    // 출발지 확인 모달 대기 중엔 2D 미니맵 노출 지연.
                    if !self.isAwaitingStartConfirmation {
                        self.delegate?.showFloorNavigationMap(
                            map,
                            routeSteps: routeSteps,
                            currentPosition: currentPose?.position,
                            currentHeadingDegrees: currentPose?.headingDegrees,
                            destinationName: self.destinationName,
                            destinationWorldPoint: destinationPoint
                        )
                    }
                    onMapReady?()
                case .failure(let error):
                    print("[FloorMap] fetch failed floorId=\(resolvedFloorId) areaId=\(self.localizedAreaId ?? "nil"): \(error)")
                    // 실패해도 모달은 fallback 텍스트로 띄울 수 있게 콜백 호출.
                    onMapReady?()
                }
            }
        }
    }

    private func currentFloorNavigationPose(frame: ARFrame?) -> (position: Position, headingDegrees: Float?)? {
        // 매칭 시점 페어를 현재 카메라 시점으로 전진 — 전진된 server camera pose 가 곧 "지금 사용자 위치/방향".
        // frame == nil 일 땐 bridgePosePair 가 matched 페어 그대로 반환하므로 fallback 동작 보존.
        guard let bridge = bridgePosePair(currentFrame: frame) else { return nil }
        let heading = serverHeadingDegrees(from: bridge.serverQuat)
        return (
            Position(x: Double(bridge.serverPos.x),
                     y: Double(bridge.serverPos.y),
                     z: Double(bridge.serverPos.z)),
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

    /// matchedARPose (캡처 시점 ARKit pose) ↔ currentFrame.camera.transform (렌더 시점 ARKit pose) 의
    /// motion delta 만큼 서버 pose 를 server world frame 에서 전진시켜 새 bridge 페어를 반환.
    ///
    ///   ΔT_AR    = currentAR · matchedAR⁻¹                       (ARKit world 내 모션)
    ///   T_AW←SW  = matchedAR · M · T_SC_match⁻¹                  (server world → ARKit world bridge)
    ///   ΔT_SW    = T_AW←SW⁻¹ · ΔT_AR · T_AW←SW                   (conjugation: ARKit world → server world)
    ///   T_SC_now = ΔT_SW · T_SC_match                            (서버 pose 같은 모션 전진)
    ///
    /// `currentFrame == nil` 또는 matched 데이터 누락 시 매칭 시점 페어 그대로 반환.
    /// ARKit 가 drift 없는 한 결과는 (T_SC_match, matchedARPose) 와 변환식 상 등가지만, drift 가 있으면
    /// "현재 카메라 시점" 기준으로 그만큼을 흡수해 chevron / 2D heading 이 같이 따라간다.
    private func bridgePosePair(currentFrame: ARFrame?)
        -> (serverPos: simd_float3, serverQuat: simd_quatf, arCameraPose: simd_float4x4)?
    {
        guard let pose = localizedPose,
              let px = pose.x, let py = pose.y, let pz = pose.z,
              let qx = pose.qx, let qy = pose.qy, let qz = pose.qz, let qw = pose.qw,
              let matchedAR = matchedARPose else { return nil }

        let matchedPos = simd_float3(Float(px), Float(py), Float(pz))
        let matchedQuat = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))

        guard let frame = currentFrame else {
            return (matchedPos, matchedQuat, matchedAR)
        }
        let currentAR = frame.camera.transform

        // T_SC_match : server world ← server camera (matched 시점)
        var T_SC_match = simd_float4x4(matchedQuat)
        T_SC_match.columns.3 = simd_float4(matchedPos.x, matchedPos.y, matchedPos.z, 1)

        // T_AW_from_SW : server world → ARKit world (matched 시점 페어로 정의)
        let T_AW_from_SW = matchedAR
            * CoordinateTransformer.rtabCameraToARKit
            * T_SC_match.inverse

        // 모션을 server world frame 으로 conjugation
        let deltaAR = currentAR * matchedAR.inverse
        let deltaSW = T_AW_from_SW.inverse * deltaAR * T_AW_from_SW

        // 전진된 server camera pose
        let T_SC_now = deltaSW * T_SC_match
        let newPos = simd_float3(T_SC_now.columns.3.x, T_SC_now.columns.3.y, T_SC_now.columns.3.z)
        let R_now = simd_float3x3(
            simd_float3(T_SC_now.columns.0.x, T_SC_now.columns.0.y, T_SC_now.columns.0.z),
            simd_float3(T_SC_now.columns.1.x, T_SC_now.columns.1.y, T_SC_now.columns.1.z),
            simd_float3(T_SC_now.columns.2.x, T_SC_now.columns.2.y, T_SC_now.columns.2.z)
        )
        let newQuat = simd_quatf(R_now)

        // diagnostic: 페어 propagation 후 server heading / position 변화량 로깅
        let matchedHeading = serverHeadingDegrees(from: matchedQuat)
        let propagatedHeading = serverHeadingDegrees(from: newQuat)
        var yawDelta = propagatedHeading - matchedHeading
        while yawDelta > 180 { yawDelta -= 360 }
        while yawDelta < -180 { yawDelta += 360 }
        let posDelta = simd_distance(matchedPos, newPos)
        if abs(yawDelta) >= 0.5 || posDelta >= 0.05 {
            print(String(format: "[BridgePair] match→now yawΔ=%.2f° posΔ=%.2fm",
                         yawDelta, posDelta))
        }

        return (newPos, newQuat, currentAR)
    }

    // MARK: - 경로 탐색

    /// pathfinding 응답 steps 를 현재 측위 층의 prefix 까지만 잘라 반환.
    /// 층 전환 step 이후의 다른 층 좌표가 그대로 들어와 RouteOverview 거리 점프 / AR 렌더링 비정상
    /// 노드 위치를 유발하는 문제 방지. 잘려나간 후속 step 은 triggerFloorTransition 에서 재측위 후
    /// pendingRemainingSteps 로 다시 흐른다.
    /// - 정책:
    ///   1) floor == nil OR steps.isEmpty → 필터 미적용, 원본 반환.
    ///   2) step.floorLevel == nil 인 step → 직전 floor 와 같다고 가정하고 append 계속.
    ///   3) step.floorLevel != floor 이고 result 비어있지 않음 → break (prefix 종료).
    ///   4) 첫 step 부터 floor 가 다르면 비정상 → 경고 로그 + 빈 배열 반환.
    private func currentFloorPrefix(_ steps: [PathStep], floor: Int?) -> [PathStep] {
        guard let floor, !steps.isEmpty else { return steps }
        var result: [PathStep] = []
        for step in steps {
            if let sf = step.floorLevel {
                if sf == floor {
                    result.append(step)
                } else {
                    if result.isEmpty {
                        print("[V3-PATH] currentFloorPrefix: 첫 step 부터 floor 불일치 (step.floor=\(sf), localFloor=\(floor)) — 빈 배열 반환")
                        return []
                    }
                    break
                }
            } else {
                // floorLevel 미상 → 직전 floor 와 같다고 가정.
                result.append(step)
            }
        }
        if result.count != steps.count {
            print("[V3-PATH] currentFloorPrefix: \(steps.count) → \(result.count) (floor=\(floor))")
        }
        return result
    }

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
                    // 현재 측위 층의 prefix 까지만 사용 — 층 전환 후 다른 층 좌표가 들어와 거리 점프/
                    // 비정상 노드 위치 유발하는 버그 방지. 잘려나간 후속 step 은 floor transition 모달
                    // 이후 재측위 시 새 pathfinding 으로 다시 흐른다.
                    let prefixed = self.currentFloorPrefix(steps, floor: startFloorLevel)
                    self.lastStartSnapDistance = nil
                    print("[V3-PATH] steps raw=\(steps.count) prefixed=\(prefixed.count), totalDistance=\(resp.totalDistance)m, floorTransitions=\(resp.floorTransitions?.count ?? 0)")

                    if isRelocalizeRefresh {
                        // 주기 재측위 경로 — 기존 흐름 그대로 (이미 확인된 사용자라 게이트 우회).
                        self.drawPathFromSteps(prefixed, isRelocalizeRefresh: true)
                        self.refreshFloorNavigationMap(routeSteps: prefixed,
                                                       currentFrame: self.arSession?.currentFrame,
                                                       isRelocalizeRefresh: true)
                        return
                    }

                    // 출발지 확인 모달 + RouteOverview 는 "오직 첫 localize" 에만 노출.
                    // 한 번 "안내 시작" 을 통과한 후엔 (layer transition restart / 사용자 재측위 등) 모달 우회.
                    // raw steps 보관 — detectFloorTransition 의 prefix 끝 transition 케이스에서 다음 층 lookup.
                    self.pendingRawSteps = steps
                    if self.hasShownInitialNavigation {
                        self.pendingFloorTransitionRestart = false
                        self.drawPathFromSteps(prefixed, isRelocalizeRefresh: false)
                        self.refreshFloorNavigationMap(routeSteps: prefixed,
                                                       currentFrame: self.arSession?.currentFrame,
                                                       isRelocalizeRefresh: false)
                        self.dumpLocalizeDebug(rawSteps: resp.steps)
                        self.delegate?.setHUDVisible(true)
                        self.delegate?.updateStatus("\(self.destinationName) 방향으로 이동하세요.", color: .white)
                        if let mPose = self.matchedARPose {
                            let c = mPose.columns.3
                            self.lastPeriodicRelocalizeCameraPos = simd_float3(c.x, c.y, c.z)
                        }
                        self.startPeriodicRelocalize()
                        self.startWallCenteringIfNeeded()
                        return
                    }
                    // 일반 흐름 진입 — stale 플래그 클리어 (예: 층 전환 후 응답에 추가 층 전환 step 포함된 케이스).
                    self.pendingFloorTransitionRestart = false

                    // 초기 측위 + 첫 pathfinding 응답 — 게이트.
                    // 실제 렌더링/HUD/주기 측위 시작은 사용자가 출발지 확인 모달에서 "확인" 을 눌러야 일어남.
                    // RouteOverview 는 다층 전체(raw)를 보여줘야 함 — prefix 자르면 단일 층만 노출됨.
                    self.pendingOverviewSteps = steps
                    self.isAwaitingStartConfirmation = true
                    self.pendingPostConfirmRender = { [weak self] in
                        guard let self else { return }
                        self.drawPathFromSteps(prefixed, isRelocalizeRefresh: false)
                        self.refreshFloorNavigationMap(routeSteps: prefixed,
                                                       currentFrame: self.arSession?.currentFrame,
                                                       isRelocalizeRefresh: false)
                        self.dumpLocalizeDebug(rawSteps: resp.steps)
                        self.delegate?.setHUDVisible(true)
                        self.delegate?.updateStatus("\(self.destinationName) 방향으로 이동하세요.", color: .white)
                        if let mPose = self.matchedARPose {
                            let c = mPose.columns.3
                            self.lastPeriodicRelocalizeCameraPos = simd_float3(c.x, c.y, c.z)
                        }
                        self.startPeriodicRelocalize()
                        self.startWallCenteringIfNeeded()
                    }

                    // map cache 가 채워진 직후 nearestPOIName 결정 가능 → 모달 표시.
                    self.refreshFloorNavigationMap(
                        routeSteps: prefixed,
                        currentFrame: self.arSession?.currentFrame,
                        isRelocalizeRefresh: false,
                        onMapReady: { [weak self] in
                            guard let self, self.isAwaitingStartConfirmation else { return }
                            let name = self.nearestPOIName()
                            self.delegate?.showStartConfirmation(nearPoiName: name)
                        }
                    )
                case .failure(let err):
                    let msg = String(describing: err)
                    print("[V3-PATH] 실패 (\(msg))")
                    // stale 플래그 클리어 — 다음 trial 일반 흐름.
                    self.pendingFloorTransitionRestart = false
                    self.delegate?.showRouteCalculating(false)
                    self.delegate?.setLoading(false)
                }
            }
        }
    }

    // MARK: - 출발지 확인 모달 API

    /// 현재 측위 좌표(localizedPose.x/y) 와 cache 된 floor map 의 destinations[] XY 거리가 가장 가까운 POI 이름.
    /// destinations 가 없거나 좌표 결정 불가하면 nil. caller 측에서 nil/빈 문자열 fallback → "현재 위치가 맞나요?" 처리.
    private func nearestPOIName() -> String? {
        guard let pose = localizedPose, let pX = pose.x, let pY = pose.y else { return nil }
        let resolvedFloorId = localizedFloorId ?? floorId
        let resolvedAreaId = localizedAreaId ?? ""
        let cacheKey = "\(resolvedFloorId)#\(resolvedAreaId)"
        guard let map = floorMapCache[cacheKey],
              let destinations = map.destinations,
              !destinations.isEmpty else {
            return nil
        }

        var bestName: String?
        var bestDist = Double.greatestFiniteMagnitude
        for dest in destinations {
            guard let dx = dest.x, let dy = dest.y else { continue }
            let ddx = dx - pX
            let ddy = dy - pY
            let d = sqrt(ddx * ddx + ddy * ddy)
            if d < bestDist {
                bestDist = d
                if let n = dest.name, !n.isEmpty {
                    bestName = n
                } else if let l = dest.label, !l.isEmpty {
                    bestName = l
                } else {
                    bestName = nil
                }
            }
        }
        if let n = bestName, !n.isEmpty { return n }
        return nil
    }

    /// 출발지 확인 모달의 "확인" 버튼 콜백. 모달 dismiss + 전체 경로 안내 화면 표시.
    /// 게이트(isAwaitingStartConfirmation) 는 startNavigation 호출 전까지 true 로 유지 — 더블탭 재진입 차단 보존.
    /// 실제 렌더링은 pendingPostConfirmRender 에 그대로 보존, startNavigation 에서 실행.
    func confirmStartLocation() {
        guard isAwaitingStartConfirmation else { return }
        // 게이트는 풀지 않음. pendingPostConfirmRender 도 보존.
        delegate?.dismissStartConfirmation()
        let items = makeRouteOverviewItems(steps: pendingOverviewSteps)
        let total = computeTotalDistanceMeters(steps: pendingOverviewSteps)
        delegate?.showRouteOverview(items: items, totalDistanceMeters: total, destinationName: destinationName)
    }

    /// "전체 경로 안내" 화면의 "안내 시작" 버튼 콜백. 보류된 렌더링/HUD/주기 측위 시작.
    func startNavigation() {
        guard isAwaitingStartConfirmation else { return }
        isAwaitingStartConfirmation = false
        hasShownInitialNavigation = true
        let work = pendingPostConfirmRender
        pendingPostConfirmRender = nil
        pendingOverviewSteps = []
        delegate?.dismissRouteOverview()
        work?()
    }

    /// "전체 경로 안내" 화면의 닫기/취소 콜백. 게이트 해제 + 새 trial 진입 준비 + 사용자에게 재 스캔 안내.
    /// cancelStartConfirmation 과 동일한 UI 복귀 흐름이지만 dismissRouteOverview 를 호출.
    func cancelRouteOverview() {
        guard isAwaitingStartConfirmation else { return }
        isAwaitingStartConfirmation = false
        hasShownInitialNavigation = false
        pendingPostConfirmRender = nil
        pendingOverviewSteps = []
        trialNumber += 1
        resetForNewTrial()
        delegate?.dismissRouteOverview()
        delegate?.setHUDVisible(false)
        delegate?.hideFloorNavigationMap()
        delegate?.setLoading(false)
        delegate?.showRouteCalculating(false)
        delegate?.updateStatus("다시 한번 주변을 스캔해 주세요", color: .white)
        delegate?.resetLocateButtonLabel()
        delegate?.setLocateButtonVisible(true)
    }

    /// 출발지 확인 모달의 "취소" 버튼 콜백. 게이트 해제 + 새 trial 진입 준비 + 사용자에게 재 스캔 안내.
    func cancelStartConfirmation() {
        guard isAwaitingStartConfirmation else { return }
        isAwaitingStartConfirmation = false
        hasShownInitialNavigation = false
        pendingPostConfirmRender = nil
        pendingOverviewSteps = []
        trialNumber += 1
        resetForNewTrial()
        delegate?.dismissStartConfirmation()
        delegate?.setHUDVisible(false)
        delegate?.hideFloorNavigationMap()
        delegate?.setLoading(false)
        delegate?.showRouteCalculating(false)
        delegate?.updateStatus("다시 한번 주변을 스캔해 주세요", color: .white)
        delegate?.resetLocateButtonLabel()
        delegate?.setLocateButtonVisible(true)
    }

    // MARK: - RouteOverview 헬퍼

    /// 주어진 step 이 층 이동(계단/엘리베이터) step 인지 판정.
    /// - instruction 키워드(STAIRS/STAIRCASE/ELEVATOR/ST-/EV-/계단/엘리베이터) 매칭 OR
    /// - navigationActionKind 가 stairsUp/stairsDown/elevator
    /// 둘 중 하나라도 만족하면 true.
    private func isTransitionStep(_ step: PathStep, action: NavigationActionKind) -> Bool {
        switch action {
        case .stairsUp, .stairsDown, .elevator: return true
        default: break
        }
        guard let instr = step.instruction, !instr.isEmpty else { return false }
        let upper = instr.uppercased()
        let keywords = ["TAKE_STAIRS", "STAIRS", "STAIRCASE", "ST-",
                        "TAKE_ELEVATOR", "ELEVATOR", "EV-",
                        "계단", "엘리베이터"]
        return keywords.contains { upper.contains($0) || instr.contains($0) }
    }

    /// pathfinding steps 를 RouteOverviewItem 배열로 변환. [origin] + step rows + [destination].
    /// - origin: 첫 step 의 floorLevel 사용.
    /// - 각 step row: navigationActionKind 재사용. instruction 빈 경우 action 기반 한국어 fallback.
    /// - distanceMeters: 직전 valid position 으로부터의 XY 유클리드 거리(Z 무시).
    ///   단, 직전 step 과 floorLevel 이 다르면 (= 층 전환 경계) 거리 0 (UI 상 hidden).
    /// - destination: 마지막 valid position 까지의 거리(없으면 0). raw 전체를 받기 때문에 마지막 step 은
    ///   최종 목적지 floor 노드.
    /// - steps.isEmpty → [origin, destination] 2행만 fallback.
    private func makeRouteOverviewItems(steps: [PathStep]) -> [RouteOverviewItem] {
        var items: [RouteOverviewItem] = []

        // origin
        let originFloor: Int? = steps.first?.floorLevel
        items.append(RouteOverviewItem(
            kind: .origin,
            action: .unknown,
            instruction: "현재 위치",
            distanceMeters: 0,
            floorLevel: originFloor
        ))

        // step rows
        var prevPos: (Double, Double)? = nil
        var prevFloor: Int? = nil
        for (i, s) in steps.enumerated() {
            let action = Self.navigationActionKind(steps: steps, at: i)
            // 거리: 직전 valid position 에서 현재 step 의 (x, y) 까지.
            // 단, 직전 step 과 floorLevel 이 다르면(= 층 경계) 거리 0 (UI 상 hidden).
            var dist: Double = 0
            if let sx = s.position?.x, let sy = s.position?.y {
                if let (px, py) = prevPos {
                    let isFloorBoundary: Bool = {
                        if let pf = prevFloor, let sf = s.floorLevel, pf != sf { return true }
                        return false
                    }()
                    if isFloorBoundary {
                        dist = 0
                    } else {
                        let dx = sx - px
                        let dy = sy - py
                        dist = sqrt(dx * dx + dy * dy)
                    }
                }
                prevPos = (sx, sy)
            }
            if let sf = s.floorLevel { prevFloor = sf }
            // instruction: turn 은 인근 POI 결합, 계단은 노드명 결합, 나머지는 action fallback.
            // 단, 직전 step 이 같은 transition (예: 계단 진입 → 계단 도착) 인 경우 두 번째 행은
            // "{도착 층}층 도착" 같은 통합 문구로 자연스럽게 표시.
            let prev: PathStep? = (i > 0) ? steps[i - 1] : nil
            let instr: String = {
                if let prev,
                   isTransitionStep(prev, action: Self.navigationActionKind(steps: steps, at: i - 1)),
                   isTransitionStep(s, action: action),
                   let arrivedFloor = s.floorLevel {
                    return "\(arrivedFloor)층 도착"
                }
                return contextualInstructionText(
                    for: action,
                    step: s,
                    previousStep: prev,
                    floorLevel: s.floorLevel ?? localizedFloorLevel
                )
            }()
            items.append(RouteOverviewItem(
                kind: .step,
                action: action,
                instruction: instr,
                distanceMeters: dist,
                floorLevel: s.floorLevel
            ))
        }

        // destination — raw 전체를 받기 때문에 마지막 step 은 최종 목적지 floor 노드.
        // (기존 isTransitionTail 가드는 prefix 가 잘려 transition step 이 tail 인 경우만 해당했고,
        //  raw 입력으로는 항상 destination 행을 표시해야 한다.)
        let destFloor: Int? = steps.last?.floorLevel
        items.append(RouteOverviewItem(
            kind: .destination,
            action: .unknown,
            instruction: destinationName,
            distanceMeters: 0,
            floorLevel: destFloor
        ))

        return items
    }

    /// steps[i-1].position ↔ steps[i].position XY 유클리드 거리 합(Z 무시). 좌표 nil step 은 skip하고 직전 valid 유지.
    /// 단, 직전 step 과 floorLevel 이 다르면(= 층 경계) 합산 제외 — 다층 raw 경로에서 가짜 거리 점프 방지.
    private func computeTotalDistanceMeters(steps: [PathStep]) -> Double {
        var total: Double = 0
        var prevPos: (Double, Double)? = nil
        var prevFloor: Int? = nil
        for s in steps {
            guard let sx = s.position?.x, let sy = s.position?.y else { continue }
            if let (px, py) = prevPos {
                let sameFloor: Bool = {
                    if let pf = prevFloor, let sf = s.floorLevel { return pf == sf }
                    return true   // 둘 중 하나라도 nil 이면 직전 floor 와 같다고 가정.
                }()
                if sameFloor {
                    let dx = sx - px
                    let dy = sy - py
                    total += sqrt(dx * dx + dy * dy)
                }
            }
            prevPos = (sx, sy)
            if let sf = s.floorLevel { prevFloor = sf }
        }
        return total
    }

    /// NavigationActionKind → 한국어 표시 문구. RouteOverview 에서도 동일 매핑 사용.
    /// RouteOverviewStepCell.koreanInstruction(for:) 과 1:1 동기화 유지할 것.
    private static func fallbackInstructionText(for action: NavigationActionKind) -> String {
        switch action {
        case .straight: return "직진"
        case .turnLeft: return "좌회전"
        case .turnRight: return "우회전"
        case .turnSlightLeft: return "좌측 방향"
        case .turnSlightRight: return "우측 방향"
        case .uturn: return "유턴"
        case .stairsUp: return "계단으로 위층 이동"
        case .stairsDown: return "계단으로 아래층 이동"
        case .elevator: return "엘리베이터 이용"
        case .arrive: return "목적지 도착"
        case .unknown: return "이동"
        }
    }

    // MARK: - RouteOverview instruction 문맥 합성

    /// step 에 따라 POI/계단 문맥을 합성한 instruction 텍스트 생성.
    /// - turnLeft/turnRight: 3m 이내 POI(transition 제외) 발견 시 "{name} 앞에서/지나쳐서 좌/우회전".
    /// - stairsUp/stairsDown: 계단 노드명 발견 시 "{name}(계단)으로 위/아래층 이동".
    /// - 그 외/매칭 실패: fallbackInstructionText.
    private func contextualInstructionText(
        for action: NavigationActionKind,
        step: PathStep,
        previousStep: PathStep?,
        floorLevel: Int?
    ) -> String {
        switch action {
        case .turnLeft, .turnRight:
            guard let poi = findNearestPOI(
                at: step.position,
                floorLevel: floorLevel,
                maxDistance: 3.0,
                excludingTransitions: true
            ) else {
                return Self.fallbackInstructionText(for: action)
            }
            let rel = relation(step: step, previousStep: previousStep, poiX: poi.x, poiY: poi.y)
            let turnText: String = (action == .turnLeft) ? "좌회전" : "우회전"
            switch rel {
            case .before:
                return "\(poi.name) 앞에서 \(turnText)"
            case .past:
                return "\(poi.name) 지나쳐서 \(turnText)"
            }
        case .stairsUp, .stairsDown:
            guard let name = findTransitionName(forStep: step, floorLevel: floorLevel) else {
                return Self.fallbackInstructionText(for: action)
            }
            let direction: String = (action == .stairsUp) ? "위층" : "아래층"
            let label: String = name.contains("계단") ? name : "\(name) 계단"
            return "\(label)으로 \(direction) 이동"
        default:
            return Self.fallbackInstructionText(for: action)
        }
    }

    /// POI 와 turn step 의 진행 방향 상 위치 관계.
    /// - before: turn 직전(아직 POI 를 지나치지 않음)
    /// - past: POI 를 지나친 직후
    private enum POIRelation {
        case before
        case past
    }

    /// floorMapCache 의 destinations[] 중 step.position 의 XY 거리 ≤ maxDistance 인 가장 가까운 POI.
    /// excludingTransitions=true 면 isTransitionDestination 판정된 항목 제외.
    /// cache miss / position nil / floorLevel mismatch / 이름 빈 destination 만 → nil.
    private func findNearestPOI(
        at position: Position?,
        floorLevel: Int?,
        maxDistance: Double,
        excludingTransitions: Bool
    ) -> (name: String, x: Double, y: Double, distance: Double)? {
        guard let pos = position, let px = pos.x, let py = pos.y else { return nil }
        let resolvedFloorId = localizedFloorId ?? floorId
        let resolvedAreaId = localizedAreaId ?? ""
        let cacheKey = "\(resolvedFloorId)#\(resolvedAreaId)"
        guard let map = floorMapCache[cacheKey] else { return nil }
        if let target = floorLevel, map.floorLevel != target {
            return nil
        }
        guard let destinations = map.destinations, !destinations.isEmpty else { return nil }

        var best: (name: String, x: Double, y: Double, distance: Double)?
        for dest in destinations {
            guard let dx = dest.x, let dy = dest.y else { continue }
            let nameCandidate: String? = {
                if let n = dest.name, !n.isEmpty { return n }
                if let l = dest.label, !l.isEmpty { return l }
                return nil
            }()
            guard let displayName = nameCandidate else { continue }
            if excludingTransitions && Self.isTransitionDestination(dest) { continue }
            let ddx = dx - px
            let ddy = dy - py
            let d = sqrt(ddx * ddx + ddy * ddy)
            if d > maxDistance { continue }
            if best == nil || d < best!.distance {
                best = (displayName, dx, dy, d)
            }
        }
        return best
    }

    /// 계단/엘리베이터/리프트 등 transition 성 destination 판정.
    /// - category 우선 (STAIRS/STAIR/ELEVATOR/LIFT 포함).
    /// - category 빈 경우 name/label 키워드(계단/엘리베이터/Stair/Elevator/EV) 로 fallback.
    private static func isTransitionDestination(_ dest: FloorMapDestination) -> Bool {
        if let category = dest.category, !category.isEmpty {
            let upper = category.uppercased()
            if upper.contains("STAIR") || upper.contains("ELEVATOR") || upper.contains("LIFT") {
                return true
            }
            return false
        }
        let label = (dest.name?.isEmpty == false ? dest.name : dest.label) ?? ""
        if label.isEmpty { return false }
        let upper = label.uppercased()
        if label.contains("계단") || label.contains("엘리베이터") { return true }
        if upper.contains("STAIR") || upper.contains("ELEVATOR") || upper.contains("EV") { return true }
        return false
    }

    /// 계단/엘리베이터 step 의 노드 이름을 connectors/destinations 에서 lookup.
    /// 1순위: step.nodeId 와 일치하는 connector.name
    /// 2순위: step.position 과 connector.x/y 거리 ≤ 1.0m 인 최근접 connector.name
    /// 3순위: destinations 중 transition 성 항목 nodeId/좌표 매칭
    /// 실패 → nil.
    private func findTransitionName(forStep step: PathStep, floorLevel: Int?) -> String? {
        let resolvedFloorId = localizedFloorId ?? floorId
        let resolvedAreaId = localizedAreaId ?? ""
        let cacheKey = "\(resolvedFloorId)#\(resolvedAreaId)"
        guard let map = floorMapCache[cacheKey] else { return nil }
        if let target = floorLevel, map.floorLevel != target {
            return nil
        }

        // 1순위: connector.routeNodeId == step.nodeId
        if let connectors = map.connectors, let nodeId = step.nodeId, !nodeId.isEmpty {
            if let match = connectors.first(where: { ($0.routeNodeId ?? "") == nodeId }) {
                if let n = match.name, !n.isEmpty { return n }
            }
        }

        // 2순위: connector 좌표 거리 ≤ 1.0m
        if let connectors = map.connectors,
           let sx = step.position?.x, let sy = step.position?.y {
            var best: (name: String, distance: Double)?
            for c in connectors {
                guard let cx = c.x, let cy = c.y else { continue }
                guard let n = c.name, !n.isEmpty else { continue }
                let dx = cx - sx
                let dy = cy - sy
                let d = sqrt(dx * dx + dy * dy)
                if d > 1.0 { continue }
                if best == nil || d < best!.distance {
                    best = (n, d)
                }
            }
            if let b = best { return b.name }
        }

        // 3순위: destinations 중 transition 성 → nodeId / 좌표 매칭
        if let destinations = map.destinations {
            // nodeId 매칭 (PathStep.nodeId 와 dest.routeNodeId)
            if let nodeId = step.nodeId, !nodeId.isEmpty {
                if let match = destinations.first(where: {
                    Self.isTransitionDestination($0) && ($0.routeNodeId ?? "") == nodeId
                }) {
                    if let n = match.name, !n.isEmpty { return n }
                    if let l = match.label, !l.isEmpty { return l }
                }
            }
            // 좌표 매칭 (≤ 1.0m)
            if let sx = step.position?.x, let sy = step.position?.y {
                var best: (name: String, distance: Double)?
                for d in destinations where Self.isTransitionDestination(d) {
                    guard let dx = d.x, let dy = d.y else { continue }
                    let nameCandidate: String? = {
                        if let n = d.name, !n.isEmpty { return n }
                        if let l = d.label, !l.isEmpty { return l }
                        return nil
                    }()
                    guard let n = nameCandidate else { continue }
                    let ex = dx - sx
                    let ey = dy - sy
                    let dist = sqrt(ex * ex + ey * ey)
                    if dist > 1.0 { continue }
                    if best == nil || dist < best!.distance {
                        best = (n, dist)
                    }
                }
                if let b = best { return b.name }
            }
        }

        return nil
    }

    /// turn step 진행 방향 기준 POI 의 위치 관계 판정.
    /// - T = step.position, P = previousStep.position (nil 이면 localizedPose 폴백, 둘 다 nil → .before)
    /// - d = T - P, q = POI - P
    /// - |d|^2 ≤ 0.01 또는 |d| ≤ 2.0 → .before 단일화
    /// - t = (q·d) / |d|^2: t < 0.7 → .past, ≥ 0.7 → .before
    private func relation(
        step: PathStep,
        previousStep: PathStep?,
        poiX: Double,
        poiY: Double
    ) -> POIRelation {
        guard let tx = step.position?.x, let ty = step.position?.y else { return .before }

        let prevXY: (Double, Double)? = {
            if let px = previousStep?.position?.x, let py = previousStep?.position?.y {
                return (px, py)
            }
            if let pose = localizedPose, let px = pose.x, let py = pose.y {
                return (px, py)
            }
            return nil
        }()
        guard let (px, py) = prevXY else { return .before }

        let dx = tx - px
        let dy = ty - py
        let dLenSq = dx * dx + dy * dy
        if dLenSq <= 0.01 { return .before }
        let dLen = sqrt(dLenSq)
        if dLen <= 2.0 { return .before }

        let qx = poiX - px
        let qy = poiY - py
        let s = (qx * dx + qy * dy) / dLen
        let t = s / dLen
        if t < 0.7 { return .past }
        return .before
    }

    // MARK: - AR 경로 렌더링 (PathChevron 시스템 — drawPathFromSteps 가 직접 PathChevronController 호출)

    /// ViewController.viewWillDisappear 에서 호출 — 안전한 no-op.
    func stopPathProgressTracking() {
        // 본 함수는 호환성 위해 유지. body 는 빈 상태.
    }

    // MARK: - 층 이동 인터렉션

    /// pendingRawSteps 에서 cur step 다음 step 의 floorLevel 을 찾는다. nodeId 우선 매칭, 좌표 1m 폴백.
    /// prefix 끝의 transition step 이라 nxt 가 nil 일 때 호출. raw 가 비어있거나 매칭 실패면 nil.
    private func lookupNextFloorFromRaw(after cur: PathStep) -> Int? {
        guard !pendingRawSteps.isEmpty else { return nil }
        // nodeId 매칭
        if let nodeId = cur.nodeId,
           let idx = pendingRawSteps.firstIndex(where: { $0.nodeId == nodeId }),
           idx + 1 < pendingRawSteps.count {
            return pendingRawSteps[idx + 1].floorLevel
        }
        // 좌표 1m 폴백
        if let cx = cur.position?.x, let cy = cur.position?.y {
            for (idx, s) in pendingRawSteps.enumerated() {
                if let sx = s.position?.x, let sy = s.position?.y {
                    let dx = sx - cx, dy = sy - cy
                    if sqrt(dx * dx + dy * dy) < 1.0,
                       idx + 1 < pendingRawSteps.count {
                        return pendingRawSteps[idx + 1].floorLevel
                    }
                }
            }
        }
        return nil
    }

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
        // "STAIRCASE:A" 형태도 매칭 (서버 instruction 의 노드명 변형).
        let stairsKeywords = ["TAKE_STAIRS", "STAIRCASE", "STAIRS", "계단", "ST-"]
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

        // targetFloor: nxt 있으면 nxt 의 floor. 없으면(prefix 끝이 transition step) raw 응답에서
        // 동일 nodeId 또는 좌표 매칭으로 다음 step floor 찾기 — 그래야 "현재 층" 이 잘못 노출되지 않음.
        // raw 도 못 찾으면 마지막 fallback 으로 cur.floorLevel.
        let nxtFloor: Int? = nxt?.floorLevel ?? lookupNextFloorFromRaw(after: cur) ?? cur.floorLevel
        return (type, nxtFloor)
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
        lastFloorTransitionTriggerAt = CACurrentMediaTime()

        // 잔여 steps 추출. prefix 끝(예: keyframe prefix drop 으로 transition step 이 마지막)에
        // transition step 이 있는 경우 remaining 이 비어있을 수 있으나, 이는 도착이 아닌 정상 층 이동.
        // restartFromFloorTransition 의 새 측위 + pathfinding 이 새 prefix 를 채워주므로 폴백 불필요.
        // remaining.isEmpty 폴백을 두면 매 1Hz tick 마다 showArrivalNotification() 이 반복 호출돼 깜빡임 발생.
        let remaining: [PathStep]
        if currentStepIdx + 1 < lastPathSteps.count {
            remaining = Array(lastPathSteps[(currentStepIdx + 1)...])
        } else {
            remaining = []
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
        // 잔존 모달 안전 닫기 — 층 전환 직전 사용자가 출발지 확인/RouteOverview 를 다시 열어두는 흐름은
        // 없지만, 외부 트리거(자동화/디버그) 로 띄워져 있을 경우 흐름 일관성 위해 명시적 dismiss.
        delegate?.dismissStartConfirmation()
        delegate?.dismissRouteOverview()

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
        pendingFloorTransitionRestart = true

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
            // 층 전환 후 lookup 실패한 경우엔 옛 시작층(userCurrentFloorId) hint 금지 — wrong-match 방지.
            // 차라리 nil 로 두고 서버 ANY 매칭에 위임한다.
            if pendingFloorTransitionRestart { return nil }
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
        let prevQuat = simd_quatf(ix: Float(pqx), iy: Float(pqy), iz: Float(pqz), r: Float(pqw))

        // 비교 baseline 을 stale prev 가 아니라 "ARKit motion 으로 propagate 된 prev" 로 잡는다.
        // stale prev 와 비교하면 사용자 walked distance 가 그대로 deltaTranslation 에 들어가
        // 정상 응답도 server/AR delta mismatch 또는 hard-set 으로 빠짐. propagated baseline 이면
        // delta = 순수 (drift + 측위 noise + wrong-match) 라 가드가 본래 목적대로 작동.
        // prevMatchedARPoseSnapshot 이 nil 인 경우 (첫 호출 등) propagation 생략 → prev 그대로 사용.
        let propagated: (pos: simd_float3, quat: simd_quatf) = {
            guard let prevMatchedAR = prevMatchedARPoseSnapshot else {
                return (prevTranslation, prevQuat)
            }
            return Self.propagateServerPose(
                prevPos: prevTranslation,
                prevQuat: prevQuat,
                prevMatchedAR: prevMatchedAR,
                targetMatchedAR: newMatchedARPose
            )
        }()

        // deltaTranslationM / deltaRotationDeg 는 propagated 기준 — drift+noise+wrong-match 신호만 추출.
        let dxPre = newTranslation.x - propagated.pos.x
        let dyPre = newTranslation.y - propagated.pos.y
        let dzPre = newTranslation.z - propagated.pos.z
        let deltaTranslationM = sqrt(dxPre*dxPre + dyPre*dyPre + dzPre*dzPre)
        let deltaRotationDeg = Self.rotationDeltaDegrees(from: propagated.quat, to: quat)

        guard deltaRotationDeg <= periodicRelocalizeMaxRotationDeltaDeg else {
            print(String(format: "[PeriodicV3] rotation delta %.1f° > %.1f° (propagated 기준) — 결과 무시",
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

        // server/AR delta mismatch 가드는 propagated baseline 도입으로 redundant.
        // (propagation 이 AR motion 을 이미 흡수했으므로 deltaTranslationM 자체가 server↔AR 일관성 신호)

        // T_AW_from_SW 회전 일관성 가드.
        // (matchedAR · M · T_SC.inverse) 의 회전이 이전 페어 대비 크게 흔들리면 wrong-match.
        // 실측 케이스(15:41:12): conf=0.77, match=147 이라 다른 가드 통과했지만 R 가 18° 흔들려 path 가 우측으로 밀림.
        if let prevMatchedARPoseSnapshot, let prevPose = prevLocalizedPoseSnapshot,
           let ppx = prevPose.x, let ppy = prevPose.y, let ppz = prevPose.z,
           let ppqx = prevPose.qx, let ppqy = prevPose.qy, let ppqz = prevPose.qz, let ppqw = prevPose.qw {
            let prevServerQuat = simd_quatf(ix: Float(ppqx), iy: Float(ppqy), iz: Float(ppqz), r: Float(ppqw))
            let R_prev = Self.computeARFromServerRotation(serverQuat: prevServerQuat,
                                                          serverPos: simd_float3(Float(ppx), Float(ppy), Float(ppz)),
                                                          arCameraPose: prevMatchedARPoseSnapshot)
            let R_new = Self.computeARFromServerRotation(serverQuat: quat,
                                                         serverPos: newTranslation,
                                                         arCameraPose: newMatchedARPose)
            let qPrev = simd_quatf(R_prev)
            let qNew = simd_quatf(R_new)
            let diffQuat = qNew * qPrev.inverse
            let realClamped = min(1.0, abs(diffQuat.real))
            let angleRad = 2.0 * acos(realClamped)
            let angleDeg = Float(angleRad * 180.0 / .pi)
            if angleDeg > periodicRelocalizeMaxTransformRotationDeltaDeg {
                print(String(format: "[PeriodicV3] transform rotation inconsistent — %.1f° > %.1f°. 결과 무시",
                             angleDeg, periodicRelocalizeMaxTransformRotationDeltaDeg))
                self.dumpPeriodicRelocalizeReject(
                    response: response,
                    capturedImages: capturedImages,
                    capturedPoses: capturedPoses,
                    prevLocalizedPose: prevLocalizedPoseSnapshot,
                    prevMatchedARPose: prevMatchedARPoseSnapshot,
                    reason: "transform_rotation_inconsistent"
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

        let cameraComparison = Self.makeCameraForwardComparison(
            matchedARPose: newMatchedARPose,
            currentARPose: arSession?.currentFrame?.camera.transform,
            serverPoseQuat: response.pose.rotationQuaternion
        )

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
            arCameraForwardAtCapture: cameraComparison.forwardAtCapture,
            arCameraPosCurrent: cameraComparison.posCurrent,
            arCameraForwardCurrent: cameraComparison.forwardCurrent,
            serverPoseForwardInServerWorld: cameraComparison.serverForwardInServerWorld,
            captureToCurrentARRotationDeg: cameraComparison.captureToCurrentRotDeg,
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

        // reject 케이스에서 capturedPoses 가 비면 newMatchedARPose 는 identity placeholder.
        // 그 경우 forward / rotation 비교는 무의미하므로 nil 로 넘김.
        let matchedARPoseForComparison: simd_float4x4? =
            capturedPoses.indices.contains(arPoseIndex) ? capturedPoses[arPoseIndex] : nil

        let cameraComparison = Self.makeCameraForwardComparison(
            matchedARPose: matchedARPoseForComparison,
            currentARPose: arSession?.currentFrame?.camera.transform,
            serverPoseQuat: response.pose.rotationQuaternion
        )

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
            arCameraForwardAtCapture: cameraComparison.forwardAtCapture,
            arCameraPosCurrent: cameraComparison.posCurrent,
            arCameraForwardCurrent: cameraComparison.forwardCurrent,
            serverPoseForwardInServerWorld: cameraComparison.serverForwardInServerWorld,
            captureToCurrentARRotationDeg: cameraComparison.captureToCurrentRotDeg,
            steps: self.lastPathSteps,
            transformedStepsByPrev: transformedByPrev,
            transformedStepsByNew: transformedByNew,
            transformedStepsByBlended: transformedByBlended,
            rejectReason: reason
        )
        LocalizeDebugLogger.dumpPeriodic(snapshot)
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

        // matched 시점 페어 대신 현재 카메라 시점으로 전진된 페어 사용 — chevron / destination 위치를
        // "지금" ARKit world 기준으로 anchor. matchedARPose / localizedPose 만 있을 때 (currentFrame nil)
        // 는 매칭 시점 페어 그대로 fallback.
        guard let bridge = bridgePosePair(currentFrame: arSession?.currentFrame) else { return }
        let input = CoordinateTransformer.Input(
            serverPosition: bridge.serverPos,
            serverQuaternion: bridge.serverQuat,
            arCameraPose: bridge.arCameraPose
        )
        let floorY = bridge.arCameraPose.columns.3.y - 1.7

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

        // 디버그: 서버 raw 경로(floorY 보정 X, 변환된 3D 그대로)를 점·선으로 동반 렌더.
        drawDebugRawServerPath(steps: steps, input: input)

        // 도착 감지용 destination AR 좌표 갱신. 매 drawPathFromSteps 호출마다 최신 값으로 set
        // (재측위 시에도 갱신되어 transform drift 보정 반영). 마지막 PathStep.position 기준.
        // 단, 마지막 step 이 transition (계단/엘리베이터) 인 경우 도착 판정을 일시 정지해야 한다 —
        // 그렇지 않으면 transition 근접 시 도착 모달이 층 이동 모달과 경합해 어느 한 쪽이 안 뜸.
        if let lastStep = steps.last {
            let lastAction = Self.navigationActionKind(steps: steps, at: steps.count - 1)
            let lastIsTransition = isTransitionStep(lastStep, action: lastAction)
            if lastIsTransition {
                destinationARPosition = nil
                print("[Arrival] destinationARPosition = nil (마지막 step 이 transition — 도착 판정 일시 정지)")
            } else if let p = lastStep.position,
                      let lx = p.x, let ly = p.y, let lz = p.z {
                let serverDest = simd_float3(Float(lx), Float(ly), Float(lz))
                let arDest = CoordinateTransformer.transform(serverPoint: serverDest, input: input)
                destinationARPosition = simd_float3(arDest.x, floorY, arDest.z)
                print("[Arrival] destinationARPosition = \(destinationARPosition!) (threshold=\(arrivalThreshold)m)")
            }
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
        // Marker 는 비우지 않음 — 1Hz tick 간격(최대 1초) 동안 마커가 사라지며 깜빡이는 문제 방지.
        // 다음 tick 의 makeActiveMarkerList 호출이 자연스럽게 새 목록으로 교체한다.
        // 추가: 첫 마커 즉시 발신 — 1Hz tick 공백 동안 마커 부재 회피.
        // ARMarkerController.update 의 sameKindFamily idempotent 처리로 다음 tick 중복 호출 안전.
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

    /// 디버그: 서버가 보낸 경로 step 들을 CoordinateTransformer 로 변환한 AR world 좌표 "그대로"
    /// (floorY 보정/투영 없이) 점·선으로 렌더한다. chevron 은 모든 점을 floorY 로 눌러 방향만 보이지만,
    /// 이 렌더는 서버 경로의 실제 3D 위치(높이 포함)를 보존해 localize 위치/방향 오류를 눈으로 진단한다.
    /// - 빨강 구  : 각 step 의 raw 변환 위치
    /// - 노랑 선  : step 간 연결 (진행 순서)
    /// - 초록 구  : 시작 step (경로 출발점)
    /// - 보라 구  : 마지막 step (목적지)
    private func drawDebugRawServerPath(steps: [PathStep], input: CoordinateTransformer.Input) {
        debugRawPathNode?.removeFromParentNode()
        debugRawPathNode = nil
        guard debugRawPathEnabled, let parent = debugPathParent else { return }

        let arPoints: [simd_float3] = steps.compactMap { step in
            guard let pos = step.position,
                  let x = pos.x, let y = pos.y, let z = pos.z else { return nil }
            return CoordinateTransformer.transform(
                serverPoint: simd_float3(Float(x), Float(y), Float(z)),
                input: input
            )
        }
        guard arPoints.count >= 2 else { return }

        let container = SCNNode()
        container.name = "debugRawServerPath"

        for (i, p) in arPoints.enumerated() {
            let isStart = (i == 0)
            let isEnd = (i == arPoints.count - 1)
            let sphere = SCNSphere(radius: isEnd ? 0.12 : 0.08)
            let mat = SCNMaterial()
            mat.diffuse.contents = isEnd ? UIColor.purple : (isStart ? UIColor.green : UIColor.red)
            mat.lightingModel = .constant
            mat.readsFromDepthBuffer = false
            sphere.materials = [mat]
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(p.x, p.y, p.z)
            node.renderingOrder = 20
            container.addChildNode(node)

            if i > 0 {
                let a = arPoints[i - 1]
                container.addChildNode(makeDebugLine(from: a, to: p))
            }
        }

        parent.addChildNode(container)
        debugRawPathNode = container
        print("[DebugRawPath] rendered \(arPoints.count) raw server points (no floorY projection)")
    }

    /// 두 AR world 점을 잇는 얇은 실린더 노드(노랑). depth 무시하고 항상 보이게.
    private func makeDebugLine(from a: simd_float3, to b: simd_float3) -> SCNNode {
        let d = b - a
        let len = simd_length(d)
        let cyl = SCNCylinder(radius: 0.015, height: CGFloat(len))
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.yellow
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        cyl.materials = [mat]
        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        // SCNCylinder 는 Y 축 정렬 — 선 방향으로 회전.
        let up = simd_float3(0, 1, 0)
        let dir = simd_normalize(d)
        let dot = simd_dot(up, dir)
        if abs(dot) < 0.9999 {
            let axis = simd_normalize(simd_cross(up, dir))
            let angle = acosf(max(-1, min(1, dot)))
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
        } else if dot < 0 {
            node.rotation = SCNVector4(1, 0, 0, Float.pi)
        }
        node.renderingOrder = 20
        return node
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

        let cameraComparison = Self.makeCameraForwardComparison(
            matchedARPose: arPose,
            currentARPose: arSession?.currentFrame?.camera.transform,
            serverPoseQuat: quat
        )

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
            transformedSteps: transformed,
            arCameraForwardAtCapture: cameraComparison.forwardAtCapture,
            arCameraPosCurrent: cameraComparison.posCurrent,
            arCameraForwardCurrent: cameraComparison.forwardCurrent,
            serverPoseForwardInServerWorld: cameraComparison.serverForwardInServerWorld,
            captureToCurrentARRotationDeg: cameraComparison.captureToCurrentRotDeg
        )
        LocalizeDebugLogger.dump(snapshot)
    }

    // MARK: - Phase 6 UI 모델

    /// RTAB-Map 컨벤션: server.z 는 수직, 수평 평면은 server.x, server.y. 1m 미만 segment 는 noise → straight 로 분류 (도어웨이/클러스터 필터).
    /// i 부터 양방향 walk 으로 ≥1m 떨어진 의미 있는 step 의 position 을 inbound/outbound 로 사용.
    /// 서버가 코너에 노드 클러스터 박는 케이스 대응. cross > 0 → LEFT 가정.
    /// 두 4x4 변환행렬을 `alpha` 비율로 보간. translation 은 lerp, rotation 은 slerp 후 재조립.
    /// 주기 V3 재측위에서 localizedPose 와 matchedARPose 를 같은 α 로 blend 해 변환식 정합성 유지.
    /// alpha=0 → prev 그대로, alpha=1 → new 그대로, 그 사이는 중간값.
    /// dump 비교용 카메라 forward 페어. 모두 같은 시점의 단위 벡터.
    /// - `forwardAtCapture` / `posCurrent` / `forwardCurrent` : ARKit world frame
    /// - `serverForwardInServerWorld` : server world frame (서버 q.act((1,0,0)))
    /// - `captureToCurrentRotDeg` : matchedARPose ↔ currentARPose quaternion 각도차 (°)
    private struct CameraForwardComparison {
        let forwardAtCapture: simd_float3?
        let posCurrent: simd_float3?
        let forwardCurrent: simd_float3?
        let serverForwardInServerWorld: simd_float3?
        let captureToCurrentRotDeg: Float?
    }

    /// 캡처 시점(matched) AR pose, 응답 도착 시점(current) AR pose, 서버 응답 quat 셋을 받아
    /// dump 에 들어갈 forward / pos / 회전 비교값을 일괄 계산. 입력 중 nil 인 항목은 결과도 nil.
    private static func makeCameraForwardComparison(
        matchedARPose: simd_float4x4?,
        currentARPose: simd_float4x4?,
        serverPoseQuat: simd_quatf?
    ) -> CameraForwardComparison {
        func cameraForward(_ m: simd_float4x4) -> simd_float3 {
            let f = m * simd_float4(0, 0, -1, 0)
            return simd_float3(f.x, f.y, f.z)
        }

        let fwdAtCapture = matchedARPose.map { cameraForward($0) }
        let posCurrent: simd_float3? = currentARPose.map {
            simd_float3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z)
        }
        let fwdCurrent = currentARPose.map { cameraForward($0) }
        let serverFwd = serverPoseQuat.map { $0.act(simd_float3(1, 0, 0)) }

        let captureToCurrentDeg: Float? = {
            guard let m = matchedARPose, let c = currentARPose else { return nil }
            let qM = simd_quatf(m)
            let qC = simd_quatf(c)
            let diff = qM.inverse * qC
            let w = max(-1.0, min(1.0, diff.real))
            return Float(2.0 * acos(abs(w)) * 180.0 / .pi)
        }()

        return CameraForwardComparison(
            forwardAtCapture: fwdAtCapture,
            posCurrent: posCurrent,
            forwardCurrent: fwdCurrent,
            serverForwardInServerWorld: serverFwd,
            captureToCurrentRotDeg: captureToCurrentDeg
        )
    }

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

    /// prev pose 를 newMatchedARPose 시점으로 ARKit motion 만큼 propagate.
    /// 변환식 (bridgePosePair 와 동일 conjugation):
    ///   T_AW←SW       = prevMatchedAR · M · T_SC_prev⁻¹
    ///   ΔT_AR         = targetMatchedAR · prevMatchedAR⁻¹
    ///   ΔT_SW         = T_AW←SW⁻¹ · ΔT_AR · T_AW←SW
    ///   T_SC_target   = ΔT_SW · T_SC_prev
    /// 결과는 "AR drift 가 없다면 새 capture 시점에 서버가 보고했어야 할 pose".
    /// 주기 reloc 가드 비교 baseline 으로 사용 — stale prev 와 비교하면 사용자 walked
    /// distance 가 그대로 deltaTranslation 에 섞여 가드가 의미를 잃음. propagated 와 비교해야
    /// 순수 drift/wrong-match 신호만 측정된다.
    private static func propagateServerPose(
        prevPos: simd_float3,
        prevQuat: simd_quatf,
        prevMatchedAR: simd_float4x4,
        targetMatchedAR: simd_float4x4
    ) -> (pos: simd_float3, quat: simd_quatf) {
        var T_SC_prev = simd_float4x4(prevQuat)
        T_SC_prev.columns.3 = simd_float4(prevPos.x, prevPos.y, prevPos.z, 1)

        let T_AW_from_SW = prevMatchedAR
            * CoordinateTransformer.rtabCameraToARKit
            * T_SC_prev.inverse

        let deltaAR = targetMatchedAR * prevMatchedAR.inverse
        let deltaSW = T_AW_from_SW.inverse * deltaAR * T_AW_from_SW

        let T_SC_target = deltaSW * T_SC_prev
        let pos = simd_float3(T_SC_target.columns.3.x,
                              T_SC_target.columns.3.y,
                              T_SC_target.columns.3.z)
        let R = simd_float3x3(
            simd_float3(T_SC_target.columns.0.x, T_SC_target.columns.0.y, T_SC_target.columns.0.z),
            simd_float3(T_SC_target.columns.1.x, T_SC_target.columns.1.y, T_SC_target.columns.1.z),
            simd_float3(T_SC_target.columns.2.x, T_SC_target.columns.2.y, T_SC_target.columns.2.z)
        )
        return (pos, simd_quatf(R))
    }

    /// (server pose, AR camera pose) 페어로 정의되는 server-world → ARKit-world 변환의 회전 성분만 추출.
    /// `bridgePosePair` 의 T_AW_from_SW = arCameraPose * M * T_SC.inverse 식과 동일 구조.
    /// translation 무시, rotation 만 비교 목적이라 upper3x3 만 반환.
    private static func computeARFromServerRotation(serverQuat: simd_quatf,
                                                    serverPos: simd_float3,
                                                    arCameraPose: simd_float4x4) -> simd_float3x3 {
        var T_SC = simd_float4x4(serverQuat)
        T_SC.columns.3 = simd_float4(serverPos.x, serverPos.y, serverPos.z, 1)
        let T_AW_from_SW = arCameraPose
            * CoordinateTransformer.rtabCameraToARKit
            * T_SC.inverse
        return simd_float3x3(
            simd_float3(T_AW_from_SW.columns.0.x, T_AW_from_SW.columns.0.y, T_AW_from_SW.columns.0.z),
            simd_float3(T_AW_from_SW.columns.1.x, T_AW_from_SW.columns.1.y, T_AW_from_SW.columns.1.z),
            simd_float3(T_AW_from_SW.columns.2.x, T_AW_from_SW.columns.2.y, T_AW_from_SW.columns.2.z)
        )
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

    /// step i 에서의 진입→진출 각도 (signed degrees). turn 마커 표시 가드용 raw 값.
    /// 시그니처는 navigationActionKind 와 같은 좌표 입력. 첫·마지막 step 은 nil.
    private static func navigationTurnAngleDegrees(steps: [PathStep], at i: Int) -> Double? {
        guard i > 0, i < steps.count - 1 else { return nil }
        guard let p = steps[i - 1].position, let c = steps[i].position, let n = steps[i + 1].position,
              let px = p.x, let py = p.y,
              let cx = c.x, let cy = c.y,
              let nx = n.x, let ny = n.y else { return nil }
        let ix = cx - px, iy = cy - py
        let ox = nx - cx, oy = ny - cy
        let cross = ix * oy - iy * ox
        let dot = ix * ox + iy * oy
        return atan2(cross, dot) * 180.0 / .pi
    }

    /// AR Next 마커가 turn 으로 표시할 각도 범위 (절대값, degrees). 90° 근처의 명확한 좌/우회전만 통과.
    /// 30°·60° 같은 애매한 각도는 마커 미표시 — 사용자 명시 요구.
    private static let nextTurnMarkerAngleRange: ClosedRange<Double> = 85.0...95.0

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
                        // 각도 가드 — 85~95° 명확한 회전만 turn 마커로 채택. 30°·60° 같은 애매한 회전은 skip.
                        if let angleDeg = Self.navigationTurnAngleDegrees(steps: lastPathSteps, at: i) {
                            let absA = abs(angleDeg)
                            if !Self.nextTurnMarkerAngleRange.contains(absA) {
                                continue
                            }
                        } else {
                            continue
                        }
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
        // "STAIRCASE" 도 stairs 분류 — detectFloorTransition 의 stairsKeywords 와 정합.
        let hasStairsKw = upper.contains("STAIRS") || upper.contains("STAIRCASE") || targetInstr.contains("계단") || upper.contains("ST-")
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
            // 각도 가드 — 85~95° 명확한 좌회전만 표시. 30°·60° 같은 애매한 각도는 마커 미표시.
            if let angleDeg = Self.navigationTurnAngleDegrees(steps: lastPathSteps, at: nextIdx) {
                let absA = abs(angleDeg)
                if !Self.nextTurnMarkerAngleRange.contains(absA) { return [] }
            } else {
                return []
            }
            kind = .nextTurn(direction: .left)
        case .turnRight, .turnSlightRight:
            if d > 7.0 { return [] }
            if let angleDeg = Self.navigationTurnAngleDegrees(steps: lastPathSteps, at: nextIdx) {
                let absA = abs(angleDeg)
                if !Self.nextTurnMarkerAngleRange.contains(absA) { return [] }
            } else {
                return []
            }
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
