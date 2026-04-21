import UIKit

class POISelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {

    private let building: BuildingResponse

    private let headerView = UIView()
    private let buildingNameLabel = UILabel()
    private let buildingInfoLabel = UILabel()
    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let emptyLabel = UILabel()

    private var allPOIs: [PoiResponse] = []
    private var filteredPOIs: [PoiResponse] = []
    private var searchWorkItem: DispatchWorkItem?

    init(building: BuildingResponse) {
        self.building = building
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(buildingId: String, buildingName: String) {
        let building = BuildingResponse(
            id: buildingId, name: buildingName, description: nil,
            latitude: nil, longitude: nil, status: nil,
            floorCount: nil, passageCount: nil, createdAt: nil, updatedAt: nil
        )
        self.init(building: building)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "목적지 선택"
        view.backgroundColor = .systemBackground

        setupHeader()
        setupSearchBar()
        setupTableView()
        setupActivityIndicator()
        setupEmptyLabel()
        fetchPOIs()
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

        var infoParts: [String] = []
        if let desc = building.description, !desc.isEmpty { infoParts.append(desc) }
        if let floors = building.floorCount { infoParts.append("\(floors)층") }
        if let passages = building.passageCount { infoParts.append("통로 \(passages)개") }

        buildingInfoLabel.text = infoParts.joined(separator: " · ")
        buildingInfoLabel.font = .systemFont(ofSize: 14)
        buildingInfoLabel.textColor = .secondaryLabel
        buildingInfoLabel.numberOfLines = 2
        buildingInfoLabel.isHidden = infoParts.isEmpty
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

    private func setupSearchBar() {
        searchBar.placeholder = "목적지 검색 (예: 301호)"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "POICell")
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
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
        emptyLabel.text = "등록된 목적지가 없습니다."
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

    private func fetchPOIs() {
        activityIndicator.startAnimating()
        tableView.isHidden = true
        emptyLabel.isHidden = true

        NetworkManager.shared.fetchPOIs(buildingId: building.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activityIndicator.stopAnimating()

                switch result {
                case .success(let pois):
                    self.allPOIs = pois
                    self.filteredPOIs = pois
                    self.tableView.isHidden = false
                    self.emptyLabel.isHidden = !pois.isEmpty
                    self.tableView.reloadData()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "오류", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "다시 시도", style: .default) { [weak self] _ in self?.fetchPOIs() })
        alert.addAction(UIAlertAction(title: "닫기", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - UISearchBarDelegate

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchWorkItem?.cancel()

        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filteredPOIs = allPOIs
            emptyLabel.isHidden = !filteredPOIs.isEmpty
            tableView.reloadData()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NetworkManager.shared.searchPOIs(buildingId: self.building.id, query: trimmed) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let pois):
                        self.filteredPOIs = pois
                    case .failure:
                        self.filteredPOIs = self.allPOIs.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                    }
                    self.emptyLabel.text = "'\(trimmed)' 검색 결과가 없습니다."
                    self.emptyLabel.isHidden = !self.filteredPOIs.isEmpty
                    self.tableView.reloadData()
                }
            }
        }
        searchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        max(sortedFloors().count, 1)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        poisForSection(section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let floors = sortedFloors()
        guard section < floors.count else { return nil }
        return "\(floors[section])층"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "POICell", for: indexPath)
        let poi = poisForSection(indexPath.section)[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = poi.name
        config.image = iconForCategory(poi.category)
        if let cat = poi.category { config.secondaryText = categoryDisplayName(cat) }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let poi = poisForSection(indexPath.section)[indexPath.row]

        let alert = UIAlertController(
            title: poi.name,
            message: "이 목적지로 길찾기를 시작할까요?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "시작", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let arVC = ARNavigationViewController()
            arVC.buildingId = self.building.id
            arVC.destinationName = poi.name
            arVC.modalPresentationStyle = .fullScreen
            self.present(arVC, animated: true)
        })
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private func sortedFloors() -> [Int] {
        Set(filteredPOIs.compactMap { $0.floorLevel }).sorted()
    }

    private func poisForSection(_ section: Int) -> [PoiResponse] {
        let floors = sortedFloors()
        guard section < floors.count else { return filteredPOIs }
        return filteredPOIs.filter { $0.floorLevel == floors[section] }
    }

    private func iconForCategory(_ category: String?) -> UIImage? {
        switch category {
        case "CLASSROOM": return UIImage(systemName: "book")
        case "OFFICE":    return UIImage(systemName: "person.crop.square")
        case "RESTROOM":  return UIImage(systemName: "toilet")
        case "EXIT":      return UIImage(systemName: "door.left.hand.open")
        case "ELEVATOR":  return UIImage(systemName: "arrow.up.arrow.down")
        case "STAIRCASE": return UIImage(systemName: "stairs")
        default:          return UIImage(systemName: "mappin")
        }
    }

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "CLASSROOM": return "강의실"
        case "OFFICE":    return "사무실"
        case "RESTROOM":  return "화장실"
        case "EXIT":      return "출입구"
        case "ELEVATOR":  return "엘리베이터"
        case "STAIRCASE": return "계단"
        case "OTHER":     return "기타"
        default:          return category
        }
    }
}
