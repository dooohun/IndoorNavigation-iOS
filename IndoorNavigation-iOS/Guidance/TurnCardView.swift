import UIKit

/// 5-2 우상단 턴 카드. 다음 턴 거리 + 방향 + 액션 텍스트를 표시.
final class TurnCardView: UIView {

    // MARK: - 사이즈 상수
    static let cardWidth: CGFloat = 160
    static let cardHeight: CGFloat = 80
    static let trailingInset: CGFloat = 16
    static let topInset: CGFloat = 16

    // MARK: - 서브뷰
    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.tintColor = .black
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let distanceLabel: UILabel = {
        let l = UILabel()
        l.textColor = .darkText
        l.font = .systemFont(ofSize: 22, weight: .bold)
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let actionLabel: UILabel = {
        let l = UILabel()
        l.textColor = .darkGray
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let textStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.alignment = .trailing
        s.distribution = .fill
        s.spacing = 2
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.white.withAlphaComponent(0.95)
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0

        addSubview(iconView)
        addSubview(textStack)
        textStack.addArrangedSubview(distanceLabel)
        textStack.addArrangedSubview(actionLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            textStack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            textStack.leadingAnchor.constraint(greaterThanOrEqualTo: iconView.trailingAnchor, constant: 8),
        ])
    }

    // MARK: - Public API

    /// 카드 등장 또는 방향/거리 모두 갱신.
    func update(direction: TurnDirection, distanceMeters: Double) {
        let symbolName: String
        let actionText: String
        switch direction {
        case .left:
            symbolName = "arrow.turn.up.left"
            actionText = "후 좌회전"
        case .right:
            symbolName = "arrow.turn.up.right"
            actionText = "후 우회전"
        case .uTurn:
            symbolName = "arrow.uturn.up"
            actionText = "후 유턴"
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        iconView.image = UIImage(systemName: symbolName, withConfiguration: cfg)
        distanceLabel.text = formatDistance(distanceMeters)
        actionLabel.text = actionText
    }

    /// 거리만 갱신 (매 frame 콜백용).
    func updateDistance(_ meters: Double) {
        distanceLabel.text = formatDistance(meters)
    }

    /// 우측 바깥 → 제자리로 슬라이드 인 (0.25초).
    func showSlideIn(in parentView: UIView) {
        let offset = TurnCardView.cardWidth + TurnCardView.trailingInset
        self.transform = CGAffineTransform(translationX: offset, y: 0)
        self.alpha = 0
        self.isHidden = false
        UIView.animate(withDuration: 0.25,
                       delay: 0,
                       options: [.curveEaseOut],
                       animations: {
            self.transform = .identity
            self.alpha = 1
        })
    }

    /// 우측 바깥으로 슬라이드 아웃 (0.2초).
    func hideSlideOut() {
        guard !self.isHidden else { return }
        let offset = TurnCardView.cardWidth + TurnCardView.trailingInset
        UIView.animate(withDuration: 0.2,
                       delay: 0,
                       options: [.curveEaseIn],
                       animations: {
            self.transform = CGAffineTransform(translationX: offset, y: 0)
            self.alpha = 0
        }, completion: { _ in
            self.isHidden = true
            self.transform = .identity
        })
    }

    // MARK: - 거리 포맷

    /// 10m 미만은 m 단위 정수, 10m 이상은 5m 단위 반올림.
    private func formatDistance(_ m: Double) -> String {
        if m < 10 {
            return "\(Int(round(m))) m"
        }
        let rounded = Int(round(m / 5.0) * 5.0)
        return "\(rounded) m"
    }
}
