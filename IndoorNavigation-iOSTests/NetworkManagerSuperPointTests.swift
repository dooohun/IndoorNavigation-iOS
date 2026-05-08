//
//  NetworkManagerSuperPointTests.swift
//  IndoorNavigation-iOSTests
//
//  Phase 8 B2 — NetworkManager 신규 3 메서드(localizeV3 / pathfinding / featurePointsLookup)
//  멀티파트 / JSON body 빌드 + 응답 디코드 + 에러 전파 단위 테스트.
//
//  Mocking 전략:
//  - URLProtocol 서브클래스(MockURLProtocol)로 모든 요청 가로채서 미리 등록한 (Data, HTTPURLResponse) 응답 주입.
//  - URLSessionConfiguration.ephemeral + protocolClasses = [MockURLProtocol.self] → 커스텀 URLSession 생성.
//  - NetworkManager.session 프로퍼티에 주입(DI) — 기존 동작 영향 없음.
//

import Testing
import Foundation
import UIKit
@testable import IndoorNavigation_iOS

// MARK: - MockURLProtocol

/// 테스트용 URLProtocol. 마지막 요청을 캡처하고 미리 등록한 응답을 반환한다.
/// Swift 5 모드 — `nonisolated(unsafe)` 어노테이션 불필요. static var 그대로.
final class MockURLProtocol: URLProtocol {

    /// 다음 요청에 반환할 응답. (응답 데이터, 상태 코드, 헤더).
    static var stubResponse: (data: Data, statusCode: Int, headers: [String: String])?
    /// 캡처된 마지막 요청.
    static var capturedRequest: URLRequest?
    /// 캡처된 본문 (multipart 는 httpBodyStream 에 들어와서 별도 read 필요).
    static var capturedBody: Data?

    static func reset() {
        stubResponse = nil
        capturedRequest = nil
        capturedBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // 요청 메타 캡처
        MockURLProtocol.capturedRequest = request

        // 본문 캡처: URLSession 이 multipart body 를 httpBodyStream 으로 변환해 넣음.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 16 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            MockURLProtocol.capturedBody = data
        } else if let body = request.httpBody {
            MockURLProtocol.capturedBody = body
        } else {
            MockURLProtocol.capturedBody = nil
        }

        // 응답 주입
        guard let stub = MockURLProtocol.stubResponse,
              let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: stub.statusCode,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { /* no-op */ }
}

// MARK: - 테스트 구조체

struct NetworkManagerSuperPointTests {

    // MARK: - Helpers

    /// 모킹된 URLSession 이 주입된 NetworkManager 인스턴스.
    /// shared 싱글턴 오염 방지를 위해 새 인스턴스 생성.
    private func configuredManager() -> NetworkManager {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let manager = NetworkManager()
        manager.session = session
        return manager
    }

    /// 작은 컬러 UIImage. 테스트용 multipart 이미지.
    private func makeTestImage(width: Int = 4, height: Int = 4, color: UIColor = .red) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// completion handler 기반 메서드를 async 컨텍스트로 전환.
    private func awaitResult<T>(_ run: (@escaping (Result<T, Error>) -> Void) -> Void) async -> Result<T, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
            run { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - 1) localizeV3 — multipart 요청 빌드

    @Test("localizeV3: URL/메서드/Content-Type/multipart body 구성 확인")
    func localizeV3_buildsMultipartRequest() async throws {
        let manager = configuredManager()

        // 200 응답 stub — 본문은 디코드 가능한 최소 JSON
        let stubJSON = """
        {
          "buildingId": "bld-test",
          "mapId": "scan-x",
          "pose": {"tx": 0, "ty": 0, "tz": 0, "qx": 0, "qy": 0, "qz": 0, "qw": 1},
          "confidence": 0.5
        }
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: stubJSON, statusCode: 200, headers: ["Content-Type": "application/json"])

        let buildingId = "bld-test"
        let images = [makeTestImage(), makeTestImage(color: .blue)]

        let result: Result<LocalizeV3Response, Error> = await awaitResult { completion in
            manager.localizeV3(buildingId: buildingId, images: images, completion: completion)
        }
        // 응답이 와야 capture 가 완료됨
        _ = try result.get()

        let req = try #require(MockURLProtocol.capturedRequest, "request 가 캡처되지 않음")
        #expect(req.url?.absoluteString == "http://218.150.183.198:8080/api/v1/buildings/bld-test/localize")
        #expect(req.httpMethod == "POST")
        let contentType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try #require(MockURLProtocol.capturedBody, "body 가 캡처되지 않음")
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        // building_id 텍스트 필드
        #expect(bodyString.contains("name=\"building_id\""))
        #expect(bodyString.contains("bld-test"))
        // 이미지 2개
        #expect(bodyString.contains("name=\"images\"; filename=\"image0.jpg\""))
        #expect(bodyString.contains("name=\"images\"; filename=\"image1.jpg\""))
        // 종료 boundary
        #expect(bodyString.contains("--\r\n") || bodyString.hasSuffix("--\r\n"))
    }

    // MARK: - 2) localizeV3 — 응답 디코드

    @Test("localizeV3: 200 응답을 LocalizeV3Response 로 디코드")
    func localizeV3_decodesResponse() async throws {
        let manager = configuredManager()

        let stubJSON = """
        {
          "buildingId": "00000000-0000-0000-0000-000000000abc",
          "mapId": "scan-abc",
          "pose": {"tx": 1.5, "ty": 2.5, "tz": 3.5, "qx": 0.1, "qy": 0.2, "qz": 0.3, "qw": 0.9, "floorLevel": 3},
          "confidence": 0.92
        }
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: stubJSON, statusCode: 200, headers: ["Content-Type": "application/json"])

        let result: Result<LocalizeV3Response, Error> = await awaitResult { completion in
            manager.localizeV3(buildingId: "bld", images: [makeTestImage()], completion: completion)
        }
        let response = try result.get()
        #expect(response.mapId == "scan-abc")
        #expect(response.buildingId == "00000000-0000-0000-0000-000000000abc")
        #expect(response.pose.floorLevel == 3)
        #expect(response.pose.tx == 1.5)
        #expect(response.pose.qx == 0.1)
        #expect(response.pose.qw == 0.9)
    }

    // MARK: - 3) pathfinding — JSON 요청 빌드

    @Test("pathfinding: URL/JSON Content-Type/body round-trip")
    func pathfinding_buildsJSONRequest() async throws {
        let manager = configuredManager()

        let stubJSON = """
        {
          "buildingId": "bld",
          "totalDistance": 0,
          "estimatedTimeSeconds": 0,
          "steps": [],
          "floorTransitions": []
        }
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: stubJSON, statusCode: 200, headers: ["Content-Type": "application/json"])

        let dto = PathfindingRequest(
            startScanId: "scan-1",
            startFloorLevel: 2,
            startX: 1.0, startY: 2.0, startZ: 0.0,
            destinationName: "회의실 A",
            preference: .shortest,
            verticalPreference: .elevator
        )

        let result: Result<PathfindingResponse, Error> = await awaitResult { completion in
            manager.pathfinding(buildingId: "bld-1", request: dto, completion: completion)
        }
        _ = try result.get()

        let req = try #require(MockURLProtocol.capturedRequest)
        #expect(req.url?.absoluteString == "http://218.150.183.198:8080/api/v1/buildings/bld-1/pathfinding")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(MockURLProtocol.capturedBody)
        let decoded = try JSONDecoder().decode(PathfindingRequest.self, from: body)
        #expect(decoded.startScanId == "scan-1")
        #expect(decoded.destinationName == "회의실 A")
        #expect(decoded.verticalPreference == .elevator)
        #expect(decoded.preference == .shortest)
    }

    // MARK: - 4) pathfinding — 응답 디코드

    @Test("pathfinding: steps + floorTransitions 디코드")
    func pathfinding_decodesResponse() async throws {
        let manager = configuredManager()

        let stubJSON = """
        {
          "buildingId": "bld-x",
          "totalDistance": 42.5,
          "estimatedTimeSeconds": 90,
          "steps": [
            {"stepNumber": 0, "floorLevel": 1, "position": {"x": 1.0, "y": 2.0, "z": 0.0, "floorLevel": 1}, "instruction": "직진", "nodeId": "n0"},
            {"stepNumber": 1, "floorLevel": 2, "position": {"x": 3.0, "y": 4.0, "z": 0.0, "floorLevel": 2}, "instruction": null, "nodeId": "n1"}
          ],
          "floorTransitions": [
            {"fromFloorLevel": 1, "toFloorLevel": 2, "connectorType": "elevator", "connectorKey": "elv-1"}
          ]
        }
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: stubJSON, statusCode: 200, headers: ["Content-Type": "application/json"])

        let dto = PathfindingRequest(startScanId: "s", startFloorLevel: nil,
                                     startX: 0, startY: 0, startZ: 0,
                                     destinationName: "x", preference: nil, verticalPreference: nil)
        let result: Result<PathfindingResponse, Error> = await awaitResult { completion in
            manager.pathfinding(buildingId: "bld", request: dto, completion: completion)
        }
        let response = try result.get()
        #expect(response.steps.count == 2)
        #expect(response.steps[0].position.x == 1.0)
        #expect(response.steps[1].position.floorLevel == 2)
        #expect(response.floorTransitions.count == 1)
        #expect(response.floorTransitions[0].connectorType == "elevator")
        #expect(response.floorTransitions[0].connectorKey == "elv-1")
    }

    // MARK: - 5) featurePointsLookup — JSON 요청 빌드

    @Test("featurePointsLookup: URL/JSON body round-trip")
    func featurePointsLookup_buildsJSONRequest() async throws {
        let manager = configuredManager()

        let stubJSON = """
        {
          "buildingId": "bld",
          "keyframes": [],
          "model": {"extractor": "superpoint_v1", "matcher": "superpoint_lightglue", "descriptorDim": 256, "maxKeypoints": 1024, "descriptorDtype": "float16", "globalDescriptorDim": 384, "globalDescriptorExtractor": "dinov2"},
          "stats": {"queryCount": 0, "keyframeCount": 0, "totalKeypoints": 0, "byteSize": 0}
        }
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: stubJSON, statusCode: 200, headers: ["Content-Type": "application/json"])

        let dto = LookupRequest(
            queries: [
                LookupQuery(floorLevel: 2, x: 5.5, y: 6.6, z: 0.0, viewDirection: [0.0, 0.0, 1.0])
            ],
            options: LookupOptions(radiusM: 5.0, maxKeyframesPerQuery: 10, viewConeDeg: 60, format: "json_b64")
        )

        let result: Result<LookupResponse, Error> = await awaitResult { completion in
            manager.featurePointsLookup(buildingId: "bld-9", request: dto, completion: completion)
        }
        _ = try result.get()

        let req = try #require(MockURLProtocol.capturedRequest)
        #expect(req.url?.absoluteString == "http://218.150.183.198:8080/api/v1/buildings/bld-9/feature-points/lookup")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(MockURLProtocol.capturedBody)
        let decoded = try JSONDecoder().decode(LookupRequest.self, from: body)
        #expect(decoded.queries.count == 1)
        #expect(decoded.queries[0].x == 5.5)
        #expect(decoded.queries[0].floorLevel == 2)
        #expect(decoded.options?.radiusM == 5.0)
        #expect(decoded.options?.format == "json_b64")
    }

    // MARK: - 6) featurePointsLookup — 응답 디코드

    @Test("featurePointsLookup: keyframes + model + stats 디코드")
    func featurePointsLookup_decodesResponse() async throws {
        let manager = configuredManager()

        let stubJSON = """
        {
          "buildingId": "bld",
          "keyframes": [
            {
              "kfId": "kf-1",
              "scanId": "scan-1",
              "floorLevel": 2,
              "rtabmapNodeId": 42,
              "pose": [[1,0,0,1.0],[0,1,0,2.0],[0,0,1,3.0],[0,0,0,1]],
              "intrinsics": {"fx": 500, "fy": 500, "cx": 320, "cy": 240, "width": 640, "height": 480},
              "matchedQueryIndices": [0],
              "distancesM": [1.2],
              "keypointCount": 0,
              "keypoints": "",
              "descriptors": "",
              "world3d": "",
              "globalDescriptor": ""
            }
          ],
          "model": {"extractor": "superpoint_v1", "matcher": "superpoint_lightglue", "descriptorDim": 256, "maxKeypoints": 1024, "descriptorDtype": "float16", "globalDescriptorDim": 384, "globalDescriptorExtractor": "dinov2"},
          "stats": {"queryCount": 1, "keyframeCount": 1, "totalKeypoints": 0, "byteSize": 1024}
        }
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: stubJSON, statusCode: 200, headers: ["Content-Type": "application/json"])

        let dto = LookupRequest(queries: [], options: nil)
        let result: Result<LookupResponse, Error> = await awaitResult { completion in
            manager.featurePointsLookup(buildingId: "bld", request: dto, completion: completion)
        }
        let response = try result.get()
        #expect(response.keyframes.count == 1)
        #expect(response.keyframes[0].kfId == "kf-1")
        #expect(response.keyframes[0].rtabmapNodeId == 42)
        #expect(response.model.descriptorDim == 256)
        #expect(response.model.globalDescriptorDim == 384)
        #expect(response.stats.byteSize > 0)
    }

    // MARK: - 7) httpError 전파 — V1ErrorResponse 디코드 경로 확인

    @Test("HTTP 422 + V1ErrorResponse 본문 → completion .failure, 메시지에 code 포함")
    func httpError_propagates() async throws {
        let manager = configuredManager()

        let errorJSON = """
        {"code": "PATH_NOT_FOUND", "message": "경로 없음", "detail": null}
        """.data(using: .utf8)!
        MockURLProtocol.stubResponse = (data: errorJSON, statusCode: 422, headers: ["Content-Type": "application/json"])

        let dto = PathfindingRequest(startScanId: "s", startFloorLevel: nil,
                                     startX: 0, startY: 0, startZ: 0,
                                     destinationName: "x", preference: nil, verticalPreference: nil)
        let result: Result<PathfindingResponse, Error> = await awaitResult { completion in
            manager.pathfinding(buildingId: "bld", request: dto, completion: completion)
        }
        switch result {
        case .success:
            Issue.record("422 응답인데 .success 반환됨")
        case .failure(let error):
            let message = error.localizedDescription
            #expect(message.contains("PATH_NOT_FOUND"), "에러 메시지에 V1ErrorResponse.code 가 포함되어야 함. 실제: \(message)")
            #expect(message.contains("422"))
        }
    }
}
