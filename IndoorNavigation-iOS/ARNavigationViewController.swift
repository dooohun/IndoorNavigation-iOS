import UIKit
import SceneKit
import ARKit

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
    var destinationPillView: UIView!
    var destinationLabel: UILabel!
    var remainingDistanceLabel: UILabel!
    var instructionCardView: UIView!
    var instructionLabel: UILabel!

    var routeCalculatingView: UIView!
    var routeCalculatingLabel: UILabel!

    var floorTransitionOverlayView: UIView!
    var floorTransitionTitleLabel: UILabel!
    var floorTransitionTargetLabel: UILabel!
    var floorTransitionRestartButton: UIButton!

    // Phase 5: 방향 안내 UI
    private var headingOverlayView: HeadingAlignmentOverlayView!
    private var turnCardView: TurnCardView!

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
        setupLocateButton()
        setupScanningOverlay()
        setupScanCompleteBadge()
        setupScanFailedView()
        setupArrivalBadge()
        setupHUD()
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

        // Phase 7: SuperPoint extractor + 디버그 시각화 (DEBUG 빌드 전용)
        #if DEBUG
        let debugController = SuperPointDebugController(hostView: self.view)
        self.superPointDebug = debugController
        logic.attachSuperPointDebug(debugController)
        #endif
        logic.setupSuperPointExtractor()

        // Phase 8: 화면 더블탭 → 측위 재시작 (무한 테스트용)
        setupRetapGestureForTesting()
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
        closeButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 20
        closeButton.frame = CGRect(x: 16, y: 60, width: 40, height: 40)
        closeButton.addTarget(self, action: #selector(onCloseButtonTapped), for: .touchUpInside)
        self.view.addSubview(closeButton)
    }

    @objc private func onCloseButtonTapped() {
        dismiss(animated: true)
    }

    private func setupLocateButton() {
        locateButton = UIButton(type: .system)
        locateButton.setTitle("\(destinationName) 길찾기 시작", for: .normal)
        locateButton.backgroundColor = .systemBlue
        locateButton.setTitleColor(.white, for: .normal)
        locateButton.layer.cornerRadius = 10
        locateButton.frame = CGRect(x: 20, y: self.view.bounds.height - 100, width: self.view.bounds.width - 40, height: 50)
        locateButton.addTarget(self, action: #selector(onLocateButtonTapped), for: .touchUpInside)
        self.view.addSubview(locateButton)
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

    private func setupHUD() {
        let bounds = self.view.bounds

        // 컨테이너 (visibility 토글용)
        hudContainerView = UIView(frame: bounds)
        hudContainerView.isUserInteractionEnabled = false
        hudContainerView.isHidden = true
        self.view.addSubview(hudContainerView)

        // 상단 목적지 pill
        destinationPillView = UIView()
        destinationPillView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        destinationPillView.layer.cornerRadius = 18
        destinationPillView.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(destinationPillView)

        destinationLabel = UILabel()
        destinationLabel.text = destinationName
        destinationLabel.textColor = .white
        destinationLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        destinationPillView.addSubview(destinationLabel)

        // 남은 거리 라벨
        remainingDistanceLabel = UILabel()
        remainingDistanceLabel.text = "약 ―m"
        remainingDistanceLabel.textColor = .white
        remainingDistanceLabel.font = .systemFont(ofSize: 28, weight: .bold)
        remainingDistanceLabel.textAlignment = .center
        remainingDistanceLabel.layer.shadowColor = UIColor.black.cgColor
        remainingDistanceLabel.layer.shadowOpacity = 0.6
        remainingDistanceLabel.layer.shadowRadius = 4
        remainingDistanceLabel.layer.shadowOffset = .zero
        remainingDistanceLabel.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(remainingDistanceLabel)

        // 하단 안내 카드
        instructionCardView = UIView()
        instructionCardView.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        instructionCardView.layer.cornerRadius = 16
        instructionCardView.layer.shadowColor = UIColor.black.cgColor
        instructionCardView.layer.shadowOpacity = 0.15
        instructionCardView.layer.shadowRadius = 8
        instructionCardView.layer.shadowOffset = CGSize(width: 0, height: 2)
        instructionCardView.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(instructionCardView)

        instructionLabel = UILabel()
        instructionLabel.text = "경로를 계산 중입니다…"
        instructionLabel.textColor = .darkText
        instructionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        instructionLabel.numberOfLines = 0
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionCardView.addSubview(instructionLabel)

        let safeArea = self.view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            // pill
            destinationPillView.centerXAnchor.constraint(equalTo: hudContainerView.centerXAnchor),
            destinationPillView.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 16),
            destinationPillView.heightAnchor.constraint(equalToConstant: 36),

            destinationLabel.leadingAnchor.constraint(equalTo: destinationPillView.leadingAnchor, constant: 16),
            destinationLabel.trailingAnchor.constraint(equalTo: destinationPillView.trailingAnchor, constant: -16),
            destinationLabel.topAnchor.constraint(equalTo: destinationPillView.topAnchor, constant: 8),
            destinationLabel.bottomAnchor.constraint(equalTo: destinationPillView.bottomAnchor, constant: -8),

            // 남은 거리
            remainingDistanceLabel.centerXAnchor.constraint(equalTo: hudContainerView.centerXAnchor),
            remainingDistanceLabel.topAnchor.constraint(equalTo: destinationPillView.bottomAnchor, constant: 12),

            // 안내 카드
            instructionCardView.centerXAnchor.constraint(equalTo: hudContainerView.centerXAnchor),
            instructionCardView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -100),
            instructionCardView.widthAnchor.constraint(equalTo: hudContainerView.widthAnchor, constant: -40),

            instructionLabel.leadingAnchor.constraint(equalTo: instructionCardView.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: instructionCardView.trailingAnchor, constant: -20),
            instructionLabel.topAnchor.constraint(equalTo: instructionCardView.topAnchor, constant: 14),
            instructionLabel.bottomAnchor.constraint(equalTo: instructionCardView.bottomAnchor, constant: -14),
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
        // 스캔 오버레이 / 완료 배지가 대체
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
        destinationLabel.text = destinationName
        remainingDistanceLabel.text = String(format: "약 %.0fm", remainingDistance)
        instructionLabel.text = instruction ?? "경로를 따라가세요"
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
        }
    }

    func setLocateButtonVisible(_ visible: Bool) {
        if visible {
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
