import UIKit
import NMapsMap

class MapViewController: UIViewController {

    // MARK: - UI

    private let mapView = NMFMapView()
    private let searchContainerView = UIView()
    private let searchBar = UISearchBar()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let searchResultsTableView = UITableView()
    private let infoCardView = UIView()
    private let infoCardNameLabel = UILabel()
    private let infoCardSubtitleLabel = UILabel()
    private let infoCardButton = UIButton(type: .system)

    // MARK: - Constraints

    private var infoCardBottomConstraint: NSLayoutConstraint!
    private var searchResultsHeightConstraint: NSLayoutConstraint!

    // MARK: - State

    private var buildings: [BuildingResponse] = []
    private var filteredBuildings: [BuildingResponse] = []
    private var markers: [NMFMarker] = []
    private var selectedBuilding: BuildingResponse?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupMap()
        setupSearchBar()
        setupSearchResultsTable()
        setupInfoCard()
        fetchBuildings()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Setup

    private func setupMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.touchDelegate = self
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupSearchBar() {
        searchContainerView.backgroundColor = .systemBackground
        searchContainerView.layer.cornerRadius = 12
        searchContainerView.layer.shadowColor = UIColor.black.cgColor
        searchContainerView.layer.shadowOpacity = 0.12
        searchContainerView.layer.shadowOffset = CGSize(width: 0, height: 2)
        searchContainerView.layer.shadowRadius = 6
        searchContainerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchContainerView)

        searchBar.placeholder = "건물 검색"
        searchBar.delegate = self
        searchBar.backgroundImage = UIImage()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchContainerView.addSubview(searchBar)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            searchContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            searchContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            searchBar.topAnchor.constraint(equalTo: searchContainerView.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: searchContainerView.leadingAnchor, constant: 4),
            searchBar.trailingAnchor.constraint(equalTo: searchContainerView.trailingAnchor, constant: -4),
            searchBar.bottomAnchor.constraint(equalTo: searchContainerView.bottomAnchor),

            activityIndicator.centerYAnchor.constraint(equalTo: searchContainerView.centerYAnchor),
            activityIndicator.trailingAnchor.constraint(equalTo: searchContainerView.trailingAnchor, constant: -16),
        ])
    }

    private func setupSearchResultsTable() {
        searchResultsTableView.delegate = self
        searchResultsTableView.dataSource = self
        searchResultsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "SearchResultCell")
        searchResultsTableView.layer.cornerRadius = 12
        searchResultsTableView.layer.shadowColor = UIColor.black.cgColor
        searchResultsTableView.layer.shadowOpacity = 0.12
        searchResultsTableView.layer.shadowOffset = CGSize(width: 0, height: 2)
        searchResultsTableView.layer.shadowRadius = 6
        searchResultsTableView.isHidden = true
        searchResultsTableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchResultsTableView)

        searchResultsHeightConstraint = searchResultsTableView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchResultsTableView.topAnchor.constraint(equalTo: searchContainerView.bottomAnchor, constant: 4),
            searchResultsTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchResultsTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            searchResultsHeightConstraint,
        ])
    }

    private func setupInfoCard() {
        infoCardView.backgroundColor = .systemBackground
        infoCardView.layer.cornerRadius = 20
        infoCardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        infoCardView.layer.shadowColor = UIColor.black.cgColor
        infoCardView.layer.shadowOpacity = 0.15
        infoCardView.layer.shadowOffset = CGSize(width: 0, height: -2)
        infoCardView.layer.shadowRadius = 8
        infoCardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoCardView)

        infoCardBottomConstraint = infoCardView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 220)
        NSLayoutConstraint.activate([
            infoCardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoCardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoCardBottomConstraint,
        ])

        let dragHandle = UIView()
        dragHandle.backgroundColor = .systemGray4
        dragHandle.layer.cornerRadius = 2.5
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        infoCardView.addSubview(dragHandle)

        infoCardNameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        infoCardNameLabel.translatesAutoresizingMaskIntoConstraints = false
        infoCardView.addSubview(infoCardNameLabel)

        infoCardSubtitleLabel.font = .systemFont(ofSize: 14)
        infoCardSubtitleLabel.textColor = .secondaryLabel
        infoCardSubtitleLabel.numberOfLines = 2
        infoCardSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        infoCardView.addSubview(infoCardSubtitleLabel)

        var config = UIButton.Configuration.filled()
        config.title = "목적지 선택"
        config.cornerStyle = .large
        infoCardButton.configuration = config
        infoCardButton.translatesAutoresizingMaskIntoConstraints = false
        infoCardButton.addTarget(self, action: #selector(infoCardButtonTapped), for: .touchUpInside)
        infoCardView.addSubview(infoCardButton)

        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: infoCardView.topAnchor, constant: 10),
            dragHandle.centerXAnchor.constraint(equalTo: infoCardView.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),

            infoCardNameLabel.topAnchor.constraint(equalTo: dragHandle.bottomAnchor, constant: 16),
            infoCardNameLabel.leadingAnchor.constraint(equalTo: infoCardView.leadingAnchor, constant: 20),
            infoCardNameLabel.trailingAnchor.constraint(equalTo: infoCardView.trailingAnchor, constant: -20),

            infoCardSubtitleLabel.topAnchor.constraint(equalTo: infoCardNameLabel.bottomAnchor, constant: 4),
            infoCardSubtitleLabel.leadingAnchor.constraint(equalTo: infoCardView.leadingAnchor, constant: 20),
            infoCardSubtitleLabel.trailingAnchor.constraint(equalTo: infoCardView.trailingAnchor, constant: -20),

            infoCardButton.topAnchor.constraint(equalTo: infoCardSubtitleLabel.bottomAnchor, constant: 20),
            infoCardButton.leadingAnchor.constraint(equalTo: infoCardView.leadingAnchor, constant: 20),
            infoCardButton.trailingAnchor.constraint(equalTo: infoCardView.trailingAnchor, constant: -20),
            infoCardButton.bottomAnchor.constraint(equalTo: infoCardView.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            infoCardButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    // MARK: - Data

    private func fetchBuildings() {
        activityIndicator.startAnimating()
        NetworkManager.shared.fetchBuildings { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activityIndicator.stopAnimating()
                if case .success(let buildings) = result {
                    self.buildings = buildings
                    self.placeMarkers(for: buildings)
                    self.centerMapOnBuildings(buildings)
                }
            }
        }
    }

    private func placeMarkers(for buildings: [BuildingResponse]) {
        markers.forEach { $0.mapView = nil }
        markers.removeAll()

        for building in buildings {
            guard let lat = building.latitude, let lng = building.longitude else { continue }
            let marker = NMFMarker(position: NMGLatLng(lat: lat, lng: lng))
            marker.captionText = building.name
            marker.captionAligns = [NMFAlignType.top]
            marker.mapView = mapView
            marker.touchHandler = { [weak self] _ in
                self?.showInfoCard(for: building)
                return true
            }
            markers.append(marker)
        }
    }

    private func centerMapOnBuildings(_ buildings: [BuildingResponse]) {
        let located = buildings.filter { $0.latitude != nil && $0.longitude != nil }
        guard !located.isEmpty else { return }

        let avgLat = located.compactMap { $0.latitude }.reduce(0, +) / Double(located.count)
        let avgLng = located.compactMap { $0.longitude }.reduce(0, +) / Double(located.count)

        let position = NMFCameraPosition(NMGLatLng(lat: avgLat, lng: avgLng), zoom: 16)
        let cameraUpdate = NMFCameraUpdate(position: position)
        cameraUpdate.animation = .easeIn
        mapView.moveCamera(cameraUpdate)
    }

    // MARK: - Info Card

    private func showInfoCard(for building: BuildingResponse) {
        selectedBuilding = building
        infoCardNameLabel.text = building.name

        var parts: [String] = []
        if let desc = building.description, !desc.isEmpty { parts.append(desc) }
        if let floors = building.floorCount { parts.append("\(floors)층") }
        infoCardSubtitleLabel.text = parts.joined(separator: " · ")

        infoCardBottomConstraint.constant = 0
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            self.view.layoutIfNeeded()
        }
    }

    private func hideInfoCard() {
        infoCardBottomConstraint.constant = 220
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        selectedBuilding = nil
    }

    @objc private func infoCardButtonTapped() {
        guard let building = selectedBuilding else { return }
        let poiVC = POISelectionViewController(building: building)
        navigationController?.pushViewController(poiVC, animated: true)
    }

    // MARK: - Search

    private func updateSearchResults(query: String) {
        filteredBuildings = query.isEmpty
            ? buildings
            : buildings.filter { $0.name.localizedCaseInsensitiveContains(query) }

        let rowHeight: CGFloat = 52
        let maxHeight: CGFloat = 240
        let height = min(CGFloat(filteredBuildings.count) * rowHeight, maxHeight)
        searchResultsHeightConstraint.constant = height
        searchResultsTableView.isHidden = filteredBuildings.isEmpty
        searchResultsTableView.reloadData()
        view.layoutIfNeeded()
    }

    private func dismissSearch() {
        searchBar.resignFirstResponder()
        searchBar.text = ""
        searchBar.setShowsCancelButton(false, animated: true)
        searchResultsTableView.isHidden = true
    }
}

// MARK: - UISearchBarDelegate

extension MapViewController: UISearchBarDelegate {
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
        hideInfoCard()
        updateSearchResults(query: "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        updateSearchResults(query: searchText.trimmingCharacters(in: .whitespaces))
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        dismissSearch()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - UITableViewDataSource, UITableViewDelegate

extension MapViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredBuildings.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SearchResultCell", for: indexPath)
        let building = filteredBuildings[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = building.name
        config.secondaryText = building.description
        config.image = UIImage(systemName: "building.2")
        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let building = filteredBuildings[indexPath.row]
        dismissSearch()
        if let lat = building.latitude, let lng = building.longitude {
            let position = NMFCameraPosition(NMGLatLng(lat: lat, lng: lng), zoom: 17)
            let cameraUpdate = NMFCameraUpdate(position: position)
            cameraUpdate.animation = .easeIn
            mapView.moveCamera(cameraUpdate)
        }
        showInfoCard(for: building)
    }
}

// MARK: - NMFMapViewTouchDelegate

extension MapViewController: NMFMapViewTouchDelegate {
    func mapView(_ mapView: NMFMapView, didTapMap latlng: NMGLatLng, point: CGPoint) {
        hideInfoCard()
        if searchBar.isFirstResponder { dismissSearch() }
    }
}
