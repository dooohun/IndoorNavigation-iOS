//
//  DTOs.swift
//  IndoorNavigation-iOS
//
//  네트워크 DTO 통합 — OpenAPI 정합 10 endpoint.
//

import Foundation
import simd

// MARK: - Buildings / Floors

struct BuildingResponse: Codable {
    let buildingId: String
    let name: String
    let description: String?
    let latitude: Double?
    let longitude: Double?
    let status: String           // "DRAFT" | "ACTIVE"
    let createdAt: String?
    let updatedAt: String?
}

struct BuildingDetailResponse: Codable {
    let buildingId: String
    let name: String
    let description: String?
    let latitude: Double?
    let longitude: Double?
    let status: String
    let createdAt: String?
    let updatedAt: String?
    let floors: [FloorResponse]?
    let verticalPassages: [VerticalPassageResponse]?
}

struct FloorResponse: Codable {
    let floorId: String
    let buildingId: String
    let name: String
    let level: Int
    let height: Double?
    let hasPath: Bool
    let hasPly: Bool
    let activeScanId: String?
    let createdAt: String?
    let updatedAt: String?
}

struct VerticalPassageResponse: Codable {
    let passageId: String
    let buildingId: String?
    let connectorType: String
    let connectorKey: String
    let name: String?
    let mock: Bool
    let segments: [PassageSegment]?
}

struct PassageSegment: Codable {
    let stopId: String?
    let levelId: String?
    let routeNodeId: String?
    let x: Double?
    let y: Double?
    let floorId: String?
    let kind: String?
}

// MARK: - FloorMap

struct FloorMapResponse: Codable {
    let floorId: String
    let buildingId: String
    let scanId: String
    let floorLevel: Int
    let floorName: String?
    let buildJobId: String?
    let coordinateSystem: FloorMapCoordinateSystem?
    let bounds: FloorMapBounds
    let polygon: PolygonRaw
    let nodes: [FloorMapNode]
    let edges: [FloorMapEdge]
    let etag: String
    let destinations: [FloorMapDestination]?
    let connectors: [FloorMapConnectorDetail]?
}

struct FloorMapCoordinateSystem: Codable {
    let frame: String?
    let description: String?
}

struct FloorMapBounds: Codable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let widthM: Double
    let heightM: Double
}

struct FloorMapNode: Codable {
    let id: String
    let type: String
    let x: Double
    let y: Double
    let z: Double
    let label: String?
    let category: String?
    let connector: FloorMapConnector?
}

struct FloorMapConnector: Codable {
    let type: String
    let key: String?
}

struct FloorMapEdge: Codable {
    let id: String
    let fromId: String
    let toId: String
    let lengthM: Double
    let type: String

    // 서버 응답 키 호환: 신서버는 fromNodeId / toNodeId 로 응답하지만, 클라 내부 호출자(ARNavigationViewController 등)는
    // 기존 프로퍼티명 fromId / toId 를 유지한다.
    private enum CodingKeys: String, CodingKey {
        case id
        case fromId = "fromNodeId"
        case toId = "toNodeId"
        case lengthM
        case type
    }
}

// MARK: - FloorMap 부속 (destinations / connectors)

/// `FloorMapResponse.destinations[]` — 층 내 도착 가능 노드(POI 등) 메타.
/// 현재 클라는 미사용이나, JSONDecoder 가 모르는 필드를 무시하지 않도록 옵셔널로 보존.
struct FloorMapDestination: Codable {
    let id: String?
    let routeNodeId: String?
    let name: String?
    let label: String?
    let category: String?
    let x: Double?
    let y: Double?
    let z: Double?
}

/// `FloorMapResponse.connectors[]` — 층 내 수직 통로(엘리베이터/계단) 진입점 메타.
/// 현재 클라는 미사용. stops 같은 free-form 필드는 생략.
struct FloorMapConnectorDetail: Codable {
    let connectorId: String?
    let type: String?
    let key: String?
    let name: String?
    let routeNodeId: String?
    let x: Double?
    let y: Double?
    let z: Double?
}

/// polygon GeoJSON 자유 schema — raw JSON bytes 로 보존만 한다 (현재 클라 미사용).
struct PolygonRaw: Codable {
    let raw: Data

    init(raw: Data) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        let any = try single.decode(GeoJSONAnyValue.self)
        self.raw = (try? JSONEncoder().encode(any)) ?? Data()
    }

    func encode(to encoder: Encoder) throws {
        // read-only — encode 미지원
    }
}

fileprivate enum GeoJSONAnyValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([GeoJSONAnyValue])
    case dict([String: GeoJSONAnyValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([GeoJSONAnyValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: GeoJSONAnyValue].self) { self = .dict(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "GeoJSONAnyValue")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .dict(let v): try c.encode(v)
        }
    }
}

// MARK: - Pathfinding

enum VerticalPreference: String, Codable {
    case elevator = "ELEVATOR"
    case stairs = "STAIRS"
}

enum RoutePreference: String, Codable {
    case shortest = "SHORTEST"
    case elevatorFirst = "ELEVATOR_FIRST"
    case staircaseFirst = "STAIRCASE_FIRST"
}

struct PathfindingRequest: Codable {
    let startFloorLevel: Int?
    let startX: Double
    let startY: Double
    let startZ: Double
    let destinationId: String
    let destinationName: String
    let preference: RoutePreference?
    let verticalPreference: VerticalPreference?
    let startAreaId: String?
}

struct PathfindingResponse: Codable {
    let buildingId: String?
    let totalDistance: Double
    let estimatedTimeSeconds: Int
    let steps: [PathStepResponse]
    let floorTransitions: [FloorTransitionResponse]?
}

struct PathStepResponse: Codable {
    let stepNumber: Int
    let floorLevel: Int?
    let position: V1Position
    let instruction: String
    let nodeId: String?

    private enum CodingKeys: String, CodingKey {
        case stepNumber
        case floorLevel
        case position
        case instruction
        case nodeId
        case node_id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepNumber = try container.decode(Int.self, forKey: .stepNumber)
        floorLevel = try container.decodeIfPresent(Int.self, forKey: .floorLevel)
        position = try container.decode(V1Position.self, forKey: .position)
        instruction = try container.decode(String.self, forKey: .instruction)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
            ?? container.decodeIfPresent(String.self, forKey: .node_id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stepNumber, forKey: .stepNumber)
        try container.encodeIfPresent(floorLevel, forKey: .floorLevel)
        try container.encode(position, forKey: .position)
        try container.encode(instruction, forKey: .instruction)
        try container.encodeIfPresent(nodeId, forKey: .nodeId)
    }
}

struct V1Position: Codable {
    let x: Double
    let y: Double
    let z: Double
    let floorLevel: Int?
}

struct FloorTransitionResponse: Codable {
    let fromFloorLevel: Int?
    let toFloorLevel: Int?
    let connectorType: String?
    let connectorKey: String?
}

// MARK: - Feature Points Lookup

struct FeatureLookupRequest: Codable {
    let queries: [FeatureLookupQuery]
    let options: FeatureLookupOptions?
}

struct FeatureLookupQuery: Codable {
    let floorLevel: Int
    let x: Double
    let y: Double
    let z: Double
    let viewDirection: [Double]?
}

struct FeatureLookupOptions: Codable {
    let radiusM: Double?
    let maxKeyframesPerQuery: Int?
    let viewConeDeg: Double?
    let format: String?
}

struct FeatureLookupResponse: Codable {
    let buildingId: String
    let keyframes: [FeatureLookupKeyframe]
    let model: FeatureLookupModel?
    let stats: FeatureLookupStats
}

struct FeatureLookupKeyframe: Codable {
    let kfId: String
    let scanId: String
    let floorLevel: Int
    let rtabmapNodeId: Int
    let pose: [[Double]]
    let intrinsics: FeatureLookupIntrinsics
    let matchedQueryIndices: [Int]
    let distancesM: [Double]
    let keypointCount: Int
    let keypoints: String
    let descriptors: String
    let world3d: String
    let globalDescriptor: String
}

struct FeatureLookupIntrinsics: Codable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let width: Int
    let height: Int
}

struct FeatureLookupModel: Codable {
    let extractor: String?
    let matcher: String?
    let descriptorDim: Int?
    let maxKeypoints: Int?
    let descriptorDtype: String?
    let globalDescriptorDim: Int?
    let globalDescriptorExtractor: String?
}

struct FeatureLookupStats: Codable {
    let queryCount: Int
    let keyframeCount: Int
    let totalKeypoints: Int
    let byteSize: Int
}

// MARK: - FloorCoordinateRoute

struct FloorCoordinateRouteRequest: Codable {
    let start: CoordinatePoint
    let goal: CoordinatePoint
}

struct CoordinatePoint: Codable {
    let x: Double
    let y: Double
    let z: Double
}

struct FloorCoordinateRouteResponse: Codable {
    let buildingId: String
    let floorId: String
    let scanId: String
    let pathGeometry: PathGeometry
    let lengthM: Double
    let nodeCount: Int
    let snapInfo: V1RouteSnapInfo
}

struct PathGeometry: Codable {
    let type: String?
    let coordinates: [[Double]]?
}

struct V1RouteSnapInfo: Codable {
    let startSnapDistanceM: Double?
    let goalSnapDistanceM: Double?
}

// MARK: - POIs

struct POIResponse: Codable {
    let poiId: String
    let buildingId: String?
    let floorId: String?
    let name: String?
    let label: String?
    let category: String
    let routeNodeId: String?
    let displayPoint: PoiDisplayPoint?
    let needsReview: Bool
    let llmConfidence: Double?
}

struct PoiDisplayPoint: Codable {
    let x: Double?
    let y: Double?
    let z: Double?
}

// MARK: - SLAM V3 Localize

struct SLAMLocalizeResponse: Codable {
    let pose: SLAMPose
    let confidence: Double
    let numMatches: Int?
    let matchedImageIndex: Int?
    let floorId: String?
    let floorLevel: Int?
    let areaId: String?
}

struct SLAMPose: Codable {
    let x: Double?
    let y: Double?
    let z: Double?
    let qx: Double?
    let qy: Double?
    let qz: Double?
    let qw: Double?
}

extension SLAMPose {
    /// pose 를 4×4 변환 행렬로 변환. (x/y/z) + 쿼터니언 조합. 둘 다 없으면 nil.
    func toMatrix4x4() -> simd_float4x4? {
        guard let x, let y, let z, let qx, let qy, let qz, let qw else { return nil }
        let q = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(Float(x), Float(y), Float(z), 1)
        return m
    }

    var translation: simd_float3? {
        guard let x, let y, let z else { return nil }
        return simd_float3(Float(x), Float(y), Float(z))
    }

    var rotationQuaternion: simd_quatf? {
        guard let qx, let qy, let qz, let qw else { return nil }
        return simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
    }
}

// MARK: - 내부 도메인 모델 (네트워크 외부, ARNavigationLogic 의존)

struct Pose: Codable {
    var x: Double?
    var y: Double?
    var z: Double?
    var qx: Double?
    var qy: Double?
    var qz: Double?
    var qw: Double?
}

struct PathStep: Codable {
    let stepNumber: Int
    let floorLevel: Int?
    let position: Position?
    let instruction: String?
    let nodeId: String?
}

struct Position: Codable {
    let x: Double?
    let y: Double?
    let z: Double?
}

typealias Coordinate = CoordinatePoint

// MARK: - 어댑터

extension PathfindingResponse {
    func toPathSteps() -> [PathStep] {
        return steps.map { s in
            PathStep(
                stepNumber: s.stepNumber,
                floorLevel: s.floorLevel,
                position: Position(x: s.position.x, y: s.position.y, z: s.position.z),
                instruction: s.instruction,
                nodeId: s.nodeId
            )
        }
    }
}

// MARK: - Lookup → LocalizationBundle 어댑터

enum LookupAdaptationError: Error, CustomStringConvertible {
    case adaptationFailed(reason: String)

    var description: String {
        switch self {
        case .adaptationFailed(let reason):
            return "lookup → bundle 변환 실패: \(reason)"
        }
    }
}

extension FeatureLookupResponse {

    /// 서버 lookup 응답 → 클라 측위/추적용 `LocalizationBundle` 변환.
    /// - Parameters:
    ///   - scanIdOverride: nil 이면 첫 keyframe.scanId 사용
    ///   - floorIdOverride: nil 이면 빈 문자열 (lookup 응답에 floorId 없음)
    ///   - destination: manifest.destination 에 주입
    func toLocalizationBundle(
        scanIdOverride: String? = nil,
        floorIdOverride: String? = nil,
        destination: String = ""
    ) throws -> LocalizationBundle {
        guard let firstKf = keyframes.first else {
            throw LookupAdaptationError.adaptationFailed(reason: "empty keyframes")
        }

        // intrinsics 동질성 가드
        let firstIntr = firstKf.intrinsics
        for kf in keyframes.dropFirst() {
            let i = kf.intrinsics
            if i.fx != firstIntr.fx || i.fy != firstIntr.fy ||
               i.cx != firstIntr.cx || i.cy != firstIntr.cy ||
               i.width != firstIntr.width || i.height != firstIntr.height {
                throw LookupAdaptationError.adaptationFailed(reason: "heterogeneous intrinsics")
            }
        }

        let manifest = BundleManifest(
            version: "lookup-v1",
            scanId: scanIdOverride ?? firstKf.scanId,
            floorId: floorIdOverride ?? "",
            floorLevel: firstKf.floorLevel,
            destination: destination,
            intrinsics: BundleIntrinsics(
                fx: firstIntr.fx,
                fy: firstIntr.fy,
                cx: firstIntr.cx,
                cy: firstIntr.cy,
                width: firstIntr.width,
                height: firstIntr.height
            ),
            localTransform3x4: [
                [0, 0, 1, 0],
                [-1, 0, 0, 0],
                [0, -1, 0, 0]
            ],
            keyframeCount: keyframes.count
        )

        let bundleKfs: [BundleKeyframe] = try keyframes.enumerated().map { (idx, kf) in
            let count = kf.keypointCount
            let keypoints = try Self.decodeKeypointsBase64(kf.keypoints, count: count)
            let world3d = try Self.decodeWorld3dBase64(kf.world3d, count: count)
            return BundleKeyframe(
                index: idx,
                pose4x4: kf.pose,
                keypoints: keypoints,
                descriptorsB64: kf.descriptors,
                world3d: world3d,
                globalDescriptorB64: kf.globalDescriptor
            )
        }

        return LocalizationBundle(manifest: manifest, keyframes: bundleKfs)
    }

    /// (N, 2) FP32 little-endian base64 → [[Float]] (N×2).
    fileprivate static func decodeKeypointsBase64(_ b64: String, count: Int) throws -> [[Float]] {
        guard let data = Data(base64Encoded: b64) else {
            throw LookupAdaptationError.adaptationFailed(reason: "keypoints base64 decode failed")
        }
        let expected = count * 2 * MemoryLayout<Float32>.size
        guard data.count == expected else {
            throw LookupAdaptationError.adaptationFailed(
                reason: "keypoints size mismatch: got \(data.count) expected \(expected)"
            )
        }
        var result = [[Float]]()
        result.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ptr = raw.bindMemory(to: Float32.self)
            for i in 0..<count {
                result.append([ptr[i * 2], ptr[i * 2 + 1]])
            }
        }
        return result
    }

    /// (N, 3) FP32 little-endian base64 → [[Float]?] (N행). NaN 행 → nil.
    fileprivate static func decodeWorld3dBase64(_ b64: String, count: Int) throws -> [[Float]?] {
        guard let data = Data(base64Encoded: b64) else {
            throw LookupAdaptationError.adaptationFailed(reason: "world3d base64 decode failed")
        }
        let expected = count * 3 * MemoryLayout<Float32>.size
        guard data.count == expected else {
            throw LookupAdaptationError.adaptationFailed(
                reason: "world3d size mismatch: got \(data.count) expected \(expected)"
            )
        }
        var result = [[Float]?]()
        result.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ptr = raw.bindMemory(to: Float32.self)
            for i in 0..<count {
                let x = ptr[i * 3]
                let y = ptr[i * 3 + 1]
                let z = ptr[i * 3 + 2]
                if x.isNaN || y.isNaN || z.isNaN {
                    result.append(nil)
                } else {
                    result.append([x, y, z])
                }
            }
        }
        return result
    }
}
