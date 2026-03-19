import UIKit

class POISelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {

    private let buildingId: String
    private let buildingName: String

    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let emptyLabel = UILabel()

    private var allPOIs: [PoiResponse] = []
    private var filteredPOIs: [PoiResponse] = []
    private var searchWorkItem: DispatchWorkItem?

    init(buildingId: String, buildingName: String) {
        self.buildingId = buildingId
        self.buildingName = buildingName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "목적지 선택"
        view.backgroundColor = .systemBackground

        setupSearchBar()
        setupTableView()
        setupActivityIndicator()
        setupEmptyLabel()
        fetchPOIs()
    }

    private func setupSearchBar() {
        searchBar.placeholder = "목적지 검색 (예: 301호)"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

    // MARK: - 데이터 로드

    private func fetchPOIs() {
        activityIndicator.startAnimating()
        tableView.isHidden = true
        emptyLabel.isHidden = true

        NetworkManager.shared.fetchPOIs(buildingId: buildingId) { [weak self] result in
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
        alert.addAction(UIAlertAction(title: "다시 시도", style: .default) { [weak self] _ in
            self?.fetchPOIs()
        })
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
            NetworkManager.shared.searchPOIs(buildingId: self.buildingId, query: trimmed) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let pois):
                        self.filteredPOIs = pois
                        self.emptyLabel.text = "'\(trimmed)' 검색 결과가 없습니다."
                        self.emptyLabel.isHidden = !pois.isEmpty
                        self.tableView.reloadData()
                    case .failure:
                        // 서버 검색 실패 시 로컬 필터링 fallback
                        self.filteredPOIs = self.allPOIs.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                        self.emptyLabel.text = "'\(trimmed)' 검색 결과가 없습니다."
                        self.emptyLabel.isHidden = !self.filteredPOIs.isEmpty
                        self.tableView.reloadData()
                    }
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
        // 층별로 그룹핑
        let floors = Set(filteredPOIs.compactMap { $0.floorLevel })
        return max(floors.count, 1)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        poisForSection(section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let floors = sortedFloors()
        guard section < floors.count else { return nil }
        let level = floors[section]
        return "\(level)층"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "POICell", for: indexPath)
        let poi = poisForSection(indexPath.section)[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = poi.name
        config.image = iconForCategory(poi.category)
        if let cat = poi.category {
            config.secondaryText = categoryDisplayName(cat)
        }
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
            arVC.buildingId = self.buildingId
            arVC.destinationName = poi.name
            arVC.modalPresentationStyle = .fullScreen
            self.present(arVC, animated: true)
        })
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - 헬퍼

    private func sortedFloors() -> [Int] {
        let floors = Set(filteredPOIs.compactMap { $0.floorLevel })
        return floors.sorted()
    }

    private func poisForSection(_ section: Int) -> [PoiResponse] {
        let floors = sortedFloors()
        guard section < floors.count else { return filteredPOIs }
        let level = floors[section]
        return filteredPOIs.filter { $0.floorLevel == level }
    }

    private func iconForCategory(_ category: String?) -> UIImage? {
        switch category {
        case "CLASSROOM": return UIImage(systemName: "book")
        case "OFFICE": return UIImage(systemName: "person.crop.square")
        case "RESTROOM": return UIImage(systemName: "toilet")
        case "EXIT": return UIImage(systemName: "door.left.hand.open")
        case "ELEVATOR": return UIImage(systemName: "arrow.up.arrow.down")
        case "STAIRCASE": return UIImage(systemName: "stairs")
        default: return UIImage(systemName: "mappin")
        }
    }

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "CLASSROOM": return "강의실"
        case "OFFICE": return "사무실"
        case "RESTROOM": return "화장실"
        case "EXIT": return "출입구"
        case "ELEVATOR": return "엘리베이터"
        case "STAIRCASE": return "계단"
        case "OTHER": return "기타"
        default: return category
        }
    }
}
