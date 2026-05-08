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

    // V3 측위 토글. false면 기존 SLAMv3(/api/slam/v3/localize) 사용.
    static let useV3Localize: Bool = true

    // V3 pathfinding 토글. 현재 useV3Localize 와 짝. legacy 분리가 필요해질 때만 false.
    static let useV3Pathfinding: Bool = true

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

        // Phase 8 bundle 로드 — 매 프레임 매칭 호환성 검증용. 실패해도 추론은 계속.
        // DEBUG 빌드 + UserDefaults `useNetworkBundle` == true 면 NetworkBundleProvider 사용,
        // 실패 시 MockBundleProvider 폴백.
        let useNetworkBundle: Bool = {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: "useNetworkBundle")
            #else
            return false
            #endif
        }()

        if useNetworkBundle {
            // TODO(S3): BuildingDetailResponse.floors 매핑 — 현재는 floorLevel hardcode
            // TODO(서버답): 빌딩 매핑 좌표계 origin 확인 — queryPosition (0,0,0)
            // TODO(서버답): 실측 byteSize 보고 radiusM 조정
            let provider = NetworkBundleProvider(
                buildingId: self.buildingId,
                floorLevel: 3,
                queryPosition: SIMD3<Double>(0, 0, 0),
                radiusM: 100.0
            )
            provider.fetch { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let bundle):
                    self.localizationBundle = bundle
                    self.keyframeDescriptorCache = bundle.keyframes.map { kf in
                        Data(base64Encoded: kf.descriptorsB64) ?? Data()
                    }
                    print("[NetworkBundle] loaded \(bundle.keyframes.count) keyframes (intrinsics \(bundle.manifest.intrinsics.width)×\(bundle.manifest.intrinsics.height))")
                case .failure(let error):
                    print("[NetworkBundle] fetch failed: \(error) — fallback to mock")
                    self.loadMockBundleFallback()
                }
            }
        } else {
            loadMockBundleFallback()
        }
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
        destinationPinNode = nil
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

        pathProgressTimer?.invalidate()
        pathProgressTimer = nil
        guidanceDirector.reset()
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
            delegate?.showRouteCalculating(false)
            delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
            let steps = pendingRemainingSteps
            pendingRemainingSteps = []
            isFloorTransitionRestart = false
            delegate?.setLoading(false)
            drawPathNodes(steps: steps)
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

        delegate?.showScanComplete()

        if isFloorTransitionRestart {
            // 잔여 경로 재렌더링 (서버 pathfinding 호출 생략)
            delegate?.showRouteCalculating(false)
            delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
            let steps = pendingRemainingSteps
            pendingRemainingSteps = []
            isFloorTransitionRestart = false
            delegate?.setLoading(false)
            drawPathNodes(steps: steps)
        } else {
            delegate?.showRouteCalculating(true)
            if Self.useV3Pathfinding {
                startV3Pathfinding(scanId: response.mapId,
                                   startFloorLevel: response.pose.floorLevel,
                                   translation: translation)
            } else {
                startCoordinateRoute(pose: pose, floorId: response.pose.floorId ?? self.floorId)
            }
        }
    }

    // MARK: - 경로 탐색

    private func startCoordinateRoute(pose: Pose, floorId: String) {
        let request = FloorCoordinateRouteRequest(
            start: Coordinate(x: pose.x ?? 0.0, y: pose.y ?? 0.0, z: pose.z),
            goal: self.goal
        )

        NetworkManager.shared.findRouteByCoordinates(buildingId: buildingId, floorId: floorId, request: request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.delegate?.setLoading(false)
                self.delegate?.showRouteCalculating(false)
                switch result {
                case .success(let response):
                    self.lastStartSnapDistance = response.snapInfo?.startSnapDistanceM
                    let steps = self.adaptRouteResponseToSteps(response: response)
                    if !steps.isEmpty {
                        self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                        self.drawPathNodes(steps: steps)
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
    private func startV3Pathfinding(scanId: String?, startFloorLevel: Int?, translation: simd_float3) {
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
                self.delegate?.setLoading(false)
                self.delegate?.showRouteCalculating(false)
                switch result {
                case .success(let resp):
                    let steps = resp.toPathSteps()
                    // TODO(서버답): V3 pathfinding 응답에 snapDistance 추가 시 채우기
                    self.lastStartSnapDistance = nil
                    print("[V3-PATH] steps=\(steps.count), totalDistance=\(resp.totalDistance)m, floorTransitions=\(resp.floorTransitions.count)")
                    if !steps.isEmpty {
                        self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                        self.drawPathNodes(steps: steps)
                    } else {
                        self.delegate?.showScanFailed(message: "경로를 찾지 못했어요.\n다시 한번 스캔해 주세요.")
                        self.delegate?.setLocateButtonVisible(true)
                    }
                case .failure:
                    // TODO(B5+): STAIRS 선택 시 PATH_NOT_FOUND → ELEVATOR 재시도
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
        destinationPinNode = nil

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
        let floorY = cameraY - 1.7

        // 서버 좌표를 AR 좌표로 변환 후 Y를 바닥 레벨로 고정
        var arPoints: [simd_float3] = []
        for step in steps {
            guard let pos = step.position else { continue }
            let serverPoint = simd_float3(Float(pos.x), Float(pos.y), Float(pos.z))
            let arPos = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
            arPoints.append(simd_float3(arPos.x, floorY, arPos.z))
        }

        if let firstAR = arPoints.first,
           let frame = arSession?.currentFrame {
            let cam = frame.camera.transform.columns.3
            let dxz = sqrt((firstAR.x - cam.x) * (firstAR.x - cam.x) +
                           (firstAR.z - cam.z) * (firstAR.z - cam.z))
            let snapStr = lastStartSnapDistance.map { String(format: "%.2f", $0) } ?? "nil"
            print(String(format: "[PATH-START] firstAR=(%.2f, %.2f, %.2f), camNow=(%.2f, %.2f), Δxz=%.2fm, snapStart=%@",
                         firstAR.x, firstAR.y, firstAR.z, cam.x, cam.z, dxz, snapStr))
        }

        guard arPoints.count >= 2 else {
            delegate?.showScanFailed(message: "경로 정보가 비어 있어요.\n다시 한번 스캔해 주세요.")
            delegate?.setLocateButtonVisible(true)
            return
        }

        // RDP 사전 단순화: 시각 경로·turn 판정 모두 동일 점열 기반
        let simplifiedARPoints = simplifyXZ(points: arPoints, epsilon: pathSimplificationEpsilonM)
        simplifiedPointCount = simplifiedARPoints.count
        print(String(format: "[PATH-RDP] raw=%d → simplified=%d (ε=%.2fm)", arPoints.count, simplifiedARPoints.count, pathSimplificationEpsilonM))

        // Catmull-Rom 스플라인으로 부드러운 경로 생성
        let smoothPoints = catmullRomSpline(points: simplifiedARPoints, subdivisions: pathSubdivisions)

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

        currentTargetWaypointIndex = 1

        // 전체 경로 ribbon 생성
        rootNode.addChildNode(buildRibbonNode(points: smoothPoints))

        // 경로 구간별 더블 쉐브론 화살표 배치
        placeChevronArrows(on: smoothPoints, steps: steps, rootNode: rootNode)

        // 목적지에 빨간 3D 핀 마커 배치
        if let lastPoint = arPoints.last {
            let pinNode = createDestinationPin(at: lastPoint)
            rootNode.addChildNode(pinNode)
            destinationPinNode = pinNode
            destinationARPosition = lastPoint
            startArrivalCheck()
        }

        // Phase 5: 방향 안내 director에 경로 전달
        guidanceDirector.setRoute(smoothedPoints: smoothPoints)

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

        // ">>" 형태의 더블 쉐브론. 두 개의 V자(">")가 local +X(진행 방향)으로 in-line 분리되어 배치됨.
        // V자 평면은 local XY에 펼쳐지며(수직/세움), tip은 +X. placeChevronArrows에서 yaw로 +X를 진행 방향에 정렬한 뒤
        // 진행 방향에 수직인 수평축(world right) 기준 pitch를 적용하여 tip을 살짝 아래로 기울임.
        // 사용자는 chevron이 진행 방향 너머로 똑바로 서서 보임.
        let halfW: Float = 0.22     // 팔의 X방향 길이 (tip→base의 X 거리 절반)
        let halfH: Float = 0.32     // 팔이 펼쳐진 Y방향 (V자 폭) 절반
        let armLen: Float = sqrt((2 * halfW) * (2 * halfW) + halfH * halfH)
        let armThick: Float = 0.085 // Y cross-section (수평 자세에서 두께)
        let faceDepth: Float = 0.085// 팔 단면 깊이 (Z, 사각 단면)
        let gap: Float = 0.30       // 두 V자의 X축 간격 (in-line 분리)

        // 팔 방향: tip (xOff, 0, 0) → base (xOff - 2*halfW, ±halfH, 0).
        // local Z축 회전으로 V자 형성 (XY 평면에 펼침).
        let armAngle = atan2(halfH, 2 * halfW)

        for xOff: Float in [-gap / 2, gap / 2] {
            // 위쪽 팔 (Y+): Z축 +armAngle 회전
            let uBox = SCNBox(width: CGFloat(armLen), height: CGFloat(armThick), length: CGFloat(faceDepth), chamferRadius: 0)
            uBox.materials = [mat]
            let uNode = SCNNode(geometry: uBox)
            uNode.position = SCNVector3(xOff - halfW, halfH / 2, 0)
            uNode.eulerAngles = SCNVector3(0, 0, armAngle)
            bobNode.addChildNode(uNode)

            // 아래쪽 팔 (Y-): Z축 -armAngle 회전
            let lBox = SCNBox(width: CGFloat(armLen), height: CGFloat(armThick), length: CGFloat(faceDepth), chamferRadius: 0)
            lBox.materials = [mat]
            let lNode = SCNNode(geometry: lBox)
            lNode.position = SCNVector3(xOff - halfW, -halfH / 2, 0)
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
        // RDP 단순화로 spline 입력 점 수가 줄어 points.count ≠ steps.count * subdiv 이므로 비례 환산.
        // TODO: 정확한 turn 매핑 개선은 GuidanceDirector turns 좌표 활용으로 후속 분리.
        let subdiv = pathSubdivisions
        let denom = max((steps.count - 1) * subdiv, 1)
        let ratio = Float(points.count - 1) / Float(denom)
        var turnIndices: Set<Int> = []
        for (idx, step) in steps.enumerated() {
            if (step.instruction ?? "").contains("회전") {
                let si = min(Int(Float(idx * subdiv) * ratio), points.count - 1)
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

            // 진행 단위 벡터 t̂, 우측 perpendicular r̂ (Y-up right-hand)
            let invLen: Float = 1.0 / len
            let tHat = simd_float2(dx * invLen, dz * invLen)
            let rHat = simd_float2(-tHat.y, tHat.x)

            // 위치: 다음 노드 직전(진행 방향 끝) + 경로 우측 가장자리로 lateral 오프셋.
            let edgeOffsetFromNext: Float = 0.6
            let edgeLateralOffset: Float = 0.55  // ribbon stripWidth 0.8 → ±0.4 외측
            let chevronHeight: Float = 1       // 바닥에서 띄운 높이
            let t: Float = max(0.0, (len - edgeOffsetFromNext) / len)
            let cx = p.x + (pn.x - p.x) * t + rHat.x * edgeLateralOffset
            let cz = p.z + (pn.z - p.z) * t + rHat.y * edgeLateralOffset
            let cy = p.y + chevronHeight
            chevron.position = SCNVector3(cx, cy, cz)

            // Yaw: V자 꼭짓점은 모델 local -X에 위치하므로, local -X를 진행 방향(dx,dz)으로 향하게 하려면
            // local +X를 진행 방향에 맞추는 atan2(-dz, dx)에 π를 더해 180° 뒤집는다.
            let yawOffsetDeg: Float = 2.0
            let yawAngle = atan2(-dz, dx) * .pi + (yawOffsetDeg * .pi / 180.0)
            let yawQ = simd_quatf(angle: yawAngle, axis: simd_float3(0, 1, 0))

            // Pitch: 진행 방향 안쪽(아래쪽)으로 살짝 기울임. yaw 180° 반전에 따라 부호도 반전(-15°).
            // rHat 축 기준 -15° 회전 시 V자 꼭짓점(=진행 방향 끝)이 -Y쪽(아래)으로 기울어 안쪽으로 향함.
            let pitchAngleDeg: Float = 0
            let pitchAngle = pitchAngleDeg * .pi / 180.0
            let pitchAxis = simd_float3(rHat.x, 0, rHat.y)
            let pitchQ = simd_quatf(angle: pitchAngle, axis: pitchAxis)

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
            // ARKit columns.2는 카메라 back vector이므로 부호 반전하여 forward로 사용
            let camCol2 = frame.camera.transform.columns.2
            let cameraForward = simd_float3(-camCol2.x, -camCol2.y, -camCol2.z)
            self.tickPathProgress(cameraPos: cameraPos)
            self.guidanceDirector.update(
                cameraPosition: cameraPos,
                cameraForward: cameraForward,
                currentTargetWaypointIndex: self.currentTargetWaypointIndex
            )
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

        // 1-1. 층 이동 감지: 현재 waypoint(smooth index) → step index로 환산
        if !hasActiveFloorTransition {
            let subdiv = pathSubdivisions
            // RDP 단순화 후 spline 보간되어 smoothedPoints 길이가 (simplifiedPointCount-1)*subdiv 기준이 됨.
            // 원본 allSteps 인덱스로 비례 환산 (보정 옵션 2).
            let denom = max((simplifiedPointCount - 1) * subdiv, 1)
            let curStepIdx = max(0, min(
                Int(Float(currentTargetWaypointIndex) * Float(allSteps.count - 1) / Float(denom)),
                allSteps.count - 1
            ))
            if let detection = detectFloorTransition(currentStepIdx: curStepIdx) {
                let target = smoothedPoints[currentTargetWaypointIndex]
                let dx = cameraPos.x - target.x
                let dz = cameraPos.z - target.z
                let dist = sqrt(dx * dx + dz * dz)
                if dist < floorTransitionTriggerDistance {
                    triggerFloorTransition(type: detection.type, targetFloor: detection.targetFloor, currentStepIdx: curStepIdx)
                    return
                }
            }
        }

        // 2. HUD 갱신
        if currentTargetWaypointIndex >= smoothedPoints.count {
            // 도착
            pathProgressTimer?.invalidate()
            pathProgressTimer = nil
            guidanceDirector.reset()
            delegate?.updateHUD(destinationName: destinationName, remainingDistance: 0, instruction: "목적지에 도착했습니다")
            return
        }

        let remaining = computeRemainingDistance(cameraPos: cameraPos)
        let subdiv = pathSubdivisions
        let denom2 = max((simplifiedPointCount - 1) * subdiv, 1)
        let stepIdx = max(0, min(
            Int(Float(currentTargetWaypointIndex) * Float(allSteps.count - 1) / Float(denom2)),
            allSteps.count - 1
        ))
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

        delegate?.setLocateButtonVisible(false)
        delegate?.setScanningOverlay(visible: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.delegate?.setScanningOverlay(visible: false)
            self.delegate?.showScanComplete()

            if self.isFloorTransitionRestart {
                // 재스캔 모드: 잔여 경로 직접 사용 (경로 계산 카드 표시 생략)
                self.delegate?.showRouteCalculating(false)
                self.matchedARPose = frame.camera.transform
                self.localizedPose = self.makeMockPose()
                self.delegate?.setLoading(false)
                self.delegate?.updateStatus("경로를 따라 이동하세요.", color: .white)
                let steps = self.pendingRemainingSteps
                self.pendingRemainingSteps = []
                self.isFloorTransitionRestart = false
                self.drawPathNodes(steps: steps)
                return
            }

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
