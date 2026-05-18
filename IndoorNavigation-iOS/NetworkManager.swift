import Foundation
import UIKit

// MARK: - 에러 모델

private struct V1ErrorResponse: Codable {
    let code: String
    let message: String
    let detail: String?
}

private struct HTTPValidationError: Codable {
    let detail: [ValidationErrorItem]?
}

private struct ValidationErrorItem: Codable {
    let loc: [String]?
    let msg: String?
    let type: String?
}

// MARK: - 로거

private func log(_ tag: String, _ items: Any...) {
    let body = items.map { "\($0)" }.joined(separator: " ")
    print("[\(tag)] \(body)")
}

// MARK: - API 통신 매니저

class NetworkManager {
    static let shared = NetworkManager()
    let baseURL = "http://218.150.183.198:8000/api/v1"
    let slamBaseURL = "http://218.150.183.198:8000/api/slam/v3"

    // MARK: - Buildings

    func fetchBuildings(status: String? = "ACTIVE",
                        completion: @escaping (Result<[BuildingResponse], Error>) -> Void) {
        var urlString = "\(baseURL)/buildings"
        if let status = status {
            urlString += "?status=\(status)"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        log("REQ", "GET", url.absoluteString)
        Self.performJSON(request) { (result: Result<[BuildingResponse], Error>) in
            if case .success(let arr) = result { log("RES", "건물 \(arr.count)개 조회") }
            completion(result)
        }
    }

    func fetchBuildingDetail(buildingId: String,
                             completion: @escaping (Result<BuildingDetailResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        log("REQ", "GET", url.absoluteString)
        Self.performJSON(request, completion: completion)
    }

    // MARK: - Floors

    /// `GET /buildings/{bid}/floors/{fid}/map.png` — 층 지도 PNG 바이너리.
    /// `widthPx` 지정 시 서버측 다운스케일 결과를 받음.
    func fetchFloorMapImage(floorId: String,
                            widthPx: Int? = nil,
                            completion: @escaping (Result<Data, Error>) -> Void) {
        var urlString = "\(baseURL)/floors/\(floorId)/map.png"
        if let widthPx = widthPx {
            urlString += "?width_px=\(widthPx)"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        log("REQ", "GET", url.absoluteString)
        Self.performData(request, completion: completion)
    }

    /// `GET /floors/{fid}/map` — 층 지도 메타(JSON) + GeoJSON polygon + nodes/edges.
    /// - Parameters:
    ///   - areaId: 신서버 area 스코프(층 내 sub-area) 식별자. 지정 시 query 로 첨부.
    ///   - ifNoneMatch: ETag 조건부 GET. 지정 시 If-None-Match 헤더 첨부 (서버 304 응답 시 캐시 사용).
    func fetchFloorMap(floorId: String,
                       areaId: String? = nil,
                       ifNoneMatch: String? = nil,
                       completion: @escaping (Result<FloorMapResponse, Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/floors/\(floorId)/map")
        if let areaId, !areaId.isEmpty {
            components?.queryItems = [URLQueryItem(name: "areaId", value: areaId)]
        }
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        log("REQ", "GET", url.absoluteString)
        Self.performJSON(request, completion: completion)
    }

    // MARK: - Pathfinding & Routing

    func pathfinding(buildingId: String,
                     request requestDto: PathfindingRequest,
                     completion: @escaping (Result<PathfindingResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/pathfinding") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONEncoder().encode(requestDto)
            log("REQ", "POST", url.absoluteString)
        } catch {
            completion(.failure(error))
            return
        }

        Self.performJSON(request) { (result: Result<PathfindingResponse, Error>) in
            if case .success(let resp) = result {
                let transitionCount = resp.floorTransitions?.count ?? 0
                log("RES", "pathfinding: steps \(resp.steps.count), transitions \(transitionCount), total \(String(format: "%.1f", resp.totalDistance))m")
            }
            completion(result)
        }
    }

    /// 첫 호출 시 서버 cache build 가 30~60초 걸릴 수 있어 timeout 90s.
    func featurePointsLookup(buildingId: String,
                             request requestDto: FeatureLookupRequest,
                             completion: @escaping (Result<FeatureLookupResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/feature-points/lookup") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        do {
            request.httpBody = try JSONEncoder().encode(requestDto)
            log("REQ", "POST lookup queries=\(requestDto.queries.count)")
        } catch {
            completion(.failure(error))
            return
        }

        Self.performJSON(request) { (result: Result<FeatureLookupResponse, Error>) in
            if case .success(let resp) = result {
                log("RES", "lookup: keyframes \(resp.keyframes.count), \(resp.stats.byteSize / 1024)KB")
            }
            completion(result)
        }
    }

    func findRouteByCoordinates(buildingId: String,
                                floorId: String,
                                request requestDto: FloorCoordinateRouteRequest,
                                completion: @escaping (Result<FloorCoordinateRouteResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/floors/\(floorId)/routes/coordinates") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONEncoder().encode(requestDto)
            log("REQ", "POST", url.absoluteString)
        } catch {
            completion(.failure(error))
            return
        }

        Self.performJSON(request, completion: completion)
    }

    // MARK: - POIs

    func fetchPOIs(buildingId: String,
                   completion: @escaping (Result<[POIResponse], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/pois") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        log("REQ", "GET", url.absoluteString)
        Self.performJSON(request) { (result: Result<[POIResponse], Error>) in
            if case .success(let arr) = result { log("RES", "POI \(arr.count)개 조회") }
            completion(result)
        }
    }

    func searchPOIs(buildingId: String,
                    query: String,
                    completion: @escaping (Result<[POIResponse], Error>) -> Void) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/pois/search?query=\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        log("REQ", "GET", url.absoluteString)
        Self.performJSON(request) { (result: Result<[POIResponse], Error>) in
            if case .success(let arr) = result { log("RES", "POI 검색 결과 \(arr.count)개") }
            completion(result)
        }
    }

    // MARK: - SLAM Localize V3

    /// `POST /api/slam/v3/localize` — multipart 이미지 업로드.
    /// 서버에서 SuperPoint 추출 + LightGlue 매칭 + PnP 까지 수행 — 5장 처리에 30초+ 걸려 timeout 90s.
    ///
    /// 신서버 스펙: `building_id` / `map_id` / `floor_id` 는 query parameter, multipart 본문에는 images + depths 만.
    /// `depths` 는 LiDAR sceneDepth FP32 raw bytes (옵셔널 — 서버는 곧 optional 로 변경 예정).
    /// `floorId` 는 신서버에서 uuid 문자열로 전달 (이전엔 floorLevel Int 였음).
    func localizeV3(buildingId: String,
                    images: [UIImage],
                    depths: [Data]? = nil,
                    mapId: String? = nil,
                    floorId: String? = nil,
                    completion: @escaping (Result<SLAMLocalizeResponse, Error>) -> Void) {
        var components = URLComponents(string: "\(slamBaseURL)/localize")
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "building_id", value: buildingId)]
        if let mapId, !mapId.isEmpty {
            queryItems.append(URLQueryItem(name: "map_id", value: mapId))
        }
        if let floorId, !floorId.isEmpty {
            queryItems.append(URLQueryItem(name: "floor_id", value: floorId))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // 다운샘플링: 원본 1920×1440 → longer side 960. 업로드 75% 감소 + 서버 SP 처리 빠름.
        for (index, image) in images.enumerated() {
            let resized = Self.resizeForLocalize(image, longerSide: 960)
            guard let imageData = resized.jpegData(compressionQuality: 0.9) else { continue }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"images\"; filename=\"image\(index).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
        }

        // depth 첨부 — LiDAR 미지원 단말이면 nil 이라 첨부 X (서버는 optional 처리 예정).
        if let depths, !depths.isEmpty {
            for (index, depthData) in depths.enumerated() {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"depths\"; filename=\"depth\(index).bin\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(depthData)
                body.append("\r\n".data(using: .utf8)!)
            }
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        log("REQ", "POST localize images=\(images.count) depths=\(depths?.count ?? 0) floorId=\(floorId ?? "ANY") mapId=\(mapId ?? "ANY") body=\(body.count / 1024)KB")

        Self.performJSON(request) { (result: Result<SLAMLocalizeResponse, Error>) in
            if case .success(let resp) = result {
                log("RES", "localize: confidence=\(String(format: "%.2f", resp.confidence)) floor=\(resp.floorLevel.map(String.init) ?? "?") matches=\(resp.numMatches ?? 0) areaId=\(resp.areaId ?? "?")")
            }
            completion(result)
        }
    }

    // MARK: - 공통 응답 처리

    /// JSON 응답 디코딩 공통 처리. status guard → V1Error/Validation 디코드 → 본문 디코드.
    private static func performJSON<T: Decodable>(
        _ request: URLRequest,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let data = data ?? Data()

            guard (200..<300).contains(statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "(빈 응답)"
                log("RES", "HTTP \(statusCode) url=\(request.url?.absoluteString ?? "?")\n\(body)")
                completion(.failure(httpError(statusCode: statusCode, data: data)))
                return
            }
            do {
                let result = try JSONDecoder().decode(T.self, from: data)
                completion(.success(result))
            } catch {
                log("ERR", "파싱 실패:", error)
                let body = String(data: data, encoding: .utf8) ?? "(빈 응답)"
                completion(.failure(makeError("응답 파싱 실패\n\(body)")))
            }
        }.resume()
    }

    /// 바이너리 응답(이미지 등) 공통 처리.
    private static func performData(
        _ request: URLRequest,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let data = data ?? Data()
            log("RES", "HTTP \(statusCode), \(data.count) bytes")

            guard (200..<300).contains(statusCode) else {
                completion(.failure(httpError(statusCode: statusCode, data: data)))
                return
            }
            completion(.success(data))
        }.resume()
    }

    // MARK: - 이미지 다운샘플링 헬퍼

    /// V3 localize multipart 업로드 전 이미지 다운샘플링. 비율 유지, longer side 를 `longerSide` 로 맞춤.
    private static func resizeForLocalize(_ image: UIImage, longerSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longerSide else { return image }
        let scale = longerSide / longest
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - 에러 헬퍼

    private static func networkError(_ error: Error) -> Error {
        let msg = "[\(type(of: error))] \(error.localizedDescription)\n\((error as? URLError).map { "code: \($0.code.rawValue)" } ?? "")"
        return makeError(msg)
    }

    private static func httpError(statusCode: Int, data: Data) -> Error {
        if let v1 = try? JSONDecoder().decode(V1ErrorResponse.self, from: data) {
            return makeError("HTTP \(statusCode) [\(v1.code)] \(v1.message)\(v1.detail.map { "\n\($0)" } ?? "")")
        }
        if let v = try? JSONDecoder().decode(HTTPValidationError.self, from: data),
           let items = v.detail, !items.isEmpty {
            let lines = items.map { "- \($0.loc?.joined(separator: ".") ?? "") \($0.msg ?? "")" }.joined(separator: "\n")
            return makeError("HTTP \(statusCode) Validation\n\(lines)")
        }
        let body = String(data: data, encoding: .utf8) ?? "(빈 응답)"
        return makeError("HTTP \(statusCode)\n\(body)")
    }

    private static func makeError(_ msg: String) -> Error {
        NSError(domain: "NetworkManager", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
