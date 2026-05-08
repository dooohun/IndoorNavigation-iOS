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

    // MARK: - Mock Mode (서버 미가용 시 UI 점검용)
    // FIXME: 서버 복구 후 false로 전환
    static let useMockData: Bool = false

    // V3 측위 토글. true: 첫 측위는 서버 V3 (정확) → 응답 좌표로 lookup → 추적은 클라 LightGlue.
    // false: 클라 단독 측위 (lookup 좌표 hardcode 한계 있음).
    // 사용자 의도된 정공: V3 1회 + lookup + 추적. 본 토글 true 유지.
    static let useV3Localize: Bool = true

    // V3 pathfinding 토글. 현재 useV3Localize 와 짝. legacy 분리가 필요해질 때만 false.
    // 클라 단독 측위 후에도 경로 탐색은 서버 사용 — true 유지.
    static let useV3Pathfinding: Bool = true

    // S3 — LightGlue 매처 토글. DEBUG 기본 true (클라 단독 측위 검증 모드).
    // RELEASE 빌드는 항상 false. UserDefaults 키 명시 시 그 값 우선.
    // 클라 단독 측위: useV3Localize=false + useLightGlueMatcher=true.
    static let useLightGlueMatcher: Bool = {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "useLightGlueMatcher") != nil {
            return UserDefaults.standard.bool(forKey: "useLightGlueMatcher")
        }
        return true   // DEBUG default — 클라 단독 측위 (A1 모드)
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
    /// 매 프레임 매칭 결과 누적 → window 평균 console 로그.
    private struct MatchSample {
        let bestKfIdx: Int
        let bestMatched: Int
        let bestAvgScore: Float
        let perKfMatched: [Int]
    }
    private var matchSamples: [MatchSample] = []
    private let matchLogWindow = 5
    /// cosine similarity 절대 임계 (정규화 vector 기준 0.7 = 매우 유사).
    private let matchScoreThreshold: Float = 0.7
    /// Lowe's ratio test — top-1 / top-2 가 본 값보다 커야 매칭 인정.
    /// 1.3 = best 가 second 보다 30% 이상 우월해야. false positive 강력 제거.
    private let matchRatio: Float = 1.3
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
    /// 추적 측위 주기 (초). 실측: 발열 throttled SuperPoint ~700ms + LightGlue 5kf × ~100ms ≈ 1.5s.
    /// cadence 2.0s 로 큐 쌓임 방지. TODO(A1): thermal throttle / globalDescriptor prefilter 도입 후 단축.
    private let trackingCadenceSec: TimeInterval = 2.0
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
    /// trial counter — 화면 더블탭으로 측위 재시작 시 +1, 로그 prefix 용.
    private var trialNumber: Int = 0

    /// LightGlue 매칭 엔진 — 토글 ON 시에만 init. mlpackage 미배치/load 실패 시 nil → fallback.
    private lazy var lightGlueMatcher: LightGlueMatcherEngine? = {
        do {
            let e = try LightGlueMatcherEngine()
            print("[LightGlue] engine ready")
            return e
        } catch {
            print("[LightGlue] init failed: \(error) — DescriptorMatcher fallback")
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
            print("[SuperPoint] using stub (UserDefaults override)")
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
            print("[SuperPoint] using ML extractor")
        } catch {
            print("[SuperPoint] ML init failed (\(error)) — fallback to stub")
            let stub = SuperPointExtractorStub()
            stub.warmUp()
            superPointExtractor = stub
        }

        // Phase 8 bundle 로드 — 매 프레임 매칭 진단용 mock 만 로드.
        // 추적용 NetworkBundle 은 V3 측위 응답 받은 후 (handleLocalizeV3Success 안에서) 호출 — 사용자 위치 알 때.
        // 앱 진입 시점에는 사용자 위치 모르므로 hardcode (0,0,0) 으로 lookup 하면 origin keyframe 받아 추적 무용.
        loadMockBundleFallback()
    }

    /// `MockBundleProvider` 로드 + descriptor 캐시 채움. 실패해도 throw 안 함 (매칭만 비활성).
    /// 토글 OFF 시 + NetworkBundleProvider 실패 시 모두 본 헬퍼로 폴백.
    private func loadMockBundleFallback() {
        do {
            let bundle = try MockBundleProvider().loadBundle()
            localizationBundle = bundle
            keyframeDescriptorCache = bundle.keyframes.map { kf in
                Data(base64Encoded: kf.descriptorsB64) ?? Data()
            }
            print("[MockBundle] loaded \(bundle.keyframes.count) keyframes (intrinsics \(bundle.manifest.intrinsics.width)×\(bundle.manifest.intrinsics.height))")
        } catch {
            print("[MockBundle] load failed: \(error) — 매칭 비활성")
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
                case .success(let url):
                    print("[Dumper] ok: \(url.path)")
                    debug.notifyDumpResult(success: true)
                case .failure(let err):
                    print("[Dumper] fail: \(err)")
                    debug.notifyDumpResult(success: false)
                }
            }
        }
        #endif

        matchAgainstMockBundle(result)

        #if DEBUG
        superPointDebug?.receiveFrame(result)
        #endif
    }

    /// 추출 결과를 mock bundle 의 모든 keyframe 과 cosine similarity 매칭. best keyframe
    /// 선택 후 window 평균을 console 로그로 출력 (매핑 환경 안/밖에서 매칭률 비교용).
    private func matchAgainstMockBundle(_ frame: SuperPointFrame) {
        guard let bundle = localizationBundle, !keyframeDescriptorCache.isEmpty else { return }
        guard frame.descriptors.shape.count == 2,
              frame.descriptors.shape[0].intValue > 0 else { return }

        // S3 분기 — LightGlue 토글 ON 시 매 프레임 매칭은 SKIP.
        // 사유: 5 keyframe × LightGlue 추론(~100ms) = main 스레드 ~500ms 점유로 UI/캡처 차단.
        // 매 프레임 LightGlue 매칭은 진단 로그용이었고 측위는 runClientLocalize 트리거 시점에만 수행.
        // 향후 추적 측위(매 cadence) 본격 도입 시 background 큐로 옮겨 다시 활성화 (TODO S3+).
        if Self.useLightGlueMatcher {
            return
        }

        let queryCount = frame.descriptors.shape[0].intValue

        var perKfStats: [(idx: Int, stats: DescriptorMatcher.Stats, matches: [DescriptorMatcher.Match?])] = []
        for (kfIdx, kf) in bundle.keyframes.enumerated() {
            let refBytes = keyframeDescriptorCache[kfIdx]
            let n = kf.keypoints.count
            guard n > 0, refBytes.count == n * 256 * MemoryLayout<Float16>.size else { continue }
            let matches = DescriptorMatcher.matchTop1(
                query: frame.descriptors,
                referenceBytes: refBytes,
                referenceCount: n,
                threshold: matchScoreThreshold,
                ratio: matchRatio
            )
            let stats = DescriptorMatcher.stats(matches: matches, queryCount: queryCount)
            perKfStats.append((idx: kfIdx, stats: stats, matches: matches))
        }
        guard !perKfStats.isEmpty else { return }
        let best = perKfStats.max { $0.stats.matchedCount < $1.stats.matchedCount }!
        let sample = MatchSample(
            bestKfIdx: best.idx,
            bestMatched: best.stats.matchedCount,
            bestAvgScore: best.stats.avgScore,
            perKfMatched: perKfStats.map { $0.stats.matchedCount }
        )
        recordMatchSample(sample, queryCount: queryCount)

        // mock 트랙 PnP — V3 가 메인 측위. UserDefaults("useMockPnP")=true 시에만 시도.
        // TODO(향후): superPointDebug 컨트롤러에 토글 UI 추가
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "useMockPnP") {
            attemptPnP(frame: frame, bundle: bundle, bestKfIdx: best.idx, bestMatches: best.matches)
        }
        #endif
    }

    /// best keyframe 매칭에서 valid 2D-3D 쌍을 추출 + DLTPnPSolver 호출. 결과 즉시 console 로그.
    private func attemptPnP(
        frame: SuperPointFrame,
        bundle: LocalizationBundle,
        bestKfIdx: Int,
        bestMatches: [DescriptorMatcher.Match?]
    ) {
        let bestKf = bundle.keyframes[bestKfIdx]
        let pairs = MatchedPointExtractor.extract(
            matches: bestMatches,
            queryKeypoints: frame.keypoints,
            bundleKeyframe: bestKf
        )
        guard pairs.count >= pnpMinPairs else { return }

        // 매핑 시점 카메라 intrinsics (서버 manifest). 클라가 동일 사이즈(960×540)로 SuperPoint
        // 추출했으므로 좌표계 일치한다고 가정 — 정확한 클라 K(스케일·회전 보정) 는 단계 5 에서.
        let m = bundle.manifest.intrinsics
        let K = simd_float3x3(rows: [
            SIMD3<Float>(Float(m.fx), 0, Float(m.cx)),
            SIMD3<Float>(0, Float(m.fy), Float(m.cy)),
            SIMD3<Float>(0, 0, 1),
        ])

        guard let pose = pnpSolver.solve(
            objectPoints: pairs.map { $0.worldPoint },
            imagePoints: pairs.map { $0.imagePoint },
            intrinsics: K
        ) else {
            print("[Pose] kf=\(bestKfIdx) pairs=\(pairs.count) — PnP solve 실패")
            return
        }

        let t = pose.translation
        // R 의 yaw 추정 (대략): atan2(R[2,0], R[0,0]) — debugging 용.
        let yawDeg = atan2(pose.rotation[2, 0], pose.rotation[0, 0]) * 180.0 / .pi
        print(String(
            format: "[Pose] kf=%d pairs=%d reproj=%.1fpx t=(%.2f, %.2f, %.2f) yaw=%.0f°",
            bestKfIdx, pairs.count, pose.reprojectionError,
            t.x, t.y, t.z, yawDeg
        ))
    }

    // MARK: - S3 LightGlue 매칭 + 클라 단독 측위

    /// LightGlue 엔진으로 모든 keyframe 매칭 → best 선정 + window 평균 console 로그.
    /// DescriptorMatcher 경로(matchAgainstMockBundle)와 1:1 미러. PnP 는 본 메서드에서 호출하지 않는다
    /// — 매 프레임 700ms 추론은 비현실적이므로 측위 트리거는 캡처 시점(runClientLocalize) 1회만.
    private func matchAgainstMockBundleLightGlue(
        _ frame: SuperPointFrame,
        bundle: LocalizationBundle,
        engine: LightGlueMatcherEngine
    ) {
        let queryCount = frame.keypoints.count
        guard queryCount > 0 else { return }

        var perKfStats: [(idx: Int, matched: Int, avgScore: Float)] = []
        for (kfIdx, kf) in bundle.keyframes.enumerated() {
            guard !kf.keypoints.isEmpty else { continue }
            guard let matches = try? engine.match(
                query: frame,
                targetKeyframe: kf,
                targetIntrinsics: bundle.manifest.intrinsics
            ) else { continue }
            let matched = matches.count
            let avg: Float = matched > 0 ? matches.reduce(0.0) { $0 + $1.score } / Float(matched) : 0
            perKfStats.append((idx: kfIdx, matched: matched, avgScore: avg))
        }
        guard !perKfStats.isEmpty else { return }
        let best = perKfStats.max { $0.matched < $1.matched }!
        let sample = MatchSample(
            bestKfIdx: best.idx,
            bestMatched: best.matched,
            bestAvgScore: best.avgScore,
            perKfMatched: perKfStats.map { $0.matched }
        )
        recordMatchSampleLightGlue(sample, queryCount: queryCount)
    }

    /// LightGlue 매칭 결과 + best keyframe → MatchedPointPair 추출 → RANSAC PnP 풀이.
    /// 성공 시 (pose, kfIdx) 반환, 실패 시 nil. attemptPnP 패턴 복제 (반환형만 (PoseEstimate, Int)? 로 변경).
    /// TODO(S3): PnP reprojectionError 임계 게이팅 — 실측 후 임계 확정.
    private func attemptPnPLightGlue(
        frame: SuperPointFrame,
        bundle: LocalizationBundle,
        bestKfIdx: Int,
        lightGlueMatches: [LightGlueMatcherEngine.Match]
    ) -> (pose: PoseEstimate, kfIdx: Int)? {
        let bestKf = bundle.keyframes[bestKfIdx]
        // 단계별 진단: raw matches → NaN/bounds filter → final pairs
        let rawCount = lightGlueMatches.count
        let kfWorld3dValid = bestKf.world3d.compactMap { $0 }.count
        let pairs = MatchedPointExtractor.extract(
            lightGlueMatches: lightGlueMatches,
            queryKeypoints: frame.keypoints,
            bundleKeyframe: bestKf
        )
        print("[LightGlue][진단] kf=\(bestKfIdx) raw_matches=\(rawCount), kf_world3d_valid=\(kfWorld3dValid)/\(bestKf.world3d.count), final_pairs=\(pairs.count)")
        guard pairs.count >= pnpMinPairs else {
            print("[LightGlue][PnP] kf=\(bestKfIdx) pairs=\(pairs.count) < min=\(pnpMinPairs) — skip")
            return nil
        }

        // 매핑 시점 카메라 intrinsics (서버 manifest). attemptPnP 동일 패턴.
        let m = bundle.manifest.intrinsics
        let K = simd_float3x3(rows: [
            SIMD3<Float>(Float(m.fx), 0, Float(m.cx)),
            SIMD3<Float>(0, Float(m.fy), Float(m.cy)),
            SIMD3<Float>(0, 0, 1),
        ])

        guard let pose = pnpSolver.solve(
            objectPoints: pairs.map { $0.worldPoint },
            imagePoints: pairs.map { $0.imagePoint },
            intrinsics: K
        ) else {
            print("[LightGlue][PnP] kf=\(bestKfIdx) pairs=\(pairs.count) — PnP solve 실패")
            return nil
        }

        let t = pose.translation
        let yawDeg = atan2(pose.rotation[2, 0], pose.rotation[0, 0]) * 180.0 / .pi
        print(String(
            format: "[LightGlue][PnP] kf=%d pairs=%d reproj=%.1fpx t=(%.2f, %.2f, %.2f) yaw=%.0f°",
            bestKfIdx, pairs.count, pose.reprojectionError,
            t.x, t.y, t.z, yawDeg
        ))
        // reprojection error 임계 게이팅 — 30px 초과 시 측위 fail 처리.
        // 정상 측위 reproj 1~10px. 30+ 면 좌표계 정합 X (mock_bundle stale 또는 다른 매핑 영역).
        if pose.reprojectionError > 30 {
            print("[LightGlue][PnP] kf=\(bestKfIdx) reproj=\(String(format: "%.1f", pose.reprojectionError))px > 30 — 측위 신뢰도 부족, fail 처리")
            return nil
        }
        return (pose, bestKfIdx)
    }

    /// LightGlue 매칭 window 평균 로그 (recordMatchSample 동일 흐름, 로그 prefix 만 분리).
    private func recordMatchSampleLightGlue(_ sample: MatchSample, queryCount: Int) {
        matchSamples.append(sample)
        guard matchSamples.count >= matchLogWindow else { return }
        let n = matchSamples.count
        let avgBestMatched = matchSamples.reduce(0) { $0 + $1.bestMatched } / n
        let avgBestScore = matchSamples.reduce(0.0) { $0 + Double($1.bestAvgScore) } / Double(n)
        let kfFreq = Dictionary(grouping: matchSamples, by: { $0.bestKfIdx }).mapValues { $0.count }
        let mostBestKf = kfFreq.max { $0.value < $1.value }?.key ?? -1
        let perKfCount = matchSamples.first?.perKfMatched.count ?? 0
        var perKfAvg: [Int] = []
        for i in 0..<perKfCount {
            let s = matchSamples.reduce(0) { $0 + $1.perKfMatched[i] }
            perKfAvg.append(s / n)
        }
        print(String(
            format: "[LightGlue][avg×%d] best_kf=%d matched=%d/%d score=%.2f per_kf=%@",
            n, mostBestKf, avgBestMatched, queryCount, avgBestScore, perKfAvg.description
        ))
        matchSamples.removeAll(keepingCapacity: true)
    }

    private func recordMatchSample(_ sample: MatchSample, queryCount: Int) {
        matchSamples.append(sample)
        guard matchSamples.count >= matchLogWindow else { return }
        // window 평균
        let n = matchSamples.count
        let avgBestMatched = matchSamples.reduce(0) { $0 + $1.bestMatched } / n
        let avgBestScore = matchSamples.reduce(0.0) { $0 + Double($1.bestAvgScore) } / Double(n)
        let kfFreq = Dictionary(grouping: matchSamples, by: { $0.bestKfIdx }).mapValues { $0.count }
        let mostBestKf = kfFreq.max { $0.value < $1.value }?.key ?? -1
        let perKfCount = matchSamples.first?.perKfMatched.count ?? 0
        var perKfAvg: [Int] = []
        for i in 0..<perKfCount {
            let s = matchSamples.reduce(0) { $0 + $1.perKfMatched[i] }
            perKfAvg.append(s / n)
        }
        print(String(
            format: "[Match][avg×%d] best_kf=%d matched=%d/%d score=%.2f per_kf=%@",
            n, mostBestKf, avgBestMatched, queryCount, avgBestScore, perKfAvg.description
        ))
        matchSamples.removeAll(keepingCapacity: true)
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

        // bundle 클리어
        localizationBundle = nil
        keyframeDescriptorCache = []
        networkBundleProvider = nil

        // capture 버퍼 클리어
        capturedImages = []
        capturedARPoses = []

        // GuidanceDirector 도 reset (Phase 5 dead path 지만 호출 부수효과 없게)
        guidanceDirector.reset()

        // mock bundle fallback 재로드 — 추적용 NetworkBundle 은 V3 응답 후 갱신.
        loadMockBundleFallback()
    }

    func startLocalizationFlow() {
        if Self.useMockData {
            runMockFlow()
            return
        }

        guard arSession?.currentFrame != nil else {
            delegate?.updateStatus("AR 세션이 준비되지 않았습니다. 잠시 후 다시 시도하세요.", color: .systemYellow)
            return
        }

        trialNumber += 1
        print("[Trial #\(trialNumber)] startLocalizationFlow")
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
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        let bakedImage = bakeOrientation(uiImage)

        capturedImages.append(bakedImage)
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
        if Self.useV3Localize {
            sendToServerV3()
        } else if Self.useLightGlueMatcher {
            // S3 — 클라 단독 측위. 서버 호출 없이 LightGlue + RANSAC PnP 로 self-localize.
            runClientLocalize()
        } else {
            sendToServerLegacy()
        }
    }

    /// 기존 SLAMv3(/api/slam/v3/localize) 흐름. useV3Localize=false 폴백 경로.
    private func sendToServerLegacy() {
        guard !capturedImages.isEmpty else {
            delegate?.setLoading(false)
            delegate?.setScanningOverlay(visible: false)
            delegate?.showScanFailed(message: "촬영에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        NetworkManager.shared.localize(buildingId: buildingId, mapId: nil, images: capturedImages) { [weak self] result in
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

    /// V3 측위 흐름 — multipart 업로드 + LocalizeV3Response 핸들링.
    private func sendToServerV3() {
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

    /// S3 — 클라 단독 측위 (서버 호출 없이 LightGlue + RANSAC PnP 로 self-localize).
    /// 캡처된 5장 중 1장(현재 ARFrame) 만 사용. 매칭 + PnP 성공 시 handleClientLocalizeSuccess 로 후속 흐름.
    /// TODO(S3): 5장 캡처 중 1장만 사용 — 5장 평균 또는 inlier 최대 선택 향후 개선
    /// TODO(S3): best keyframe 선택 — globalDescriptor cosine prefilter (NetworkBundle 100+ keyframe 시 필수)
    private func runClientLocalize() {
        guard !capturedImages.isEmpty else {
            delegate?.setLoading(false)
            delegate?.setScanningOverlay(visible: false)
            delegate?.showScanFailed(message: "캡처된 이미지가 없어요.\n다시 시도해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        delegate?.setScanningOverlay(visible: false)

        guard let frame = arSession?.currentFrame,
              let extractor = superPointExtractor else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "AR 세션이 준비되지 않았어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        guard let bundle = localizationBundle, !bundle.keyframes.isEmpty else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "매핑 데이터가 준비되지 않았어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        guard let engine = lightGlueMatcher else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "매처가 준비되지 않았어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // 1. 현재 ARFrame 으로 SuperPoint 추출 (processARFrame 패턴 동일)
        let deviceIsLandscape = UIDevice.current.orientation.isLandscape
        let orientation: InputOrientation = deviceIsLandscape ? .landscape : .portrait
        let queryFrame = extractor.extract(
            image: frame.capturedImage,
            intrinsics: frame.camera.intrinsics,
            timestamp: frame.timestamp,
            orientation: orientation
        )

        // 2. 모든 keyframe 매칭 → best (matched count max)
        let queryKpCount = queryFrame.keypoints.count
        let queryDescShape = queryFrame.descriptors.shape
        let querySize = queryFrame.inputSize
        print("[LightGlue][입력] query kp=\(queryKpCount), desc shape=\(queryDescShape), size=\(querySize), bundle_intr=(\(bundle.manifest.intrinsics.width)×\(bundle.manifest.intrinsics.height))")
        var perKfMatches: [(idx: Int, matches: [LightGlueMatcherEngine.Match])] = []
        for (kfIdx, kf) in bundle.keyframes.enumerated() {
            guard !kf.keypoints.isEmpty else { continue }
            let validW3d = kf.world3d.compactMap { $0 }.count
            guard validW3d > 0 else {
                print("[LightGlue][매칭] kf=\(kfIdx) world3d 전부 NaN — skip")
                continue
            }
            do {
                let m = try engine.match(
                    query: queryFrame,
                    targetKeyframe: kf,
                    targetIntrinsics: bundle.manifest.intrinsics
                )
                print("[LightGlue][매칭] kf=\(kfIdx) (kp=\(kf.keypoints.count), valid_w3d=\(validW3d)) → matches=\(m.count)")
                perKfMatches.append((idx: kfIdx, matches: m))
            } catch {
                print("[LightGlue][매칭] kf=\(kfIdx) → ERROR: \(error)")
                continue
            }
        }
        guard let best = perKfMatches.max(by: { $0.matches.count < $1.matches.count }),
              !best.matches.isEmpty else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "주변 환경을 인식하지 못했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // 3. PnP 풀이
        guard let pnp = attemptPnPLightGlue(
            frame: queryFrame,
            bundle: bundle,
            bestKfIdx: best.idx,
            lightGlueMatches: best.matches
        ) else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // 4. PoseEstimate → Pose (Codable) 어댑터.
        // TODO(S3): Pose 회전 어댑터 — RansacPnPSolver pose.rotation 좌표계 방향
        //          (camera→world vs world→camera) 확인. V3 와 동일 가정.
        let t = pnp.pose.translation
        let q = simd_quatf(pnp.pose.rotation)
        let pose = Pose(
            x: Double(t.x), y: Double(t.y), z: Double(t.z),
            qx: Double(q.imag.x), qy: Double(q.imag.y), qz: Double(q.imag.z), qw: Double(q.real)
        )

        // TODO(S3): floorId/floorLevel 결정 — bundle.manifest 의존, 매핑 시점과 다른 층 측위 시 부정확
        let floorLevel = bundle.manifest.floorLevel
        let scanId = bundle.manifest.scanId

        handleClientLocalizeSuccess(pose: pose, scanId: scanId, floorLevel: floorLevel)
    }

    private func handleLocalizeSuccess(response: SLAMLocalizeResponse) {
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
        localizedFloorId = response.floorId
        localizedFloorLevel = response.floorLevel

        delegate?.showScanComplete()

        if isFloorTransitionRestart {
            // 잔여 경로 재렌더링 (서버 pathfinding 호출 생략)
            // TODO(Phase 3): Phase 8 keyframe 단계 추적 모델에서 층 전환 잔여 경로 재시작 미지원.
            //                drawPathNodes 폐기 — legacy dead path.
            delegate?.showRouteCalculating(false)
            delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
            pendingRemainingSteps = []
            isFloorTransitionRestart = false
            delegate?.setLoading(false)
        } else {
            delegate?.showRouteCalculating(true)
            let activeFloorId = response.floorId ?? self.floorId
            startCoordinateRoute(pose: pose, floorId: activeFloorId)
        }
    }

    /// V3 측위 응답 핸들러 — handleLocalizeSuccess 와 같은 후속 흐름(showScanComplete + 층 전환 분기 + startCoordinateRoute) 사용.
    /// 응답 형식이 다르므로 별도 메서드로 분리.
    private func handleLocalizeV3Success(response: LocalizeV3Response) {
        // TODO(서버답): confidence 임계값 미정 → 0.3 잠정
        guard response.confidence >= 0.3 else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식 신뢰도가 낮아요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // TODO(서버답): pose 변환 방향 — camera→world 가정 (SLAMv3와 동일)
        guard let _ = response.pose.toMatrix4x4(),
              let translation = response.pose.translation,
              let quat = response.pose.rotationQuaternion else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // 서버 LocalizeResponse 에 matchedImageIndex 없음 — 캡처 마지막 프레임으로 fallback (가장 최근 ARKit pose).
        guard let lastARPose = capturedARPoses.last else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }
        matchedARPose = lastARPose

        let pose = Pose(
            x: Double(translation.x), y: Double(translation.y), z: Double(translation.z),
            qx: Double(quat.imag.x), qy: Double(quat.imag.y), qz: Double(quat.imag.z), qw: Double(quat.real)
        )
        localizedPose = pose
        // 서버 LocalizeResponse 본체에 floorId/floorLevel 없음 — pose object 안에 있을 수도(자유 schema). 없으면 self.floorId fallback.
        localizedFloorId = response.pose.floorId ?? self.floorId
        localizedFloorLevel = response.pose.floorLevel
        localizedScanId = response.mapId  // B4 인계: PathfindingRequest.startScanId (Optional)

        // 추적용 lookup 은 pathfinding 응답 받은 후 — steps 좌표 multi-query 로 경로 전체 keyframe 받음.
        // pathfinding 호출은 startV3Pathfinding 에서 (아래 분기). 응답 분기에서 lookup 트리거.

        delegate?.showScanComplete()

        if isFloorTransitionRestart {
            // 잔여 경로 재렌더링 (서버 pathfinding 호출 생략)
            // TODO(Phase 3): Phase 8 keyframe 단계 추적 모델에서 층 전환 잔여 경로 재시작 미지원.
            //                drawPathNodes 폐기 — 추후 trackingKeyframeCandidates 재구성 흐름으로 대체.
            delegate?.showRouteCalculating(false)
            delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
            pendingRemainingSteps = []
            isFloorTransitionRestart = false
            delegate?.setLoading(false)
        } else {
            // 직선 안내 폐기 — Phase 8 keyframe 단계 추적 모델 (checkpoint 1개 + tick drop) 로 대체.
            delegate?.showRouteCalculating(false)
            delegate?.setLoading(false)
            delegate?.updateStatus("\(destinationName) 방향으로 이동하세요.", color: .white)
            delegate?.setHUDVisible(true)
            if Self.useLightGlueMatcher {
                startV3Pathfinding(scanId: response.mapId,
                                   startFloorLevel: response.pose.floorLevel,
                                   translation: translation)
            }
        }
    }

    /// S3 — 클라 단독 측위 성공 핸들러. handleLocalizeV3Success 와 동일 후속 흐름
    /// (showScanComplete + 층 전환 분기 + V3 또는 좌표 경로). pose 변환은 runClientLocalize 에서 완료.
    private func handleClientLocalizeSuccess(pose: Pose, scanId: String?, floorLevel: Int?) {
        guard let lastARPose = capturedARPoses.last else {
            delegate?.setLoading(false)
            delegate?.showScanFailed(message: "위치 인식에 실패했어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }
        matchedARPose = lastARPose

        localizedPose = pose
        localizedFloorId = self.localizationBundle?.manifest.floorId ?? self.floorId
        localizedFloorLevel = floorLevel ?? self.localizationBundle?.manifest.floorLevel
        localizedScanId = scanId

        delegate?.showScanComplete()

        if isFloorTransitionRestart {
            // 잔여 경로 재렌더링 (서버 pathfinding 호출 생략)
            // TODO(Phase 3): Phase 8 keyframe 단계 추적 모델에서 층 전환 잔여 경로 재시작 미지원.
            //                drawPathNodes 폐기 — dead path.
            delegate?.showRouteCalculating(false)
            delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
            pendingRemainingSteps = []
            isFloorTransitionRestart = false
            delegate?.setLoading(false)
        } else {
            delegate?.showRouteCalculating(true)
            let activeFloorId = self.localizationBundle?.manifest.floorId ?? self.floorId
            _ = activeFloorId  // legacy dead path 의 startCoordinateRoute 인자였음 (TODO 박제)
            if Self.useV3Pathfinding {
                let translation = simd_float3(
                    Float(pose.x ?? 0),
                    Float(pose.y ?? 0),
                    Float(pose.z ?? 0)
                )
                startV3Pathfinding(scanId: scanId,
                                   startFloorLevel: floorLevel,
                                   translation: translation)
            } else {
                // legacy 클라 단독 측위 폴백 — Phase 8 추적 모델에선 dead path.
                // TODO(S3+): useV3Pathfinding=false 분기 자체 폐기 검토.
            }
        }
    }

    // MARK: - 경로 탐색

    private func startCoordinateRoute(pose: Pose, floorId: String) {
        // TODO(Phase 8): legacy 좌표 기반 경로 탐색 — Phase 8 keyframe 단계 추적 모델에서 dead path.
        //                drawPathNodes 폐기로 본 함수 호출 결과 활용처 없음.
        //                handleLocalizeSuccess (legacy SLAMv3) 분기에서만 호출되므로 useV3Localize=true 시 도달 불가.
        //                NetworkManager.shared.findRouteByCoordinates 등 함수 본체는 보존 (재활용 가능).
        _ = pose
        _ = floorId
        delegate?.setLoading(false)
        delegate?.showRouteCalculating(false)
    }

    private func adaptRouteResponseToSteps(response: FloorCoordinateRouteResponse) -> [PathStep] {
        guard let coords = response.pathGeometry?.coordinates else { return [] }
        let level = self.localizedFloorLevel
        return coords.enumerated().compactMap { (idx, c) in
            guard c.count >= 2 else { return nil }
            let x = c[0]
            let y = c[1]
            let z = c.count >= 3 ? c[2] : 0.0
            return PathStep(
                stepNumber: idx,
                floorLevel: level,
                position: Position(x: x, y: y, z: z),
                instruction: nil
            )
        }
    }

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
            startScanId: scanId,
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
                    print("[V3-PATH] steps=\(steps.count), totalDistance=\(resp.totalDistance)m, floorTransitions=\(resp.floorTransitions.count)")
                    // 데이터용 — drawPathNodes 호출 X (직선 안내는 handleLocalizeV3Success 에서 이미 표시).
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
                self.setupTrackingCandidates(bundle: bundle)
                self.startTracking()
            case .failure(let error):
                print("[NetworkBundle] fetch failed: \(error) — 추적 미시작, ARKit pose 만")
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
        destinationPinNode = nil
        allSteps = []
        allARPoints = []
        smoothedPoints = []
        simplifiedPointCount = 0
        currentTargetWaypointIndex = 0
        matchedARPose = nil
        localizedPose = nil
        destinationARPosition = nil

        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
        arrivalCheckTimer?.invalidate()
        arrivalCheckTimer = nil
        hasNotifiedArrival = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        isTrackingTickInFlight = false

        delegate?.setLocateButtonVisible(false)
        delegate?.setScanningOverlay(visible: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.delegate?.setScanningOverlay(visible: false)
            self.delegate?.showScanComplete()

            if self.isFloorTransitionRestart {
                // 재스캔 모드: 잔여 경로 직접 사용 (경로 계산 카드 표시 생략)
                // TODO(Phase 8): mock 흐름에서 drawPathNodes 폐기 — keyframe 단계 추적 모델 미지원.
                self.delegate?.showRouteCalculating(false)
                self.matchedARPose = frame.camera.transform
                self.localizedPose = self.makeMockPose()
                self.delegate?.setLoading(false)
                self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                self.pendingRemainingSteps = []
                self.isFloorTransitionRestart = false
                return
            }

            self.delegate?.showRouteCalculating(true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.delegate?.showRouteCalculating(false)

                self.matchedARPose = frame.camera.transform
                self.localizedPose = self.makeMockPose()
                self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                // TODO(Phase 8): mock drawPathNodes(self.makeMockSteps()) 폐기 — keyframe 단계 추적 모델로 대체 예정.
                _ = self.makeMockSteps()
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

        if Self.useMockData {
            runMockFlow()
            return
        }

        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureOneFrame()
        }
    }

    // MARK: - Phase 8 추적 측위 cadence (A 트랙)

    /// 추적 측위 시작 — V3 측위 + lookup 완료 후 호출. cadence 마다 background 측위.
    func startTracking() {
        guard Self.useLightGlueMatcher else {
            print("[Tracking] useLightGlueMatcher OFF — 추적 미시작")
            return
        }
        guard let bundle = localizationBundle, !bundle.keyframes.isEmpty else {
            print("[Tracking] localizationBundle 없음 — 추적 미시작")
            return
        }
        guard lightGlueMatcher != nil else {
            print("[Tracking] LightGlueMatcher 없음 — 추적 미시작")
            return
        }
        guard superPointExtractor != nil else {
            print("[Tracking] SuperPointExtractor 없음 — 추적 미시작")
            return
        }
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: trackingCadenceSec, repeats: true) { [weak self] _ in
            self?.runTrackingTick()
        }
        print("[Tracking] 추적 측위 시작 — cadence \(trackingCadenceSec)s, keyframes=\(bundle.keyframes.count)")
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        print("[Tracking] 추적 측위 중지")
    }

    private func runTrackingTick() {
        guard !isTrackingTickInFlight else {
            print("[Tracking] 직전 tick 미완료 — skip")
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
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            let queryFrame = extractor.extract(
                image: pixelBuffer,
                intrinsics: intrinsics,
                timestamp: timestamp,
                orientation: orientation
            )
            // 모든 후보 keyframe 매칭 — matched count 만 산출. PnP 풀지 않음.
            let perKfMatches: [(idx: Int, matched: Int)] = candidatesSnapshot.enumerated().compactMap { (idx, kf) in
                guard !kf.keypoints.isEmpty else { return nil }
                guard let m = try? engine.match(
                    query: queryFrame,
                    targetKeyframe: kf,
                    targetIntrinsics: intrinsicsSnapshot
                ) else { return nil }
                return (idx, m.count)
            }
            guard let best = perKfMatches.max(by: { $0.matched < $1.matched }) else {
                DispatchQueue.main.async {
                    print("[Tracking] tick — 매칭 없음, 후보 유지")
                    self.isTrackingTickInFlight = false
                }
                return
            }
            DispatchQueue.main.async {
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

    /// runTrackingTick 의 main 큐 후속 처리. PnP 없이 best keyframe 까지 prefix drop +
    /// checkpoint 갱신 + localizedPose 갱신 + 도착 판정.
    private func handleTrackingMatchResult(
        bestIdx: Int,
        bestMatched: Int,
        perKfMatches: [(idx: Int, matched: Int)],
        arPoseAtCapture: simd_float4x4
    ) {
        // 진단 로그 — best + 후보 별 매칭 점 수
        let perKfStr = perKfMatches.map { "\($0.idx):\($0.matched)" }.joined(separator: ",")
        print("[LightGlue][진단] kf=\(bestIdx) matched=\(bestMatched) per_kf=[\(perKfStr)]")

        // "지워나감" — best 까지 prefix drop. snapshot 인덱스(idx)는 매칭 시점 candidatesSnapshot 기준.
        // 본 main 큐 도달 시점에 trackingKeyframeCandidates 가 다른 흐름으로 변경됐을 가능성 — count 가드.
        guard bestIdx < trackingKeyframeCandidates.count else {
            print("[Tracking] 후보 스냅샷 stale — drop skip")
            return
        }
        trackingKeyframeCandidates = Array(trackingKeyframeCandidates[bestIdx...])
        lastBestKeyframeIndex = bestIdx

        // best keyframe 의 pose4x4 마지막 열 → localizedPose 갱신 (서버 좌표).
        // PnP 없이 keyframe 좌표 그대로 사용 — 사용자 위치 ≈ keyframe 위치 가정.
        if let bestKf = trackingKeyframeCandidates.first {
            let kfTr = bestKf.pose4x4
            // homogeneous 마지막 열 = translation (서버 좌표)
            let kfPos = simd_float3(
                Float(kfTr[0][3]),
                Float(kfTr[1][3]),
                Float(kfTr[2][3])
            )
            // 회전 — pose4x4 는 row-major 4×4. 회전 부분 추출은 향후 R→quat 변환 도입 (TODO).
            // 현재 단계는 위치만 사용.
            let newPose = Pose(
                x: Double(kfPos.x), y: Double(kfPos.y), z: Double(kfPos.z),
                qx: localizedPose?.qx ?? 0,
                qy: localizedPose?.qy ?? 0,
                qz: localizedPose?.qz ?? 0,
                qw: localizedPose?.qw ?? 1
            )
            self.localizedPose = newPose
            self.matchedARPose = arPoseAtCapture
        }

        // checkpoint (다음 keyframe = 후보 마지막) 갱신
        updateCheckpointNode()

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
                print("[Tracking] 도착 판정 — dist=\(String(format: "%.2f", dist))m < \(trackingArrivalThresholdM)m")
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
        print("[Tracking] 후보 정렬 완료 — count=\(sorted.count) (시작쪽→목적지쪽)")
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

        if let node = checkpointNode {
            node.position = SCNVector3(placement.x, placement.y, placement.z)
        } else {
            let node = createCheckpointNode(at: placement)
            scene?.rootNode.addChildNode(node)
            checkpointNode = node
        }
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

    /// UIImage의 imageOrientation을 실제 픽셀에 redraw하여 .up 정방향 UIImage 반환.
    /// PNG는 EXIF orientation을 지원하지 않으므로 pngData() 호출 전에 baking 필수.
    private func bakeOrientation(_ image: UIImage) -> UIImage {
        let inOri = image.imageOrientation.rawValue
        let inSize = image.size
        let inCG = image.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
        let inPNG = image.pngData()?.count ?? -1

        if image.imageOrientation == .up {
            print("[BAKE] skip (already .up) orientation=\(inOri) size=\(Int(inSize.width))x\(Int(inSize.height)) cg=\(inCG) png=\(inPNG)B")
            return image
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let baked = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        let outOri = baked.imageOrientation.rawValue
        let outSize = baked.size
        let outCG = baked.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
        let outPNG = baked.pngData()?.count ?? -1
        print("[BAKE] in: ori=\(inOri) size=\(Int(inSize.width))x\(Int(inSize.height)) cg=\(inCG) png=\(inPNG)B → out: ori=\(outOri) size=\(Int(outSize.width))x\(Int(outSize.height)) cg=\(outCG) png=\(outPNG)B")
        return baked
    }

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
