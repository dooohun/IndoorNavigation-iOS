import UIKit
import SceneKit
import ARKit

/// Phase 6: HUD 컨테이너용 pass-through view. 자식이 잡지 않은 터치는 sceneView 로 통과.
/// transparent HUD 영역에서 sceneView 의 더블탭 제스처(측위 재시작) 가 정상 동작하도록.
private final class HUDPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 자기 자신은 통과시키고, 자식이 잡으면 그 자식 반환
        return hit === self ? nil : hit
    }
}

class ARNavigationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    var buildingId: String = ""
    var floorId: String = ""
    var destinationName: String = ""
    var goal: Coordinate = Coordinate(x: 0, y: 0, z: 0)

    var sceneView: ARSCNView!
    var locateButton: UIButton!
    var closeButton: UIButton!
    var scanningOverlayView: UIView!
    var captureCountLabel: UILabel!
    var scanCompleteBadge: UIView!
    var scanFailedView: UIView!
    var scanFailedLabel: UILabel!
    var arrivalBadge: UIView!

    var hudContainerView: UIView!
    // Phase 6: 기존 HUD 멤버는 신규 카드 UX 흐름에서 미사용 — 옵셔널화로 nil 안전
    var destinationPillView: UIView?
    var destinationLabel: UILabel?
    var remainingDistanceLabel: UILabel?
    var instructionCardView: UIView?
    var instructionLabel: UILabel?

    // Phase 6: 신규 목적지 pill 내부 컴포넌트
    var destinationIconCircle: UIView!
    var destinationFloorLabel: UILabel!
    var destinationNameLabel: UILabel!

    // Phase 6: 현재 스텝 카드
    var currentStepCardView: UIView!
    var currentStepIconBox: UIView!
    var currentStepIconView: UIImageView!
    var currentStepActionLabel: UILabel!
    var currentStepDistanceLabel: UILabel!
    var currentStepWalkLabel: UILabel!

    // Phase 6: 하단 거리/시간 캡슐
    var remainingCapsuleView: UIView!
    var remainingCapsuleLabel: UILabel!

    // Phase 6: 재측정 버튼 라벨 상태 추적 — 첫 측위 성공 전엔 "주변 스캔", 이후 "재측정".
    private var hasLocalizedSuccessfully = false

    var routeCalculatingView: UIView!
    var routeCalculatingLabel: UILabel!

    var floorTransitionOverlayView: UIView!
    var floorTransitionTitleLabel: UILabel!
    var floorTransitionTargetLabel: UILabel!
    var floorTransitionRestartButton: UIButton!

    // Phase 5: 방향 안내 UI
    private var headingOverlayView: HeadingAlignmentOverlayView!
    private var turnCardView: TurnCardView!

    // Phase 6: AR 공간 3D 회전 화살표 (Logic 의 updateTurnArrow delegate 로 갱신)
    private var turnArrowNode: SCNNode?
    private var turnArrowStepIndex: Int?

    // Phase 7: SuperPoint 디버그 시각화 (DEBUG 빌드 전용)
    #if DEBUG
    private var superPointDebug: SuperPointDebugController?
    #endif

    private var logic: ARNavigationLogic!

    override func viewDidLoad() {
        super.viewDidLoad()

        logic = ARNavigationLogic(buildingId: buildingId, floorId: floorId, destinationName: destinationName, goal: goal)

        setupARView()
        setupCloseButton()
        setupRelocalizeButton()
        setupScanningOverlay()
        setupScanCompleteBadge()
        setupScanFailedView()
        setupArrivalBadge()
        // Phase 6: setupHUD() 폐기 → 5개 신규 setup 으로 대체
        setupHudContainer()
        setupDestinationPill()
        setupCurrentStepCard()
        setupRemainingCapsule()
        setupRouteCalculatingView()
        setupFloorTransitionOverlay()
        // Phase 8: setupHeadingOverlay() / setupTurnCard() 호출 제거 — keyframe 단계 추적 모델
        //          (checkpoint 1개) 로 대체. 함수 본체는 dead path 로 보존.

        logic.delegate = self
        logic.arSession = sceneView.session
        logic.scene = sceneView.scene
        // Phase 8: setGuidanceDelegate 호출 제거 — headingOverlayView/turnCardView 가 IUO 인데
        //          setupHeadingOverlay/setupTurnCard 미호출이라 nil. delegate 메서드 호출 시 강제 언래핑 크래시.
        //          GuidanceDirector 인스턴스는 보존(향후 Phase 5 부활 가능성). delegate 미등록 → no-op.
        // TODO(phase8+): GuidanceDirector 인스턴스 자체 옵셔널화 또는 폐기.

        // Phase 7: SuperPoint extractor.
        // Phase 6 UI 정리: 상단 SP / DUMP 디버그 버튼은 사용자 요청으로 비활성.
        // SuperPointDebugController 인스턴스화 자체를 끔 — keypoint 오버레이/추론 시간/dump 버튼 모두 노출 X.
        logic.setupSuperPointExtractor()

        // Phase 8: 화면 더블탭 → 측위 재시작 (무한 테스트용)
        setupRetapGestureForTesting()

        // Phase 6: 닫기 / 재측정 버튼이 scanningOverlay·floorTransitionOverlay 등에 가려지지 않도록 항상 최상단으로.
        self.view.bringSubviewToFront(closeButton)
        self.view.bringSubviewToFront(locateButton)
    }

    /// 화면 더블탭 시 측위 재시작 — 무한 테스트용. logic.startLocalizationFlow() 가 idempotent.
    private func setupRetapGestureForTesting() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onSceneRetapped))
        tap.numberOfTapsRequired = 2
        sceneView.addGestureRecognizer(tap)
    }

    @objc private func onSceneRetapped() {
        logic.startLocalizationFlow()
    }

    // MARK: - UI 세팅

    private func setupARView() {
        sceneView = ARSCNView(frame: self.view.bounds)
        self.view.addSubview(sceneView)
        sceneView.delegate = self
        sceneView.showsStatistics = true
        sceneView.autoenablesDefaultLighting = true
    }

    private func setupCloseButton() {
        // Phase 6: 좌상단 원형 X 버튼 (44pt, blur, xmark 18pt semibold)
        closeButton = UIButton(type: .system)
        let assetIcon = UIImage(named: "closeThick")?
            .withRenderingMode(.alwaysTemplate)
            .resized(to: CGSize(width: 18, height: 18))
        let fallbackConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let icon = assetIcon ?? UIImage(systemName: "xmark", withConfiguration: fallbackConfig)
        closeButton.setImage(icon, for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        closeButton.layer.cornerRadius = 22
        closeButton.layer.masksToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(onCloseButtonTapped), for: .touchUpInside)

        // blur 백드롭
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 22
        blur.layer.masksToBounds = true
        closeButton.insertSubview(blur, at: 0)

        self.view.addSubview(closeButton)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            blur.topAnchor.constraint(equalTo: closeButton.topAnchor),
            blur.leadingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
        ])
    }

    @objc private func onCloseButtonTapped() {
        dismiss(animated: true)
    }

    private func setupRelocalizeButton() {
        // Phase 6: 하단 중앙 캡슐 (52pt 높이, blur, viewfinder + "재측정")
        // 인스턴스는 기존 locateButton 그대로 재사용.
        locateButton = UIButton(type: .system)
        // 초기 default — 첫 측위 성공(setLocateButtonVisible(true)) 시 "재측정" 으로 전환.
        locateButton.setTitle("주변 스캔", for: .normal)
        locateButton.setTitleColor(.white, for: .normal)
        locateButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        let assetIcon = UIImage(named: "compass")?
            .withRenderingMode(.alwaysTemplate)
            .resized(to: CGSize(width: 20, height: 20))
        let fallbackConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let icon = assetIcon ?? UIImage(systemName: "viewfinder", withConfiguration: fallbackConfig)
        locateButton.setImage(icon, for: .normal)
        locateButton.tintColor = .white
        locateButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        locateButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        locateButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        locateButton.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        locateButton.layer.cornerRadius = 26
        locateButton.layer.masksToBounds = true
        locateButton.layer.borderWidth = 1
        locateButton.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        locateButton.translatesAutoresizingMaskIntoConstraints = false
        locateButton.addTarget(self, action: #selector(onLocateButtonTapped), for: .touchUpInside)

        // blur 백드롭
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 26
        blur.layer.masksToBounds = true
        locateButton.insertSubview(blur, at: 0)

        self.view.addSubview(locateButton)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            locateButton.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -16),
            locateButton.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            locateButton.heightAnchor.constraint(equalToConstant: 52),

            blur.topAnchor.constraint(equalTo: locateButton.topAnchor),
            blur.leadingAnchor.constraint(equalTo: locateButton.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: locateButton.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: locateButton.bottomAnchor),
        ])
    }

    private func setupScanningOverlay() {
        let bounds = self.view.bounds

        scanningOverlayView = UIView(frame: bounds)
        scanningOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scanningOverlayView.isHidden = true
        scanningOverlayView.isUserInteractionEnabled = false

        // 스캔 아이콘 (SF Symbol)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let iconImage = UIImage(systemName: "viewfinder", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: bounds.midX - 40, y: bounds.midY - 120, width: 80, height: 80)

        // 메인 안내 문구
        let titleLabel = UILabel()
        titleLabel.text = "주변을 천천히 둘러보세요"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.frame = CGRect(x: 20, y: bounds.midY - 20, width: bounds.width - 40, height: 30)

        // 보조 안내 문구
        let subtitleLabel = UILabel()
        subtitleLabel.text = "위치를 확인하고 있어요.\n스마트폰을 들고 천천히 움직여 보세요."
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.frame = CGRect(x: 20, y: bounds.midY + 16, width: bounds.width - 40, height: 50)

        // 캡처 진행 카운트 (subtitle 아래 16pt)
        captureCountLabel = UILabel()
        captureCountLabel.text = ""
        captureCountLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        captureCountLabel.font = .systemFont(ofSize: 14, weight: .medium)
        captureCountLabel.textAlignment = .center
        captureCountLabel.isHidden = true
        captureCountLabel.frame = CGRect(x: 20, y: bounds.midY + 82, width: bounds.width - 40, height: 20)

        scanningOverlayView.addSubview(iconView)
        scanningOverlayView.addSubview(titleLabel)
        scanningOverlayView.addSubview(subtitleLabel)
        scanningOverlayView.addSubview(captureCountLabel)
        self.view.addSubview(scanningOverlayView)
    }

    private func setupScanCompleteBadge() {
        let bounds = self.view.bounds

        // 반투명 어두운 배경
        scanCompleteBadge = UIView(frame: bounds)
        scanCompleteBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        scanCompleteBadge.isHidden = true
        scanCompleteBadge.isUserInteractionEnabled = false

        // 필(pill) 형태 배지
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        pill.layer.cornerRadius = 22
        pill.translatesAutoresizingMaskIntoConstraints = false
        scanCompleteBadge.addSubview(pill)

        // 체크마크 아이콘
        let checkConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let checkImage = UIImage(systemName: "checkmark.circle.fill", withConfiguration: checkConfig)
        let checkView = UIImageView(image: checkImage)
        checkView.tintColor = .systemBlue
        checkView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(checkView)

        // "스캔 완료" 텍스트
        let label = UILabel()
        label.text = "스캔 완료"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        self.view.addSubview(scanCompleteBadge)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: scanCompleteBadge.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: scanCompleteBadge.bottomAnchor, constant: -bounds.height * 0.35),
            pill.heightAnchor.constraint(equalToConstant: 44),

            checkView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            checkView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 22),
            checkView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: checkView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
        ])
    }

    private func setupScanFailedView() {
        let bounds = self.view.bounds

        scanFailedView = UIView(frame: bounds)
        scanFailedView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scanFailedView.isHidden = true
        scanFailedView.isUserInteractionEnabled = false

        // 실패 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        let iconImage = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: bounds.midX - 25, y: bounds.midY - 80, width: 50, height: 50)

        // 실패 메시지
        scanFailedLabel = UILabel()
        scanFailedLabel.textColor = .white
        scanFailedLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        scanFailedLabel.textAlignment = .center
        scanFailedLabel.numberOfLines = 0
        scanFailedLabel.frame = CGRect(x: 20, y: bounds.midY - 16, width: bounds.width - 40, height: 60)

        scanFailedView.addSubview(iconView)
        scanFailedView.addSubview(scanFailedLabel)
        self.view.addSubview(scanFailedView)
    }

    private func setupArrivalBadge() {
        let bounds = self.view.bounds

        // 반투명 어두운 배경
        arrivalBadge = UIView(frame: bounds)
        arrivalBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        arrivalBadge.isHidden = true
        arrivalBadge.isUserInteractionEnabled = false

        // 필(pill) 형태 배지
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        pill.layer.cornerRadius = 22
        pill.translatesAutoresizingMaskIntoConstraints = false
        arrivalBadge.addSubview(pill)

        // 위치 핀 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let iconImage = UIImage(systemName: "mappin.circle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemRed
        iconView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(iconView)

        // "목적지 도착" 텍스트
        let label = UILabel()
        label.text = "목적지 도착"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        self.view.addSubview(arrivalBadge)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: arrivalBadge.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: arrivalBadge.bottomAnchor, constant: -bounds.height * 0.35),
            pill.heightAnchor.constraint(equalToConstant: 44),

            iconView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Phase 6 신규 HUD setup (setupHUD 분해)

    private func setupHudContainer() {
        let bounds = self.view.bounds
        // Phase 6: PassthroughView 로 transparent 영역은 sceneView 의 더블탭 제스처에 위임.
        // 자식 버튼은 정상 터치 수신.
        hudContainerView = HUDPassthroughView(frame: bounds)
        hudContainerView.isUserInteractionEnabled = true
        hudContainerView.isHidden = true
        self.view.addSubview(hudContainerView)
    }

    /// docs Phase 6 §2 — 상단 목적지 pill (높이 56pt, 좌측 36pt 원 아이콘 + 2행 텍스트).
    private func setupDestinationPill() {
        let pill = UIView()
        pill.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        pill.layer.cornerRadius = 28
        pill.layer.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(pill)
        destinationPillView = pill

        // blur 백드롭
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 28
        blur.layer.masksToBounds = true
        pill.insertSubview(blur, at: 0)

        // 좌측 36pt 원 (systemBlue)
        destinationIconCircle = UIView()
        destinationIconCircle.backgroundColor = .systemBlue
        destinationIconCircle.layer.cornerRadius = 18
        destinationIconCircle.layer.masksToBounds = true
        destinationIconCircle.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(destinationIconCircle)

        let flagAsset = UIImage(named: "flagFill")?.withRenderingMode(.alwaysTemplate)
        let flagFallback = UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        let flagIcon = UIImageView(image: flagAsset ?? flagFallback)
        flagIcon.tintColor = .white
        flagIcon.contentMode = .scaleAspectFit
        flagIcon.translatesAutoresizingMaskIntoConstraints = false
        destinationIconCircle.addSubview(flagIcon)

        // 1행: "3F · 목적지"
        destinationFloorLabel = UILabel()
        destinationFloorLabel.text = "—F · 목적지"
        destinationFloorLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        destinationFloorLabel.font = .systemFont(ofSize: 12, weight: .regular)
        destinationFloorLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(destinationFloorLabel)

        // 2행: POI 이름
        destinationNameLabel = UILabel()
        destinationNameLabel.text = destinationName
        destinationNameLabel.textColor = .white
        destinationNameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        destinationNameLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(destinationNameLabel)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 56),
            pill.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            // 가운데 정렬 — closeButton 과의 충돌만 leading greaterThanOrEqual 로 방지.
            pill.centerXAnchor.constraint(equalTo: hudContainerView.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 12),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -16),

            blur.topAnchor.constraint(equalTo: pill.topAnchor),
            blur.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: pill.bottomAnchor),

            destinationIconCircle.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            destinationIconCircle.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            destinationIconCircle.widthAnchor.constraint(equalToConstant: 36),
            destinationIconCircle.heightAnchor.constraint(equalToConstant: 36),

            flagIcon.centerXAnchor.constraint(equalTo: destinationIconCircle.centerXAnchor),
            flagIcon.centerYAnchor.constraint(equalTo: destinationIconCircle.centerYAnchor),
            flagIcon.widthAnchor.constraint(equalToConstant: 18),
            flagIcon.heightAnchor.constraint(equalToConstant: 18),

            destinationFloorLabel.leadingAnchor.constraint(equalTo: destinationIconCircle.trailingAnchor, constant: 10),
            destinationFloorLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            destinationFloorLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 10),

            destinationNameLabel.leadingAnchor.constraint(equalTo: destinationIconCircle.trailingAnchor, constant: 10),
            destinationNameLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            destinationNameLabel.topAnchor.constraint(equalTo: destinationFloorLabel.bottomAnchor, constant: 2),
        ])
    }

    /// docs Phase 6 §3 — 현재 스텝 카드 (systemBlue 배경, 56pt 아이콘 박스 + 3행 텍스트).
    private func setupCurrentStepCard() {
        let card = UIView()
        card.backgroundColor = .systemBlue
        card.layer.cornerRadius = 20
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(card)
        currentStepCardView = card

        // 좌측 56pt 아이콘 박스
        currentStepIconBox = UIView()
        currentStepIconBox.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        currentStepIconBox.layer.cornerRadius = 16
        currentStepIconBox.layer.masksToBounds = true
        currentStepIconBox.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(currentStepIconBox)

        let upAsset = UIImage(named: "arrowUpThick")?.withRenderingMode(.alwaysTemplate)
        let upFallback = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold))
        currentStepIconView = UIImageView(image: upAsset ?? upFallback)
        currentStepIconView.tintColor = .white
        currentStepIconView.contentMode = .scaleAspectFit
        currentStepIconView.translatesAutoresizingMaskIntoConstraints = false
        currentStepIconBox.addSubview(currentStepIconView)

        // 1행: 동작 단어
        currentStepActionLabel = UILabel()
        currentStepActionLabel.text = "—"
        currentStepActionLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        currentStepActionLabel.font = .systemFont(ofSize: 14, weight: .regular)
        currentStepActionLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(currentStepActionLabel)

        // 2행: 큰 거리 숫자 + m (attributedText 로 갱신됨)
        currentStepDistanceLabel = UILabel()
        currentStepDistanceLabel.textColor = .white
        currentStepDistanceLabel.font = .systemFont(ofSize: 28, weight: .heavy)
        currentStepDistanceLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(currentStepDistanceLabel)

        // 3행: "약 N걸음"
        currentStepWalkLabel = UILabel()
        currentStepWalkLabel.text = "약 —걸음"
        currentStepWalkLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        currentStepWalkLabel.font = .systemFont(ofSize: 13, weight: .regular)
        currentStepWalkLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(currentStepWalkLabel)

        guard let pill = destinationPillView else { return }

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 16),
            card.leadingAnchor.constraint(equalTo: hudContainerView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: hudContainerView.trailingAnchor, constant: -16),

            currentStepIconBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            currentStepIconBox.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            currentStepIconBox.widthAnchor.constraint(equalToConstant: 56),
            currentStepIconBox.heightAnchor.constraint(equalToConstant: 56),

            currentStepIconView.centerXAnchor.constraint(equalTo: currentStepIconBox.centerXAnchor),
            currentStepIconView.centerYAnchor.constraint(equalTo: currentStepIconBox.centerYAnchor),
            currentStepIconView.widthAnchor.constraint(equalToConstant: 32),
            currentStepIconView.heightAnchor.constraint(equalToConstant: 32),

            currentStepActionLabel.leadingAnchor.constraint(equalTo: currentStepIconBox.trailingAnchor, constant: 14),
            currentStepActionLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            currentStepActionLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),

            currentStepDistanceLabel.leadingAnchor.constraint(equalTo: currentStepIconBox.trailingAnchor, constant: 14),
            currentStepDistanceLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            currentStepDistanceLabel.topAnchor.constraint(equalTo: currentStepActionLabel.bottomAnchor, constant: 2),

            currentStepWalkLabel.leadingAnchor.constraint(equalTo: currentStepIconBox.trailingAnchor, constant: 14),
            currentStepWalkLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            currentStepWalkLabel.topAnchor.constraint(equalTo: currentStepDistanceLabel.bottomAnchor, constant: 2),
            currentStepWalkLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
    }

    /// docs Phase 6 §5 — 하단 거리/시간 캡슐 (44pt 높이, blur, attributed).
    private func setupRemainingCapsule() {
        let capsule = UIView()
        capsule.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        capsule.layer.cornerRadius = 22
        capsule.layer.masksToBounds = true
        capsule.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(capsule)
        remainingCapsuleView = capsule

        // blur 백드롭
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 22
        blur.layer.masksToBounds = true
        capsule.insertSubview(blur, at: 0)

        remainingCapsuleLabel = UILabel()
        remainingCapsuleLabel.text = "남은 거리 —"
        remainingCapsuleLabel.textColor = .white
        remainingCapsuleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        remainingCapsuleLabel.textAlignment = .center
        remainingCapsuleLabel.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(remainingCapsuleLabel)

        let safeArea = self.view.safeAreaLayoutGuide
        // 재측정 버튼 위 16pt — locateButton 은 setupRelocalizeButton 에서 생성됨
        NSLayoutConstraint.activate([
            capsule.heightAnchor.constraint(equalToConstant: 44),
            capsule.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: locateButton.topAnchor, constant: -16),

            blur.topAnchor.constraint(equalTo: capsule.topAnchor),
            blur.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),

            remainingCapsuleLabel.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 18),
            remainingCapsuleLabel.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -18),
            remainingCapsuleLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])
    }

    private func setupRouteCalculatingView() {
        routeCalculatingView = UIView()
        routeCalculatingView.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        routeCalculatingView.layer.cornerRadius = 16
        routeCalculatingView.layer.shadowColor = UIColor.black.cgColor
        routeCalculatingView.layer.shadowOpacity = 0.15
        routeCalculatingView.layer.shadowRadius = 8
        routeCalculatingView.layer.shadowOffset = CGSize(width: 0, height: 2)
        routeCalculatingView.translatesAutoresizingMaskIntoConstraints = false
        routeCalculatingView.isHidden = true
        routeCalculatingView.isUserInteractionEnabled = false
        self.view.addSubview(routeCalculatingView)

        routeCalculatingLabel = UILabel()
        routeCalculatingLabel.text = "경로를 계산 중입니다…"
        routeCalculatingLabel.textColor = .darkText
        routeCalculatingLabel.font = .systemFont(ofSize: 16, weight: .medium)
        routeCalculatingLabel.textAlignment = .center
        routeCalculatingLabel.translatesAutoresizingMaskIntoConstraints = false
        routeCalculatingView.addSubview(routeCalculatingLabel)

        let safeArea = self.view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            routeCalculatingView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            routeCalculatingView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -100),

            routeCalculatingLabel.leadingAnchor.constraint(equalTo: routeCalculatingView.leadingAnchor, constant: 20),
            routeCalculatingLabel.trailingAnchor.constraint(equalTo: routeCalculatingView.trailingAnchor, constant: -20),
            routeCalculatingLabel.topAnchor.constraint(equalTo: routeCalculatingView.topAnchor, constant: 14),
            routeCalculatingLabel.bottomAnchor.constraint(equalTo: routeCalculatingView.bottomAnchor, constant: -14),
        ])
    }

    private func setupFloorTransitionOverlay() {
        let bounds = self.view.bounds

        // 컨테이너 (전체화면 어두운 배경)
        floorTransitionOverlayView = UIView(frame: bounds)
        floorTransitionOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        floorTransitionOverlayView.isHidden = true
        floorTransitionOverlayView.isUserInteractionEnabled = true
        self.view.addSubview(floorTransitionOverlayView)

        // 카드 뷰 (중앙)
        let cardView = UIView()
        cardView.backgroundColor = UIColor.white
        cardView.layer.cornerRadius = 20
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.2
        cardView.layer.shadowRadius = 12
        cardView.layer.shadowOffset = CGSize(width: 0, height: 4)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        floorTransitionOverlayView.addSubview(cardView)

        // 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 50, weight: .medium)
        let iconImage = UIImage(systemName: "figure.stairs", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(iconView)

        // 타이틀 라벨
        floorTransitionTitleLabel = UILabel()
        floorTransitionTitleLabel.text = "계단을 이용해주세요"
        floorTransitionTitleLabel.textColor = .darkText
        floorTransitionTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        floorTransitionTitleLabel.textAlignment = .center
        floorTransitionTitleLabel.numberOfLines = 0
        floorTransitionTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(floorTransitionTitleLabel)

        // 본문 라벨 (정적)
        let bodyLabel = UILabel()
        bodyLabel.text = "원하는 층에 도착하면 다시 스캔해야 합니다."
        bodyLabel.textColor = .gray
        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(bodyLabel)

        // 목표 층 라벨
        floorTransitionTargetLabel = UILabel()
        floorTransitionTargetLabel.text = "목표: ―층으로 이동"
        floorTransitionTargetLabel.textColor = .systemBlue
        floorTransitionTargetLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        floorTransitionTargetLabel.textAlignment = .center
        floorTransitionTargetLabel.numberOfLines = 0
        floorTransitionTargetLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(floorTransitionTargetLabel)

        // 버튼
        floorTransitionRestartButton = UIButton(type: .system)
        floorTransitionRestartButton.setTitle("도착했습니다 — 다시 스캔하기", for: .normal)
        floorTransitionRestartButton.setTitleColor(.white, for: .normal)
        floorTransitionRestartButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        floorTransitionRestartButton.backgroundColor = .systemBlue
        floorTransitionRestartButton.tintColor = .white
        floorTransitionRestartButton.layer.cornerRadius = 12
        floorTransitionRestartButton.translatesAutoresizingMaskIntoConstraints = false
        floorTransitionRestartButton.addTarget(self, action: #selector(onFloorTransitionRestartTapped), for: .touchUpInside)
        cardView.addSubview(floorTransitionRestartButton)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: floorTransitionOverlayView.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: floorTransitionOverlayView.centerYAnchor),
            cardView.leadingAnchor.constraint(equalTo: floorTransitionOverlayView.leadingAnchor, constant: 24),
            cardView.trailingAnchor.constraint(equalTo: floorTransitionOverlayView.trailingAnchor, constant: -24),

            iconView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 28),
            iconView.widthAnchor.constraint(equalToConstant: 60),
            iconView.heightAnchor.constraint(equalToConstant: 60),

            floorTransitionTitleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            floorTransitionTitleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            floorTransitionTitleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            bodyLabel.topAnchor.constraint(equalTo: floorTransitionTitleLabel.bottomAnchor, constant: 16),
            bodyLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            bodyLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            floorTransitionTargetLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 16),
            floorTransitionTargetLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            floorTransitionTargetLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            floorTransitionRestartButton.topAnchor.constraint(equalTo: floorTransitionTargetLabel.bottomAnchor, constant: 16),
            floorTransitionRestartButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            floorTransitionRestartButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            floorTransitionRestartButton.heightAnchor.constraint(equalToConstant: 50),
            floorTransitionRestartButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -28),
        ])
    }

    private func setupHeadingOverlay() {
        headingOverlayView = HeadingAlignmentOverlayView(frame: self.view.bounds)
        headingOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(headingOverlayView)
    }

    private func setupTurnCard() {
        turnCardView = TurnCardView(frame: .zero)
        turnCardView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(turnCardView)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            turnCardView.widthAnchor.constraint(equalToConstant: TurnCardView.cardWidth),
            turnCardView.heightAnchor.constraint(equalToConstant: TurnCardView.cardHeight),
            turnCardView.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: TurnCardView.topInset),
            turnCardView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -TurnCardView.trailingInset),
        ])
    }

    @objc private func onFloorTransitionRestartTapped() {
        logic.restartFromFloorTransition()
    }

    @objc private func onLocateButtonTapped() {
        logic.startLocalizationFlow()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        sceneView.session.delegate = self
        sceneView.session.run(configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        logic.stopCapture()
        logic.stopArrivalCheck()
        logic.stopPathProgressTracking()
        sceneView.session.pause()
    }

    // MARK: - ARSessionDelegate (Phase 7)

    /// 매 ARFrame마다 SuperPoint 추론 cadence를 평가하고 통과 시 extractor 호출.
    /// 무거운 처리는 logic.processARFrame 내부에서 cadence 게이트로 차단된다.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        logic.processARFrame(frame)
    }
}

// MARK: - ARNavigationLogicDelegate

extension ARNavigationViewController: ARNavigationLogicDelegate {

    func updateStatus(_ message: String, color: UIColor) {
        // Phase 6: instructionLabel 은 신규 흐름에서 미사용 — 옵셔널 체이닝.
        instructionLabel?.text = message
        instructionLabel?.textColor = color == .white ? .darkText : color
    }

    func setLoading(_ loading: Bool) {
        locateButton.isEnabled = !loading
        locateButton.alpha = loading ? 0.5 : 1.0
    }

    func setCaptureProgress(text: String, isHidden: Bool) {
        if isHidden || text.isEmpty {
            captureCountLabel.isHidden = true
            captureCountLabel.text = ""
        } else {
            captureCountLabel.isHidden = false
            captureCountLabel.text = "\(text) 촬영 중"
        }
    }

    func setScanningOverlay(visible: Bool) {
        if visible {
            scanningOverlayView.alpha = 0
            scanningOverlayView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.scanningOverlayView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.3) {
                self.scanningOverlayView.alpha = 0
            } completion: { _ in
                self.scanningOverlayView.isHidden = true
            }
        }
    }

    func showScanComplete() {
        scanningOverlayView.isHidden = true

        scanCompleteBadge.alpha = 0
        scanCompleteBadge.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.scanCompleteBadge.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIView.animate(withDuration: 0.4) {
                self.scanCompleteBadge.alpha = 0
            } completion: { _ in
                self.scanCompleteBadge.isHidden = true
            }
        }
    }

    func showArrivalNotification() {
        setHUDVisible(false)
        arrivalBadge.alpha = 0
        arrivalBadge.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.arrivalBadge.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.4) {
                self.arrivalBadge.alpha = 0
            } completion: { _ in
                self.arrivalBadge.isHidden = true
            }
        }
    }

    func showScanFailed(message: String) {
        scanningOverlayView.isHidden = true
        scanFailedLabel.text = message

        scanFailedView.alpha = 0
        scanFailedView.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.scanFailedView.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.4) {
                self.scanFailedView.alpha = 0
            } completion: { _ in
                self.scanFailedView.isHidden = true
            }
        }
    }

    func updateHUD(destinationName: String, remainingDistance: Float, instruction: String?) {
        // Phase 6: 기존 IUO 라벨들은 신규 카드 UX 에서 미사용 — 옵셔널 체이닝.
        destinationLabel?.text = destinationName
        remainingDistanceLabel?.text = String(format: "약 %.0fm", remainingDistance)
        instructionLabel?.text = instruction ?? "경로를 따라가세요"
    }

    func updateNavigationStep(_ vm: NavigationStepViewModel) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. 목적지 pill
            if let floor = vm.destinationFloorLevel {
                self.destinationFloorLabel.text = "\(floor)F · 목적지"
            } else {
                self.destinationFloorLabel.text = "목적지"
            }
            self.destinationNameLabel.text = vm.destinationName

            // 2. 현재 step 카드 — 아이콘 (Montage SVG 우선, 폴백 SF Symbol)
            self.currentStepIconView.image = self.actionImage(for: vm.action)

            // 3. 동작 한국어 라벨
            self.currentStepActionLabel.text = self.actionLabel(for: vm.action)

            // 4. 거리 attributed (큰 숫자 28 heavy + m 16 regular)
            let distInt = max(0, Int(vm.distanceMeters.rounded()))
            let attr = NSMutableAttributedString(
                string: "\(distInt)",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .heavy),
                    .foregroundColor: UIColor.white,
                ]
            )
            attr.append(NSAttributedString(
                string: "m",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .regular),
                    .foregroundColor: UIColor.white,
                ]
            ))
            self.currentStepDistanceLabel.attributedText = attr

            // 5. 걸음 수
            self.currentStepWalkLabel.text = "약 \(vm.approxSteps)걸음"

            // 6. 하단 거리/시간 캡슐 — attributed
            let totalInt = max(0, Int(vm.remainingTotalMeters.rounded()))
            let cap = NSMutableAttributedString(
                string: "남은 거리 ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.white,
                ]
            )
            cap.append(NSAttributedString(
                string: "\(totalInt)m",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .heavy),
                    .foregroundColor: UIColor.systemBlue,
                ]
            ))
            cap.append(NSAttributedString(
                string: " | ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                ]
            ))
            cap.append(NSAttributedString(
                string: "약 \(vm.remainingMinutes)분",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.white,
                ]
            ))
            self.remainingCapsuleLabel.attributedText = cap
        }
    }

    func updateTurnArrow(_ vm: TurnArrowViewModel?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let vm = vm else {
                self.turnArrowNode?.removeFromParentNode()
                self.turnArrowNode = nil
                self.turnArrowStepIndex = nil
                return
            }
            if self.turnArrowStepIndex != vm.stepIndex || self.turnArrowNode == nil {
                self.turnArrowNode?.removeFromParentNode()
                let node = self.makeTurnArrowSCNNode(direction: vm.direction, kind: vm.kind)
                self.sceneView.scene.rootNode.addChildNode(node)
                self.turnArrowNode = node
                self.turnArrowStepIndex = vm.stepIndex
            }
            self.turnArrowNode?.position = SCNVector3(vm.arPosition.x, vm.arPosition.y, vm.arPosition.z)
            self.turnArrowNode?.eulerAngles = SCNVector3(0, self.turnArrowYaw(direction: vm.direction, kind: vm.kind), 0)
        }
    }

    /// 우회전 화살표 베이스 path. 좌/우 모두 동일 path 사용 — yaw 회전으로만 방향 차이.
    /// SCNShape extrusionDepth 0.05m. brand-blue + emission 으로 어두운 환경 시인성 확보.
    private func makeTurnArrowSCNNode(direction: TurnDirection, kind: TurnArrowKind) -> SCNNode {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0.4))
        path.addLine(to: CGPoint(x: 0.4, y: 0.4))
        path.addLine(to: CGPoint(x: 0.4, y: 0.5))
        path.addLine(to: CGPoint(x: 0.6, y: 0.3))
        path.addLine(to: CGPoint(x: 0.4, y: 0.1))
        path.addLine(to: CGPoint(x: 0.4, y: 0.2))
        path.addLine(to: CGPoint(x: 0.2, y: 0.2))
        path.addLine(to: CGPoint(x: 0.2, y: 0))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.05)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0/255, green: 102/255, blue: 255/255, alpha: 1)
        mat.emission.contents = UIColor(red: 0/255, green: 102/255, blue: 255/255, alpha: 1).withAlphaComponent(0.6)
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = true
        shape.materials = [mat]
        return SCNNode(geometry: shape)
    }

    /// TurnDirection × TurnArrowKind → SceneKit Y-yaw (rad).
    /// SceneKit 좌수/+Y up 기준 가정 — 시뮬레이터 검증으로 부호 확정 권고. 필요시 반전.
    private func turnArrowYaw(direction: TurnDirection, kind: TurnArrowKind) -> Float {
        switch (direction, kind) {
        case (.left, .sharp):   return Float.pi / 2
        case (.right, .sharp):  return -Float.pi / 2
        case (.left, .slight):  return Float.pi / 4
        case (.right, .slight): return -Float.pi / 4
        case (.uTurn, _):       return Float.pi
        default:                return 0
        }
    }

    /// NavigationActionKind → 카드 아이콘. 핸드오프 매핑(Montage SVG)을 우선 사용하고,
    /// 매핑 표에 없는 액션은 SF Symbol 로 폴백한다.
    private func actionImage(for action: NavigationActionKind) -> UIImage? {
        let assetName: String?
        let sfSymbol: String?
        switch action {
        case .straight:        assetName = "arrowUpThick";        sfSymbol = "arrow.up"
        case .turnLeft:        assetName = "arrowTurnDownLeft";   sfSymbol = "arrow.turn.up.left"
        case .turnRight:       assetName = "arrowTurnDownRight";  sfSymbol = "arrow.turn.up.right"
        case .arrive:          assetName = "flagFill";            sfSymbol = "flag.checkered"
        case .unknown:         assetName = "arrowUpThick";        sfSymbol = "arrow.up"
        case .turnSlightLeft:  assetName = nil;                   sfSymbol = "arrow.up.left"
        case .turnSlightRight: assetName = nil;                   sfSymbol = "arrow.up.right"
        case .uturn:           assetName = nil;                   sfSymbol = "arrow.uturn.down"
        case .stairsUp,
             .stairsDown:      assetName = nil;                   sfSymbol = "figure.stairs"
        case .elevator:        assetName = nil;                   sfSymbol = "arrow.up.arrow.down.square"
        }
        if let name = assetName, let img = UIImage(named: name) {
            return img.withRenderingMode(.alwaysTemplate)
        }
        if let sf = sfSymbol {
            let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
            return UIImage(systemName: sf, withConfiguration: cfg)
        }
        return nil
    }

    /// NavigationActionKind → 한국어 라벨.
    private func actionLabel(for action: NavigationActionKind) -> String {
        switch action {
        case .straight: return "직진"
        case .turnLeft: return "좌회전"
        case .turnRight: return "우회전"
        case .turnSlightLeft: return "좌측 진행"
        case .turnSlightRight: return "우측 진행"
        case .uturn: return "유턴"
        case .stairsUp: return "계단 (오르기)"
        case .stairsDown: return "계단 (내려가기)"
        case .elevator: return "엘리베이터"
        case .arrive: return "도착"
        case .unknown: return "진행"
        }
    }

    func setHUDVisible(_ visible: Bool) {
        if visible {
            hudContainerView.alpha = 0
            hudContainerView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.hudContainerView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.3) {
                self.hudContainerView.alpha = 0
            } completion: { _ in
                self.hudContainerView.isHidden = true
            }
            // Phase 6: HUD 숨김 시 AR 공간 turn 화살표도 동반 정리.
            self.turnArrowNode?.removeFromParentNode()
            self.turnArrowNode = nil
            self.turnArrowStepIndex = nil
        }
    }

    func setLocateButtonVisible(_ visible: Bool) {
        if visible {
            // 첫 측위 성공 이후엔 "재측정" 으로 라벨 전환.
            if !hasLocalizedSuccessfully {
                hasLocalizedSuccessfully = true
                locateButton.setTitle("재측정", for: .normal)
            }
            locateButton.alpha = 0
            locateButton.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.locateButton.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.2) {
                self.locateButton.alpha = 0
            } completion: { _ in
                self.locateButton.isHidden = true
            }
        }
    }

    func showRouteCalculating(_ visible: Bool) {
        if visible {
            routeCalculatingView.alpha = 0
            routeCalculatingView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.routeCalculatingView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.3) {
                self.routeCalculatingView.alpha = 0
            } completion: { _ in
                self.routeCalculatingView.isHidden = true
            }
        }
    }

    func showFloorTransition(transitionType: String, targetFloor: Int?, currentFloor: Int?) {
        if transitionType == "ELEVATOR" {
            floorTransitionTitleLabel.text = "엘리베이터를 이용해주세요"
        } else {
            floorTransitionTitleLabel.text = "계단을 이용해주세요"
        }

        if let target = targetFloor {
            floorTransitionTargetLabel.text = "목표: \(target)층으로 이동"
        } else {
            floorTransitionTargetLabel.text = "목표 층으로 이동해주세요"
        }

        floorTransitionOverlayView.alpha = 0
        floorTransitionOverlayView.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.floorTransitionOverlayView.alpha = 1
        }
    }

    func hideFloorTransition() {
        UIView.animate(withDuration: 0.3) {
            self.floorTransitionOverlayView.alpha = 0
        } completion: { _ in
            self.floorTransitionOverlayView.isHidden = true
        }
    }
}

// MARK: - GuidanceDirectorDelegate (Phase 5)

extension ARNavigationViewController: GuidanceDirectorDelegate {

    func guidance(_ director: GuidanceDirector, showInitialAlignment direction: TurnDirection, angle: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.headingOverlayView.show(direction: direction, angleDeg: angle, mode: .initial)
        }
    }

    func guidance(_ director: GuidanceDirector, showReorient direction: TurnDirection, angle: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.headingOverlayView.show(direction: direction, angleDeg: angle, mode: .reorient)
        }
    }

    func guidanceDismissAlignmentOverlay(_ director: GuidanceDirector) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.headingOverlayView.dismiss()
        }
    }

    func guidance(_ director: GuidanceDirector, showTurnCard direction: TurnDirection, distance: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnCardView.update(direction: direction, distanceMeters: distance)
            self.turnCardView.showSlideIn(in: self.view)
        }
    }

    func guidance(_ director: GuidanceDirector, updateTurnCardDistance distance: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnCardView.updateDistance(distance)
        }
    }

    func guidanceHideTurnCard(_ director: GuidanceDirector) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnCardView.hideSlideOut()
        }
    }
}

// MARK: - UIImage 리사이즈 헬퍼 (Phase 6)

private extension UIImage {
    /// vector 자산을 button 표시 사이즈로 리샘플링.
    func resized(to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
