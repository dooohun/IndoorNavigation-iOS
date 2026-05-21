import UIKit

// MARK: - RouteOverviewItem

/// 전체 경로 안내 화면의 한 행. origin/destination 은 시작/끝 행, step 은 중간 경유점.
struct RouteOverviewItem {
    enum Kind { case origin, step, destination }
    let kind: Kind
    /// origin/destination 은 .unknown. step 은 ARNavigationLogic.navigationActionKind 결과.
    let action: NavigationActionKind
    /// 사용자에게 보일 한 줄 설명. step 의 경우 ARNavigationLogic.makeRouteOverviewItems 에서
    /// POI/계단 문맥 합성된 한국어. 빈 경우 셀이 action 기반 fallback 사용.
    let instruction: String
    /// 직전 valid 좌표로부터의 XY 유클리드 거리(m). origin/destination 은 0.
    let distanceMeters: Double
    /// 해당 step 의 floorLevel (있을 때만). UI 미사용이지만 향후 층 표시 확장 대비 보존.
    let floorLevel: Int?
}

// MARK: - RouteOverviewViewController

/// 출발지 확인 직후 사용자에게 전체 경로(턴 시퀀스 + 총 거리) 를 미리 보여주는 풀스크린 모달.
/// "안내 시작" 누르면 onStartNavigation, 닫기 누르면 onCancel 콜백.
/// 호출 측(ARNavigationViewController) 이 dismiss + logic.startNavigation/logic.cancelRouteOverview 위임.
final class RouteOverviewViewController: UIViewController {

    var onStartNavigation: (() -> Void)?
    var onCancel: (() -> Void)?

    private let items: [RouteOverviewItem]
    private let totalDistanceMeters: Double
    private let destinationName: String

    // UI
    private var dimView: UIView!
    private var sheetView: UIView!
    private var closeButton: UIButton!
    private var totalDistanceLabel: UILabel!
    private var totalDistanceSubLabel: UILabel!
    private var tableView: UITableView!
    private var startButton: UIButton!

    init(items: [RouteOverviewItem], totalDistanceMeters: Double, destinationName: String) {
        self.items = items
        self.totalDistanceMeters = totalDistanceMeters
        self.destinationName = destinationName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        setupDimView()
        setupSheetView()
        setupCloseButton()
        setupTotalDistanceLabels()
        setupTableView()
        setupStartButton()
        applyConstraints()

        // 총 거리 라벨 채우기
        totalDistanceLabel.text = Self.formatMeters(totalDistanceMeters)
        totalDistanceSubLabel.text = "\(destinationName)까지"
    }

    // MARK: - Setup

    private func setupDimView() {
        dimView = UIView()
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dimView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimView)
    }

    private func setupSheetView() {
        sheetView = UIView()
        sheetView.backgroundColor = .systemBackground
        sheetView.layer.cornerRadius = 24
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.clipsToBounds = true
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)
    }

    private func setupCloseButton() {
        closeButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        closeButton.tintColor = .label
        closeButton.addTarget(self, action: #selector(onCloseTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(closeButton)
    }

    private func setupTotalDistanceLabels() {
        totalDistanceLabel = UILabel()
        totalDistanceLabel.font = .systemFont(ofSize: 36, weight: .bold)
        totalDistanceLabel.textColor = .label
        totalDistanceLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(totalDistanceLabel)

        totalDistanceSubLabel = UILabel()
        totalDistanceSubLabel.font = .systemFont(ofSize: 13, weight: .regular)
        totalDistanceSubLabel.textColor = .secondaryLabel
        totalDistanceSubLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(totalDistanceSubLabel)
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.dataSource = self
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.backgroundColor = .clear
        tableView.register(RouteOverviewStepCell.self, forCellReuseIdentifier: RouteOverviewStepCell.reuseId)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(tableView)
    }

    private func setupStartButton() {
        var config = UIButton.Configuration.filled()
        config.title = "안내 시작"
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        startButton = UIButton(configuration: config, primaryAction: nil)
        startButton.addTarget(self, action: #selector(onStartTapped), for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(startButton)
    }

    private func applyConstraints() {
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 상단 60pt 비우고 그 아래 풀폭 흰 컨테이너.
            sheetView.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            totalDistanceLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            totalDistanceLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            totalDistanceLabel.trailingAnchor.constraint(lessThanOrEqualTo: sheetView.trailingAnchor, constant: -20),

            totalDistanceSubLabel.topAnchor.constraint(equalTo: totalDistanceLabel.bottomAnchor, constant: 2),
            totalDistanceSubLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            totalDistanceSubLabel.trailingAnchor.constraint(lessThanOrEqualTo: sheetView.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(equalTo: totalDistanceSubLabel.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -12),

            startButton.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            startButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -20),
            startButton.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            startButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    // MARK: - Actions

    @objc private func onCloseTapped() { onCancel?() }
    @objc private func onStartTapped() { onStartNavigation?() }

    // MARK: - 거리 포맷

    /// <1m → "0m" (총 거리), <1000m → "Nm", ≥1000m → "X.Xkm".
    static func formatMeters(_ meters: Double) -> String {
        if meters < 1.0 { return "0m" }
        if meters < 1000.0 { return "\(Int(meters.rounded()))m" }
        let km = meters / 1000.0
        return String(format: "%.1fkm", km)
    }

    /// 셀(step row) 거리 포맷. 0<m<1 인 경우 "1m" 으로 끌어올림. 0 은 "0m".
    static func formatStepMeters(_ meters: Double) -> String {
        if meters <= 0 { return "0m" }
        if meters < 1.0 { return "1m" }
        if meters < 1000.0 { return "\(Int(meters.rounded()))m" }
        let km = meters / 1000.0
        return String(format: "%.1fkm", km)
    }

    /// NavigationActionKind → 한국어 표시 텍스트. 서버 instruction 을 무시하고 항상 이 매핑 사용.
    /// 양쪽 동기화 필수: ARNavigationLogic.fallbackInstructionText 와 1:1 동일 매핑 유지할 것.
    static func koreanInstruction(for action: NavigationActionKind) -> String {
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
}

// MARK: - UITableViewDataSource

extension RouteOverviewViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: RouteOverviewStepCell.reuseId, for: indexPath)
        guard let stepCell = cell as? RouteOverviewStepCell else { return cell }
        stepCell.configure(item: items[indexPath.row])
        return stepCell
    }
}

// MARK: - RouteOverviewStepCell

final class RouteOverviewStepCell: UITableViewCell {
    static let reuseId = "RouteOverviewStepCell"

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let distanceLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        // slight 회전 등 transform 잔존 방지 + 이미지/색상/라벨 상태 초기화.
        iconView.transform = .identity
        iconView.image = nil
        iconView.tintColor = nil
        iconContainer.backgroundColor = .systemGray6
        titleLabel.text = nil
        distanceLabel.text = nil
        distanceLabel.isHidden = false
    }

    private func setupSubviews() {
        // 동그란 테두리 컨테이너 — SVG asset (full-bleed) / SF Symbol (배경 회색) 모두 수용.
        iconContainer.backgroundColor = .systemGray6
        iconContainer.layer.cornerRadius = 16
        iconContainer.clipsToBounds = true
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconContainer)

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        distanceLabel.font = .systemFont(ofSize: 14, weight: .medium)
        distanceLabel.textColor = .secondaryLabel
        distanceLabel.textAlignment = .right
        distanceLabel.setContentHuggingPriority(.required, for: .horizontal)
        distanceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        distanceLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(distanceLabel)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 32),
            iconContainer.heightAnchor.constraint(equalToConstant: 32),

            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: distanceLabel.leadingAnchor, constant: -8),

            distanceLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            distanceLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func configure(item: RouteOverviewItem) {
        // 텍스트: origin/destination 은 instruction (현재 위치 / 목적지명) 그대로.
        // step 은 ARNavigationLogic 에서 POI/계단 문맥 합성한 instruction 우선,
        // 빈 문자열일 때만 action 기반 한국어 fallback.
        switch item.kind {
        case .origin, .destination:
            titleLabel.text = item.instruction
        case .step:
            let text = item.instruction.trimmingCharacters(in: .whitespaces)
            titleLabel.text = text.isEmpty
                ? RouteOverviewViewController.koreanInstruction(for: item.action)
                : text
        }

        // 아이콘: asset (SVG) / SF Symbol 분기.
        let resource = Self.iconResource(for: item)
        switch resource {
        case .asset(let name, let rotation):
            if let image = UIImage(named: name) {
                iconView.image = image
                iconView.tintColor = nil
                // slight 회전(±45°)은 turnLeft/turnRight 자산을 회전시켜 표현.
                iconView.transform = (rotation == 0) ? .identity : CGAffineTransform(rotationAngle: rotation)
                // SVG 자산은 자체 검은 배경을 포함하므로 컨테이너 배경 투명화 (자산이 컨테이너 가득 채움).
                iconContainer.backgroundColor = .clear
            } else {
                // 자산 로드 실패 시 SF Symbol 로 강등.
                applyFallbackSymbol(for: item)
            }
        case .symbol(let name, let tint):
            let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            iconView.image = UIImage(systemName: name, withConfiguration: config)
            iconView.tintColor = tint
            iconView.transform = .identity
            iconContainer.backgroundColor = .systemGray6
        }

        switch item.kind {
        case .origin, .destination:
            distanceLabel.isHidden = true
            distanceLabel.text = nil
        case .step:
            distanceLabel.isHidden = false
            distanceLabel.text = RouteOverviewViewController.formatStepMeters(item.distanceMeters)
        }
    }

    /// SVG 자산 로드 실패 시 SF Symbol 로 강등. straight/turnLeft/turnRight/slight/uturn/stairs/elevator 모두 의미 있는 fallback.
    private func applyFallbackSymbol(for item: RouteOverviewItem) {
        var rotation: CGFloat = 0
        let symbolName: String = {
            guard item.kind == .step else { return "circle.fill" }
            switch item.action {
            case .straight: return "arrow.up"
            case .turnLeft: return "arrow.turn.up.left"
            case .turnRight: return "arrow.turn.up.right"
            case .turnSlightLeft:
                rotation = .pi / 4
                return "arrow.turn.up.left"
            case .turnSlightRight:
                rotation = -.pi / 4
                return "arrow.turn.up.right"
            case .uturn: return "arrow.uturn.up"
            case .stairsUp, .stairsDown: return "figure.stairs"
            case .elevator: return "arrow.up.arrow.down.square"
            default: return "circle.fill"
            }
        }()
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        iconView.image = UIImage(systemName: symbolName, withConfiguration: config)
        iconView.tintColor = .label
        iconView.transform = (rotation == 0) ? .identity : CGAffineTransform(rotationAngle: rotation)
        iconContainer.backgroundColor = .systemGray6
    }

    /// 아이콘 리소스 종류 — SVG asset 우선, 없으면 SF Symbol + tint.
    private enum IconResource {
        case asset(name: String, rotation: CGFloat = 0)
        case symbol(name: String, tint: UIColor)
    }

    /// kind + action → 아이콘 리소스. SVG 등록된 항목(직진/좌회전/우회전) 만 .asset, 나머지는 SF Symbol.
    private static func iconResource(for item: RouteOverviewItem) -> IconResource {
        switch item.kind {
        case .origin:
            return .symbol(name: "mappin.circle.fill", tint: .systemGreen)
        case .destination:
            return .symbol(name: sfSymbolName(preferred: "flag.checkered.circle.fill", fallback: "flag.fill"), tint: .systemRed)
        case .step:
            switch item.action {
            case .straight:
                return .asset(name: "icNavStraight")
            case .turnLeft:
                return .asset(name: "icNavTurnLeft")
            case .turnRight:
                return .asset(name: "icNavTurnRight")
            case .turnSlightLeft:
                return .asset(name: "icNavTurnLeft", rotation: .pi / 4)
            case .turnSlightRight:
                return .asset(name: "icNavTurnRight", rotation: -.pi / 4)
            case .uturn:
                return .asset(name: "icNavUturn")
            case .stairsUp, .stairsDown:
                return .asset(name: "icNavStairs")
            case .elevator:
                return .asset(name: "icNavElevator")
            case .arrive:
                return .symbol(name: sfSymbolName(preferred: "flag.checkered.circle.fill", fallback: "flag.fill"), tint: .systemRed)
            case .unknown:
                return .symbol(name: "circle.fill", tint: .secondaryLabel)
            }
        }
    }

    /// preferred symbol 이 현재 iOS 버전에 존재하면 그것, 아니면 fallback.
    private static func sfSymbolName(preferred: String, fallback: String) -> String {
        if UIImage(systemName: preferred) != nil { return preferred }
        return fallback
    }
}
