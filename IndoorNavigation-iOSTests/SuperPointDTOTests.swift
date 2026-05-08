import Testing
import Foundation
import simd
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

    // MARK: - 8. LocalizeV3Pose helpers — quaternion only

    @Test("LocalizeV3Pose helpers: tx/ty/tz + qx/qy/qz/qw 만 → toMatrix4x4 마지막 열 = translation")
    func localizeV3Pose_QuaternionOnly_returnsMatrix() throws {
        let pose = LocalizeV3Pose(
            tx: 1.5, ty: 2.5, tz: 3.5,
            qx: 0.0, qy: 0.0, qz: 0.0, qw: 1.0,
            matrix: nil
        )
        let m = try #require(pose.toMatrix4x4())
        // 마지막 열 = translation (column-major simd_float4x4)
        #expect(abs(m.columns.3.x - 1.5) < 1e-5)
        #expect(abs(m.columns.3.y - 2.5) < 1e-5)
        #expect(abs(m.columns.3.z - 3.5) < 1e-5)
        #expect(abs(m.columns.3.w - 1.0) < 1e-5)
        // identity quaternion → 좌측 3×3 = identity
        #expect(abs(m.columns.0.x - 1.0) < 1e-5)
        #expect(abs(m.columns.1.y - 1.0) < 1e-5)
        #expect(abs(m.columns.2.z - 1.0) < 1e-5)

        let t = try #require(pose.translation)
        #expect(t.x == 1.5)
        #expect(t.y == 2.5)
        #expect(t.z == 3.5)

        let q = try #require(pose.rotationQuaternion)
        #expect(abs(q.real - 1.0) < 1e-5)
    }

    // MARK: - 9. LocalizeV3Pose helpers — matrix only

    @Test("LocalizeV3Pose helpers: matrix 만 → simd_float4x4 element-wise 일치")
    func localizeV3Pose_MatrixOnly_returnsMatrix() throws {
        let mat: [[Double]] = [
            [1.0, 0.0, 0.0, 7.0],
            [0.0, 1.0, 0.0, 8.0],
            [0.0, 0.0, 1.0, 9.0],
            [0.0, 0.0, 0.0, 1.0],
        ]
        let pose = LocalizeV3Pose(
            tx: nil, ty: nil, tz: nil,
            qx: nil, qy: nil, qz: nil, qw: nil,
            matrix: mat
        )
        let m = try #require(pose.toMatrix4x4())
        // simd_float4x4(rows:) 는 row-major 입력 → column-major 저장
        // 입력 row r, col c → m.columns[c][r]
        for r in 0..<4 {
            for c in 0..<4 {
                let expected = Float(mat[r][c])
                let column: SIMD4<Float>
                switch c {
                case 0: column = m.columns.0
                case 1: column = m.columns.1
                case 2: column = m.columns.2
                default: column = m.columns.3
                }
                let actual: Float
                switch r {
                case 0: actual = column.x
                case 1: actual = column.y
                case 2: actual = column.z
                default: actual = column.w
                }
                #expect(abs(actual - expected) < 1e-5)
            }
        }

        let t = try #require(pose.translation)
        #expect(t.x == 7.0)
        #expect(t.y == 8.0)
        #expect(t.z == 9.0)
    }

    // MARK: - 10. LocalizeV3Pose helpers — both nil

    @Test("LocalizeV3Pose helpers: 모두 nil → toMatrix4x4/translation/rotationQuaternion nil")
    func localizeV3Pose_BothNil_returnsNil() throws {
        let pose = LocalizeV3Pose(
            tx: nil, ty: nil, tz: nil,
            qx: nil, qy: nil, qz: nil, qw: nil,
            matrix: nil
        )
        #expect(pose.toMatrix4x4() == nil)
        #expect(pose.translation == nil)
        #expect(pose.rotationQuaternion == nil)
    }

    // MARK: - 11. LocalizeV3Pose helpers — quaternion priority if matrix nil

    @Test("LocalizeV3Pose helpers: matrix nil + quat 채워짐 → 정상 변환")
    func localizeV3Pose_QuaternionPriorityIfMatrixNil() throws {
        // 90° yaw (Y axis) 회전: half-angle = 45°
        let halfAngle: Double = .pi / 4
        let pose = LocalizeV3Pose(
            tx: 10.0, ty: 0.0, tz: -5.0,
            qx: 0.0, qy: sin(halfAngle), qz: 0.0, qw: cos(halfAngle),
            matrix: nil
        )
        let m = try #require(pose.toMatrix4x4())
        // translation 정상 적용
        #expect(abs(m.columns.3.x - 10.0) < 1e-5)
        #expect(abs(m.columns.3.z - (-5.0)) < 1e-5)
        // 90° yaw 회전 후 R[0,0] ≈ 0
        #expect(abs(m.columns.0.x) < 1e-4)

        let q = try #require(pose.rotationQuaternion)
        #expect(abs(q.imag.y - Float(sin(halfAngle))) < 1e-5)
        #expect(abs(q.real - Float(cos(halfAngle))) < 1e-5)
    }

    // MARK: - 12. LocalizeV3Response — 잠정 픽스처 디코딩 (서버답 대기)

    // TODO(서버답): 실제 응답 형식 받아오면 본 테스트 의 픽스처 갱신
    @Test("LocalizeV3Response: 잠정 픽스처 (quaternion form) 디코딩 + helpers 통합")
    func localizeV3Response_decodeFromJSON_quaternionForm() throws {
        let json = """
        {
          "pose": {
            "tx": 12.0, "ty": 1.5, "tz": -3.0,
            "qx": 0.0, "qy": 0.0, "qz": 0.0, "qw": 1.0
          },
          "confidence": 0.92,
          "mapId": "scan-uuid-fixture",
          "numMatches": 200,
          "matchedImageIndex": 2,
          "floorId": "floor-uuid-fixture",
          "floorLevel": 5
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(LocalizeV3Response.self, from: json)
        #expect(response.confidence == 0.92)
        #expect(response.mapId == "scan-uuid-fixture")
        #expect(response.matchedImageIndex == 2)
        #expect(response.floorLevel == 5)

        // helpers 가 디코딩 결과로부터 정상 동작하는지
        let t = try #require(response.pose.translation)
        #expect(t.x == 12.0)
        #expect(t.z == -3.0)
        let m = try #require(response.pose.toMatrix4x4())
        #expect(abs(m.columns.3.y - 1.5) < 1e-5)
    }

    // MARK: - 13. PathfindingResponse.toPathSteps() — B4 어댑터

    /// Helper: PathfindingStep 합성.
    private func makePathStep(stepNumber: Int,
                              floorLevel: Int,
                              x: Double, y: Double, z: Double,
                              instruction: String? = nil,
                              nodeId: String = "node") -> PathfindingStep {
        return PathfindingStep(
            stepNumber: stepNumber,
            floorLevel: floorLevel,
            position: WorldPosition(x: x, y: y, z: z, floorLevel: floorLevel),
            instruction: instruction,
            nodeId: nodeId
        )
    }

    /// Helper: PathfindingResponse 합성.
    private func makePathResponse(steps: [PathfindingStep],
                                  floorTransitions: [FloorTransition] = []) -> PathfindingResponse {
        return PathfindingResponse(
            buildingId: "test-building",
            totalDistance: 0.0,
            estimatedTimeSeconds: 0,
            steps: steps,
            floorTransitions: floorTransitions
        )
    }

    @Test("toPathSteps: steps 3개 → 길이 3, 각 필드 일치")
    func pathfindingResponse_toPathSteps_basic() {
        let steps = [
            makePathStep(stepNumber: 0, floorLevel: 1, x: 1.0, y: 2.0, z: 3.0, instruction: "직진"),
            makePathStep(stepNumber: 1, floorLevel: 1, x: 4.0, y: 5.0, z: 6.0, instruction: "좌회전"),
            makePathStep(stepNumber: 2, floorLevel: 1, x: 7.0, y: 8.0, z: 9.0, instruction: nil)
        ]
        let resp = makePathResponse(steps: steps)

        let pathSteps = resp.toPathSteps()

        #expect(pathSteps.count == 3)

        #expect(pathSteps[0].stepNumber == 0)
        #expect(pathSteps[0].floorLevel == 1)
        #expect(pathSteps[0].position?.x == 1.0)
        #expect(pathSteps[0].position?.y == 2.0)
        #expect(pathSteps[0].position?.z == 3.0)
        #expect(pathSteps[0].instruction == "직진")

        #expect(pathSteps[1].stepNumber == 1)
        #expect(pathSteps[1].position?.x == 4.0)
        #expect(pathSteps[1].instruction == "좌회전")

        #expect(pathSteps[2].stepNumber == 2)
        #expect(pathSteps[2].position?.z == 9.0)
        #expect(pathSteps[2].instruction == nil)
    }

    @Test("toPathSteps: steps 5개 (1→1→2→2→2) — floorLevel 변화 보존")
    func pathfindingResponse_toPathSteps_multiFloor() {
        let steps = [
            makePathStep(stepNumber: 0, floorLevel: 1, x: 0.0, y: 0.0, z: 0.0),
            makePathStep(stepNumber: 1, floorLevel: 1, x: 1.0, y: 0.0, z: 0.0, instruction: "TAKE_ELEVATOR"),
            makePathStep(stepNumber: 2, floorLevel: 2, x: 1.0, y: 0.0, z: 0.0),
            makePathStep(stepNumber: 3, floorLevel: 2, x: 2.0, y: 0.0, z: 0.0),
            makePathStep(stepNumber: 4, floorLevel: 2, x: 3.0, y: 0.0, z: 0.0)
        ]
        let resp = makePathResponse(steps: steps)

        let pathSteps = resp.toPathSteps()

        #expect(pathSteps.count == 5)
        #expect(pathSteps[0].floorLevel == 1)
        #expect(pathSteps[1].floorLevel == 1)
        #expect(pathSteps[2].floorLevel == 2)
        #expect(pathSteps[3].floorLevel == 2)
        #expect(pathSteps[4].floorLevel == 2)

        // instruction 키워드 보존 (detectFloorTransition 가 사용)
        #expect(pathSteps[1].instruction == "TAKE_ELEVATOR")
    }

    @Test("toPathSteps: 빈 steps → 빈 배열")
    func pathfindingResponse_toPathSteps_emptySteps() {
        let resp = makePathResponse(steps: [])
        let pathSteps = resp.toPathSteps()
        #expect(pathSteps.isEmpty)
    }
}
