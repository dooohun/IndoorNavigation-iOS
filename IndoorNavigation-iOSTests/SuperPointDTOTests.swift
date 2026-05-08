import Testing
import Foundation
@testable import IndoorNavigation_iOS

/// Phase 8 B1 — SuperPointDTO 의 인코딩/디코딩 단위 테스트.
/// 외부 파일 의존 없이 합성 JSON 인라인 으로만 검증.
struct SuperPointDTOTests {

    // MARK: - 1. LocalizeV3 — 쿼터니언 형식 디코딩

    @Test("LocalizeV3Pose: tx/ty/tz + qx/qy/qz/qw 디코딩, matrix 는 nil")
    func localizeV3Response_decodesQuaternionPose() throws {
        let json = """
        {
          "pose": {
            "tx": 1.5, "ty": 2.5, "tz": 3.5,
            "qx": 0.1, "qy": 0.2, "qz": 0.3, "qw": 0.927
          },
          "confidence": 0.85,
          "mapId": "scan-uuid-1",
          "numMatches": 124,
          "matchedImageIndex": 0,
          "floorId": "floor-uuid-1",
          "floorLevel": 3
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalizeV3Response.self, from: json)
        #expect(decoded.pose.tx == 1.5)
        #expect(decoded.pose.ty == 2.5)
        #expect(decoded.pose.tz == 3.5)
        #expect(decoded.pose.qw == 0.927)
        #expect(decoded.pose.matrix == nil)
        #expect(decoded.confidence == 0.85)
        #expect(decoded.mapId == "scan-uuid-1")
        #expect(decoded.floorLevel == 3)
    }

    // MARK: - 2. LocalizeV3 — 4×4 행렬 형식 디코딩

    @Test("LocalizeV3Pose: 4x4 matrix 디코딩, tx 등 nil")
    func localizeV3Response_decodesMatrixPose() throws {
        let json = """
        {
          "pose": {
            "matrix": [
              [1.0, 0.0, 0.0, 1.5],
              [0.0, 1.0, 0.0, 2.5],
              [0.0, 0.0, 1.0, 3.5],
              [0.0, 0.0, 0.0, 1.0]
            ]
          },
          "confidence": 0.7,
          "mapId": "scan-uuid-2",
          "numMatches": 50,
          "matchedImageIndex": 1,
          "floorId": "floor-uuid-2",
          "floorLevel": 1
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalizeV3Response.self, from: json)
        #expect(decoded.pose.tx == nil)
        #expect(decoded.pose.qw == nil)
        let matrix = try #require(decoded.pose.matrix)
        #expect(matrix.count == 4)
        #expect(matrix[0][3] == 1.5)
        #expect(matrix[1][3] == 2.5)
        #expect(matrix[2][3] == 3.5)
    }

    // MARK: - 3. Pathfinding — enum 인코딩 정확성

    @Test("PathfindingRequest: VerticalPreference/RoutePreference 가 대문자 문자열로 인코딩")
    func pathfindingRequest_encodesEnumsCorrectly() throws {
        let req = PathfindingRequest(
            startScanId: "scan-uuid-1",
            startFloorLevel: 3,
            startX: 1.0, startY: 2.0, startZ: 3.0,
            destinationName: "301호",
            preference: .shortest,
            verticalPreference: .elevator
        )
        let data = try JSONEncoder().encode(req)
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(body.contains("\"preference\":\"SHORTEST\""))
        #expect(body.contains("\"verticalPreference\":\"ELEVATOR\""))
        #expect(body.contains("\"destinationName\":\"301호\""))

        // 다른 enum 값도 round-trip
        let req2 = PathfindingRequest(
            startScanId: "scan-uuid-2", startFloorLevel: nil,
            startX: 0, startY: 0, startZ: 0,
            destinationName: "201호", preference: nil,
            verticalPreference: .stairs
        )
        let data2 = try JSONEncoder().encode(req2)
        let body2 = try #require(String(data: data2, encoding: .utf8))
        #expect(body2.contains("\"verticalPreference\":\"STAIRS\""))
    }

    // MARK: - 4. Pathfinding — 중첩 steps + floorTransitions 디코딩

    @Test("PathfindingResponse: steps[].position 와 floorTransitions[] 중첩 디코딩")
    func pathfindingResponse_decodesNestedSteps() throws {
        let json = """
        {
          "buildingId": "building-uuid",
          "totalDistance": 42.7,
          "estimatedTimeSeconds": 60,
          "steps": [
            {
              "stepNumber": 0,
              "floorLevel": 1,
              "position": { "x": 1.0, "y": 2.0, "z": 0.0, "floorLevel": 1 },
              "instruction": "직진",
              "nodeId": "node-1"
            },
            {
              "stepNumber": 1,
              "floorLevel": 3,
              "position": { "x": 5.0, "y": 6.0, "z": 0.0, "floorLevel": 3 },
              "instruction": null,
              "nodeId": "node-2"
            }
          ],
          "floorTransitions": [
            {
              "fromFloorLevel": 1,
              "toFloorLevel": 3,
              "connectorType": "elevator",
              "connectorKey": "ELV-A"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PathfindingResponse.self, from: json)
        #expect(decoded.buildingId == "building-uuid")
        #expect(decoded.totalDistance == 42.7)
        #expect(decoded.steps.count == 2)
        #expect(decoded.steps[0].position.floorLevel == 1)
        #expect(decoded.steps[0].instruction == "직진")
        #expect(decoded.steps[1].instruction == nil)
        #expect(decoded.steps[1].position.x == 5.0)
        #expect(decoded.floorTransitions.count == 1)
        #expect(decoded.floorTransitions[0].connectorType == "elevator")
        #expect(decoded.floorTransitions[0].connectorKey == "ELV-A")
    }

    // MARK: - 5. Lookup — 인코드 → 디코드 라운드트립

    @Test("LookupRequest: encode → decode 후 같은 값 (viewDirection 포함)")
    func lookupRequest_roundtripEncoding() throws {
        let original = LookupRequest(
            queries: [
                LookupQuery(floorLevel: 3, x: 1.0, y: 2.0, z: 0.0,
                            viewDirection: [0.0, 0.0, -1.0]),
                LookupQuery(floorLevel: 3, x: 4.5, y: 5.5, z: 0.0,
                            viewDirection: nil)
            ],
            options: LookupOptions(radiusM: 2.5, maxKeyframesPerQuery: 5,
                                   viewConeDeg: 60, format: "json_b64")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LookupRequest.self, from: data)

        #expect(decoded.queries.count == 2)
        #expect(decoded.queries[0].floorLevel == 3)
        #expect(decoded.queries[0].x == 1.0)
        #expect(decoded.queries[0].viewDirection == [0.0, 0.0, -1.0])
        #expect(decoded.queries[1].viewDirection == nil)
        #expect(decoded.options?.radiusM == 2.5)
        #expect(decoded.options?.maxKeyframesPerQuery == 5)
        #expect(decoded.options?.viewConeDeg == 60)
        #expect(decoded.options?.format == "json_b64")
    }

    // MARK: - 6. Lookup — 합성 응답 JSON 디코딩

    @Test("LookupResponse: 합성 JSON 디코딩 + descriptorDim==256 검증")
    func lookupResponse_decodesFromSyntheticJson() throws {
        let json = """
        {
          "buildingId": "building-uuid",
          "keyframes": [
            {
              "kfId": "kf-1",
              "scanId": "scan-1",
              "floorLevel": 3,
              "rtabmapNodeId": 17,
              "pose": [
                [1.0, 0.0, 0.0, 1.5],
                [0.0, 1.0, 0.0, 2.5],
                [0.0, 0.0, 1.0, 0.0],
                [0.0, 0.0, 0.0, 1.0]
              ],
              "intrinsics": { "fx": 1463.0, "fy": 1463.0, "cx": 960.0, "cy": 540.0, "width": 1920, "height": 1080 },
              "matchedQueryIndices": [0],
              "distancesM": [1.2],
              "keypointCount": 256,
              "keypoints": "AAAA",
              "descriptors": "BBBB",
              "world3d": "CCCC",
              "globalDescriptor": "DDDD"
            }
          ],
          "model": {
            "extractor": "superpoint_v1",
            "matcher": "superpoint_lightglue",
            "descriptorDim": 256,
            "maxKeypoints": 1024,
            "descriptorDtype": "float16",
            "globalDescriptorDim": 384,
            "globalDescriptorExtractor": "dinov2"
          },
          "stats": {
            "queryCount": 1,
            "keyframeCount": 1,
            "totalKeypoints": 256,
            "byteSize": 12345
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LookupResponse.self, from: json)
        #expect(decoded.buildingId == "building-uuid")
        #expect(decoded.keyframes.count == 1)
        let kf = decoded.keyframes[0]
        #expect(kf.kfId == "kf-1")
        #expect(kf.floorLevel == 3)
        #expect(kf.rtabmapNodeId == 17)
        #expect(kf.pose.count == 4)
        #expect(kf.pose[0][3] == 1.5)
        #expect(kf.intrinsics.fx == 1463.0)
        #expect(kf.intrinsics.width == 1920)
        #expect(kf.matchedQueryIndices == [0])
        #expect(kf.keypointCount == 256)
        #expect(kf.keypoints == "AAAA")
        #expect(decoded.model.descriptorDim == 256)
        #expect(decoded.model.maxKeypoints == 1024)
        #expect(decoded.model.descriptorDtype == "float16")
        #expect(decoded.stats.totalKeypoints == 256)
    }

    // MARK: - 7. Lookup — 추가(미지) 필드 무시

    @Test("LookupResponse: 알 수 없는 추가 필드는 무시하고 디코딩")
    func lookupResponse_skipsUnknownFields() throws {
        // 최소 필드 + future 확장 필드 (`extraTopLevel`, keyframe/model/stats 안에 미지 키)
        let json = """
        {
          "buildingId": "building-uuid",
          "extraTopLevel": "ignored",
          "keyframes": [
            {
              "kfId": "kf-x",
              "scanId": "scan-x",
              "floorLevel": 1,
              "rtabmapNodeId": 1,
              "pose": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
              "intrinsics": { "fx": 1.0, "fy": 1.0, "cx": 0.0, "cy": 0.0, "width": 1, "height": 1 },
              "matchedQueryIndices": [],
              "distancesM": [],
              "keypointCount": 0,
              "keypoints": "",
              "descriptors": "",
              "world3d": "",
              "globalDescriptor": "",
              "futureField": 42
            }
          ],
          "model": {
            "extractor": "superpoint_v1",
            "matcher": "superpoint_lightglue",
            "descriptorDim": 256,
            "maxKeypoints": 1024,
            "descriptorDtype": "float16",
            "globalDescriptorDim": 384,
            "globalDescriptorExtractor": "dinov2",
            "modelFutureKnob": "x"
          },
          "stats": {
            "queryCount": 0,
            "keyframeCount": 0,
            "totalKeypoints": 0,
            "byteSize": 0,
            "statsFuture": true
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LookupResponse.self, from: json)
        #expect(decoded.buildingId == "building-uuid")
        #expect(decoded.keyframes.count == 1)
        #expect(decoded.keyframes[0].kfId == "kf-x")
        #expect(decoded.model.descriptorDim == 256)
        #expect(decoded.stats.queryCount == 0)
    }
}
