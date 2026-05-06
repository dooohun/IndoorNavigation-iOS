import UIKit

/// 5-1 (초기 정렬), 5-3 (재정렬) 공용 풀스크린 오버레이.
/// 반투명 검정 배경 + 큰 회전 아이콘 + 메인/서브 라벨로 회전을 유도한다.
final class HeadingAlignmentOverlayView: UIView {

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let mainLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subLabel: UILabel = {
        let l = UILabel()
        l.textColor = UIColor.white.withAlphaComponent(0.8)
        l.font = .systemFont(ofSize: 15, weight: .regular)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
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
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        isUserInteractionEnabled = true
        isHidden = true

        addSubview(iconView)
        addSubview(mainLabel)
        addSubview(subLabel)

        let safe = self.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: safe.centerYAnchor, constant: -40),
            iconView.widthAnchor.constraint(equalToConstant: 120),
            iconView.heightAnchor.constraint(equalToConstant: 120),

            mainLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 24),
            mainLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            mainLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),

            subLabel.topAnchor.constraint(equalTo: mainLabel.bottomAnchor, constant: 12),
            subLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            subLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Public API

    func show(direction: TurnDirection, angleDeg: Double, mode: AlignmentMode, animated: Bool = true) {
        // 아이콘 매핑
        let symbolName: String
        switch direction {
        case .left:  symbolName = "arrow.turn.up.left"
        case .right: symbolName = "arrow.turn.up.right"
        case .uTurn: symbolName = "arrow.uturn.up"
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: 120, weight: .regular)
        iconView.image = UIImage(systemName: symbolName, withConfiguration: cfg)

        let absAngle = abs(angleDeg)
        let isRight = angleDeg > 0
        let sideKR = isRight ? "오른쪽" : "왼쪽"

        // 메인 문구
        switch mode {
        case .initial:
            if absAngle >= 150 {
                mainLabel.text = "뒤를 돌아보세요"
            } else if absAngle >= 60 {
                mainLabel.text = "\(sideKR)으로 90° 회전하세요"
            } else {
                mainLabel.text = "\(sideKR)으로 살짝 돌아보세요"
            }
        case .reorient:
            mainLabel.text = "방향이 잘못되었습니다"
        }

        // 서브 문구
        switch mode {
        case .initial:
            subLabel.text = "회전 후 정면을 바라보면 안내가 시작됩니다"
        case .reorient:
            // 부호 컨벤션: angleDeg > 0 → 카메라가 목적지 우측(시계방향)으로 회전 필요라 가정.
            // 첫 빌드 후 디바이스에서 실제 회전 방향을 확인해 필요 시 부호 반전.
            let dirKR = isRight ? "시계방향" : "반시계방향"
            let degInt = Int(round(absAngle))
            subLabel.text = "\(dirKR) \(degInt)° 회전하여 정면을 바라봐 주세요\nAR 안내가 다시 시작됩니다"
        }

        if animated {
            self.alpha = 0
            self.isHidden = false
            UIView.animate(withDuration: 0.25) {
                self.alpha = 1
            }
        } else {
            self.alpha = 1
            self.isHidden = false
        }
    }

    func dismiss(animated: Bool = true) {
        guard !self.isHidden else { return }
        if animated {
            UIView.animate(withDuration: 0.3, animations: {
                self.alpha = 0
            }, completion: { _ in
                self.isHidden = true
            })
        } else {
            self.alpha = 0
            self.isHidden = true
        }
    }
}
