import UIKit

class FloorSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let building: BuildingResponse

    private let headerView = UIView()
    private let buildingNameLabel = UILabel()
    private let buildingInfoLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let emptyLabel = UILabel()

    private var floors: [FloorResponse] = []

    init(building: BuildingResponse) {
        self.building = building
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "현재 층 선택"
        view.backgroundColor = .systemBackground

        setupHeader()
        setupTableView()
        setupActivityIndicator()
        setupEmptyLabel()
        fetchFloors()
    }

    // MARK: - Setup

    private func setupHeader() {
        headerView.backgroundColor = .systemBackground
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        buildingNameLabel.text = building.name
        buildingNameLabel.font = .systemFont(ofSize: 22, weight: .bold)
        buildingNameLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(buildingNameLabel)

        buildingInfoLabel.text = "어디서 길찾기를 시작하시나요?"
        buildingInfoLabel.font = .systemFont(ofSize: 14)
        buildingInfoLabel.textColor = .secondaryLabel
        buildingInfoLabel.numberOfLines = 2
        buildingInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(buildingInfoLabel)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(separator)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            buildingNameLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            buildingNameLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            buildingNameLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),

            buildingInfoLabel.topAnchor.constraint(equalTo: buildingNameLabel.bottomAnchor, constant: 4),
            buildingInfoLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            buildingInfoLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: buildingInfoLabel.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FloorCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UnknownCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupActivityIndicator() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.text = "등록된 층 정보가 없습니다."
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .systemFont(ofSize: 16)
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Data

    private func fetchFloors() {
        activityIndicator.startAnimating()
        tableView.isHidden = true
        emptyLabel.isHidden = true

        NetworkManager.shared.fetchBuildingDetail(buildingId: building.buildingId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activityIndicator.stopAnimating()

                switch result {
                case .success(let detail):
                    let fetched = (detail.floors ?? []).sorted { $0.level > $1.level }
                    self.floors = fetched
                    self.tableView.isHidden = false
                    // 빈 배열이어도 Section 1 (모르겠음) 은 유지 → 사용자 진행 가능
                    self.emptyLabel.isHidden = !fetched.isEmpty
                    self.tableView.reloadData()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "오류", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "다시 시도", style: .default) { [weak self] _ in self?.fetchFloors() })
        alert.addAction(UIAlertAction(title: "닫기", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return floors.count
        case 1: return 1
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "층 선택"
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "FloorCell", for: indexPath)
            let floor = floors[indexPath.row]

            var config = cell.defaultContentConfiguration()
            config.text = floorDisplayName(floor)
            config.image = UIImage(systemName: "building.2")
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "UnknownCell", for: indexPath)

            var config = cell.defaultContentConfiguration()
            config.text = "모르겠어요"
            config.secondaryText = "스캔 결과로 자동 추정"
            config.image = UIImage(systemName: "questionmark.circle")
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            let floor = floors[indexPath.row]
            navigateToPOI(currentFloorId: floor.floorId)
        } else {
            navigateToPOI(currentFloorId: nil)
        }
    }

    // MARK: - Navigation

    private func navigateToPOI(currentFloorId: String?) {
        let poiVC = POISelectionViewController(building: building, userCurrentFloorId: currentFloorId)
        navigationController?.pushViewController(poiVC, animated: true)
    }

    // MARK: - Helpers

    private func floorDisplayName(_ floor: FloorResponse) -> String {
        let trimmed = floor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if floor.level > 0 { return "\(floor.level)F" }
        if floor.level == 0 { return "G" }
        return "B\(-floor.level)"
    }
}
