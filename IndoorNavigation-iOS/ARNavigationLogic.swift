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
    func showFloorTransition(transitionType: String, targetFloor: Int?, currentFloor: Int?)
    func hideFloorTransition()
}

// MARK: - Logic

class ARNavigationLogic {

    // LightGlue 매처 토글 — RELEASE 에서 false 면 lightGlueMatcher lazy init skip.
    static let useLightGlueMatcher: Bool = {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "useLightGlueMatcher") != nil {
            return UserDefaults.standard.bool(forKey: "useLightGlueMatcher")
        }
        return true
        #else
        return false
        #endif
    }()

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
    private var matchedARPose: simd_float4x4?
    private var localizedPose: Pose?
    private var localizedFloorId: String?
    private var localizedFloorLevel: Int?
    private var localizedScanId: String?  // V3 응답 mapId — B4 PathfindingRequest.startScanId 인계용
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
    /// V3 측위 + lookup 후 첫 PnP 보정 1회만 적용. true 되면 이후 tick 은 prefix drop 만.
    private var hasPerformedPnPRefinement: Bool = false
    /// trial counter — 화면 더블탭으로 측위 재시작 시 +1, 로그 prefix 용.
    private var trialNumber: Int = 0

    /// LightGlue 매칭 엔진 — 토글 ON 시에만 init. mlpackage 미배치/load 실패 시 nil → fallback.
    private lazy var lightGlueMatcher: LightGlueMatcherEngine? = {
        do {
            let e = try LightGlueMatcherEngine()
            return e
        } catch {
            return nil
        }
    }()

    // MARK: - 외부 노출

    func setGuidanceDelegate(_ delegate: GuidanceDirectorDelegate) {
        guidanceDirector.delegate = delegate
    }

    /// SuperPoint extractor 인스턴스화 + warmUp. ViewController에서 viewDidLoad 끝에 호출.
    /// 기본 경로: SuperPointExtractorML (Core ML 추론). DEBUG 빌드에서 UserDefaults
    /// `useSuperPointStub` 가 true 면 stub 으로 강제 폴백. ML init 실패 시에도 stub 폴백.
    func setupSuperPointExtractor() {
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
        hasPerformedPnPRefinement = false

        // bundle 클리어
        localizationBundle = nil
        keyframeDescriptorCache = []
        networkBundleProvider = nil

        // capture 버퍼 클리어
        capturedImages = []
        capturedARPoses = []

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

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

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
        NetworkManager.shared.pathfinding(buildingId: buildingId, request: req) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    let steps = resp.toPathSteps()
                    self.lastStartSnapDistance = nil
                    print("[V3-PATH] steps=\(steps.count), totalDistance=\(resp.totalDistance)m, floorTransitions=\(resp.floorTransitions?.count ?? 0)")
                    self.drawPathFromSteps(steps)
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

        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureOneFrame()
        }
    }

    // MARK: - Phase 8 추적 측위 cadence (A 트랙)

    /// 추적 측위 시작 — V3 측위 + lookup 완료 후 호출. cadence 마다 background 측위.
    func startTracking() {
        guard Self.useLightGlueMatcher else {
            print("[Tracking] start 실패 — useLightGlueMatcher=false")
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
        let pnpAttempt = !hasPerformedPnPRefinement
        let bundleSnapshot = bundle
        print("[Tick] 시작 — candidates=\(candidatesSnapshot.count) pnpAttempt=\(pnpAttempt)")
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

            // PnP 보정 — V3 측위 quat 오차 정정. 첫 성공 시점에 한 번만 적용.
            var pnpRefinement: PoseEstimate? = nil
            if pnpAttempt {
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
            }

            DispatchQueue.main.async {
                print("[Tick] best kf=\(best.idx) matched=\(best.matched) → prefix drop")
                if let pnp = pnpRefinement {
                    self.applyPnPRefinement(pose: pnp, arPose: arPoseAtCapture)
                    self.hasPerformedPnPRefinement = true
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
        hasPerformedPnPRefinement = false
        updateCheckpointNode()
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

    /// 단일 흰색 원형 바닥 마커 갱신. 후보 마지막(목적지쪽 = 다음 keyframe) 위치에 표시.
    /// 노드 없으면 createCheckpointNode 로 생성 + scene rootNode 추가, 있으면 position 만 갱신.
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

        let camPos = arPose.columns.3
        let dx = placement.x - camPos.x, dz = placement.z - camPos.z
        let distXZ = sqrt(dx * dx + dz * dz)
        // 카메라 forward in ARKit world = -col2 (ARKit 컨벤션 -Z forward)
        let camFwd = simd_normalize(simd_float3(-arPose.columns.2.x, -arPose.columns.2.y, -arPose.columns.2.z))
        let toCp = simd_normalize(simd_float3(dx, placement.y - camPos.y, dz))
        let dot = simd_dot(camFwd, toCp)
        let angleDeg = acos(max(-1, min(1, dot))) * 180 / .pi
        print(String(format: "[Checkpoint] kf=(%.2f,%.2f,%.2f) → ar=(%.2f,%.2f,%.2f) cam→cp=%.2fm fwd∠cp=%.1f°",
                     kfPos.x, kfPos.y, kfPos.z, placement.x, placement.y, placement.z, distXZ, angleDeg))

        if let node = checkpointNode {
            node.position = SCNVector3(placement.x, placement.y, placement.z)
        } else {
            let node = createCheckpointNode(at: placement)
            scene?.rootNode.addChildNode(node)
            checkpointNode = node
        }
    }

    /// pathfinding steps[].position 들을 server world → AR world 변환 후 sphere + cylinder line 으로 시각화.
    /// V3 측위 + lookup 직후 1회 호출. 매 tick 갱신 X.
    private func drawPathFromSteps(_ steps: [PathStep]) {
        lastPathSteps = steps
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
