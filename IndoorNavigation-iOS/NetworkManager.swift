import Foundation
import UIKit

// MARK: - Building / POI DTOs

struct BuildingResponse: Codable {
    let id: String
    let name: String
    let description: String?
    let latitude: Double?
    let longitude: Double?
    let status: String?
    let floorCount: Int?
    let passageCount: Int?
    let createdAt: String?
    let updatedAt: String?
}

struct PoiResponse: Codable {
    let nodeId: String
    let name: String
    let category: String?
    let floorLevel: Int?
    let floorName: String?
    let x: Double?
    let y: Double?
    let z: Double?
}

// MARK: - Localize / Pathfinding DTOs

struct LocalizeResponse: Codable {
    let pose: Pose?
    let confidence: Double?
    let mapId: String?
    let numMatches: Int?
    let matchedImageIndex: Int?
}

struct Pose: Codable {
    let x: Double?
    let y: Double?
    let z: Double?
    // 회전 쿼터니언 (AR 방향 정렬에 필요)
    let qx: Double?
    let qy: Double?
    let qz: Double?
    let qw: Double?
}

struct PathfindingRequest: Codable {
    let startFloorLevel: Int
    let startX: Double
    let startY: Double
    let startZ: Double
    let destinationName: String
    let preference: String?
}

struct PathfindingResponse: Codable {
    let totalDistance: Double?
    let estimatedTimeSeconds: Int?
    let steps: [PathStep]?
}

struct PathStep: Codable {
    let stepNumber: Int?
    let floorLevel: Int?
    let position: Position?
    let instruction: String?
}

struct Position: Codable {
    let x: Double
    let y: Double
    let z: Double
}

private struct ServerErrorBody: Codable {
    let status: Int?
    let error: String?
    let message: String?
    let path: String?
}

// MARK: - 로거

private func log(_ tag: String, _ items: Any...) {
    let body = items.map { "\($0)" }.joined(separator: " ")
    print("[\(tag)] \(body)")
}

// MARK: - API 통신 매니저

class NetworkManager {
    static let shared = NetworkManager()
    let baseURL = "http://218.150.183.198:8080/api/v1"

    // MARK: - 1. Localize

    func localize(buildingId: String, images: [UIImage], completion: @escaping (Result<LocalizeResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/localize") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (index, image) in images.enumerated() {
            guard let imageData = image.jpegData(compressionQuality: 0.5) else { continue }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"images\"; filename=\"image\(index).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        log("REQ", "POST", url.absoluteString)
        log("REQ", "이미지 \(images.count)장, 바디 크기: \(body.count) bytes")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(Self.networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(빈 응답)"

            log("RES", "HTTP \(statusCode)")
            log("RES", "바디:", responseBody)

            let data = data ?? Data()
            guard (200..<300).contains(statusCode) else {
                completion(.failure(Self.httpError(statusCode: statusCode, data: data)))
                return
            }
            do {
                let result = try JSONDecoder().decode(LocalizeResponse.self, from: data)
                log("RES", "파싱 성공:", result)
                completion(.success(result))
            } catch {
                log("ERR", "파싱 실패:", error)
                completion(.failure(Self.makeError("응답 파싱 실패\n\(responseBody)")))
            }
        }.resume()
    }

    // MARK: - 2. Pathfinding

    func findPath(buildingId: String, requestDto: PathfindingRequest, completion: @escaping (Result<PathfindingResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/pathfinding") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            let bodyData = try JSONEncoder().encode(requestDto)
            request.httpBody = bodyData
            log("REQ", "POST", url.absoluteString)
            log("REQ", "바디:", String(data: bodyData, encoding: .utf8) ?? "")
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(Self.networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(빈 응답)"

            log("RES", "HTTP \(statusCode)")
            log("RES", "바디:", responseBody)

            let data = data ?? Data()
            guard (200..<300).contains(statusCode) else {
                completion(.failure(Self.httpError(statusCode: statusCode, data: data)))
                return
            }
            do {
                let result = try JSONDecoder().decode(PathfindingResponse.self, from: data)
                log("RES", "파싱 성공:", result)
                completion(.success(result))
            } catch {
                log("ERR", "파싱 실패:", error)
                completion(.failure(Self.makeError("응답 파싱 실패\n\(responseBody)")))
            }
        }.resume()
    }

    // MARK: - 3. 건물 목록 조회

    func fetchBuildings(status: String? = "ACTIVE", completion: @escaping (Result<[BuildingResponse], Error>) -> Void) {
        var urlString = "\(baseURL)/buildings"
        if let status = status {
            urlString += "?status=\(status)"
        }
        guard let url = URL(string: urlString) else { return }

        log("REQ", "GET", url.absoluteString)

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(Self.networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let data = data ?? Data()
            log("RES", "HTTP \(statusCode)")

            guard (200..<300).contains(statusCode) else {
                completion(.failure(Self.httpError(statusCode: statusCode, data: data)))
                return
            }
            do {
                let result = try JSONDecoder().decode([BuildingResponse].self, from: data)
                log("RES", "건물 \(result.count)개 조회")
                completion(.success(result))
            } catch {
                log("ERR", "파싱 실패:", error)
                completion(.failure(Self.makeError("응답 파싱 실패")))
            }
        }.resume()
    }

    // MARK: - 4. POI 목록 조회

    func fetchPOIs(buildingId: String, completion: @escaping (Result<[PoiResponse], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/pois") else { return }

        log("REQ", "GET", url.absoluteString)

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(Self.networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let data = data ?? Data()
            log("RES", "HTTP \(statusCode)")

            guard (200..<300).contains(statusCode) else {
                completion(.failure(Self.httpError(statusCode: statusCode, data: data)))
                return
            }
            do {
                let result = try JSONDecoder().decode([PoiResponse].self, from: data)
                log("RES", "POI \(result.count)개 조회")
                completion(.success(result))
            } catch {
                log("ERR", "파싱 실패:", error)
                completion(.failure(Self.makeError("응답 파싱 실패")))
            }
        }.resume()
    }

    // MARK: - 5. POI 검색

    func searchPOIs(buildingId: String, query: String, completion: @escaping (Result<[PoiResponse], Error>) -> Void) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(baseURL)/buildings/\(buildingId)/pois/search?query=\(encoded)") else { return }

        log("REQ", "GET", url.absoluteString)

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                log("ERR", "네트워크 오류:", error)
                completion(.failure(Self.networkError(error)))
                return
            }
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let data = data ?? Data()
            log("RES", "HTTP \(statusCode)")

            guard (200..<300).contains(statusCode) else {
                completion(.failure(Self.httpError(statusCode: statusCode, data: data)))
                return
            }
            do {
                let result = try JSONDecoder().decode([PoiResponse].self, from: data)
                log("RES", "POI 검색 결과 \(result.count)개")
                completion(.success(result))
            } catch {
                log("ERR", "파싱 실패:", error)
                completion(.failure(Self.makeError("응답 파싱 실패")))
            }
        }.resume()
    }

    // MARK: - 에러 헬퍼

    private static func networkError(_ error: Error) -> Error {
        let msg = "[\(type(of: error))] \(error.localizedDescription)\n\((error as? URLError).map { "code: \($0.code.rawValue)" } ?? "")"
        return makeError(msg)
    }

    private static func httpError(statusCode: Int, data: Data) -> Error {
        let body = String(data: data, encoding: .utf8) ?? "(빈 응답)"
        return makeError("HTTP \(statusCode)\n\(body)")
    }

    private static func makeError(_ msg: String) -> Error {
        NSError(domain: "NetworkManager", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
