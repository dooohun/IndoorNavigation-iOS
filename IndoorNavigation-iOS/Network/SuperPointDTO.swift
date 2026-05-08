//
//  SuperPointDTO.swift
//  IndoorNavigation-iOS
//
//  Phase 8 B1 — SuperPoint 서버 3 endpoint DTO.
//  ⚠️ 미해결 가정 항목은 TODO(서버답) 마커로 grep 가능.
//

import Foundation
import simd

// MARK: - 공용 타입

/// 매핑 좌표계의 위치 (m).
struct WorldPosition: Codable {
    let x: Double
    let y: Double
    let z: Double
    let floorLevel: Int
}

// MARK: - 1. Localize V3

/// `POST /api/v1/buildings/{buildingId}/localize/v3` 의 multipart 메타용 컨테이너.
/// **Codable 미사용** — 실제 multipart body 빌드는 NetworkManager(B2) 책임. 본 struct 는 호출자가 인자 묶음으로 전달할 때 쓰는 값 객체.
struct LocalizeV3Request {
    let images: [Data]      // JPEG 권장. ⚠️ 권장 개수/해상도 미정 — TODO(서버답)
    let buildingId: String  // UUID 문자열
}

/// Localize V3 응답의 pose. 서버 swagger 가 `additionalProperties: true` 자유 schema —
/// 들어올 가능성 있는 필드 모두 Optional 로 보존하여 어떤 형식이든 디코딩 실패하지 않게.
/// 실측 (2026-05-08): 서버는 `x/y/z + qx/qy/qz/qw + floorLevel` 채움. tx/ty/tz/matrix 는 빈 채로 옴.
struct LocalizeV3Pose: Codable {
    // 실측 형식: x/y/z + 쿼터니언 (qx/qy/qz/qw)
    let x: Double?
    let y: Double?
    let z: Double?
    // 변형 가정 보존: tx/ty/tz (다른 endpoint 또는 향후 변경 대비)
    let tx: Double?
    let ty: Double?
    let tz: Double?
    let qx: Double?
    let qy: Double?
    let qz: Double?
    let qw: Double?
    // 4×4 행렬 형식 fallback
    let matrix: [[Double]]?
    // pose object 안에 floorLevel/floorId 채워짐 (실측 확인).
    let floorLevel: Int?
    let floorId: String?
}

/// 서버 swagger `LocalizeResponse` 정합:
/// required: buildingId / pose / confidence. nullable: mapId. optional: candidates(자유 object — 디코드 무시).
struct LocalizeV3Response: Codable {
    let buildingId: String
    let mapId: String?            // nullable — pathfinding startScanId 로 사용
    let pose: LocalizeV3Pose
    let confidence: Double
    // candidates: [object] 자유 schema — 클라 미사용. JSONDecoder 가 모르는 키 자동 무시.
}

// MARK: - 2. Pathfinding

enum VerticalPreference: String, Codable {
    case elevator = "ELEVATOR"
    case stairs = "STAIRS"
}

enum RoutePreference: String, Codable {
    case shortest = "SHORTEST"
    // TODO(서버답): FASTEST/ACCESSIBLE 등 추가 값 확인
}

struct PathfindingRequest: Codable {
    let startScanId: String?             // localize 응답 mapId (서버 nullable). 둘 중 하나는 채워야 함.
    let startFloorLevel: Int?            // 선택 — startScanId 가 있으면 무시됨
    let startX: Double
    let startY: Double
    let startZ: Double
    let destinationName: String          // POI 이름
    let preference: RoutePreference?
    let verticalPreference: VerticalPreference?
}

struct PathfindingStep: Codable {
    let stepNumber: Int
    let floorLevel: Int
    let position: WorldPosition
    let instruction: String?
    let nodeId: String
}

struct FloorTransition: Codable {
    let fromFloorLevel: Int
    let toFloorLevel: Int
    let connectorType: String   // TODO(서버답): enum 후보값 확인 후 enum 승격 ("elevator"/"stairs"/"escalator"?)
    let connectorKey: String
}

struct PathfindingResponse: Codable {
    let buildingId: String
    let totalDistance: Double
    let estimatedTimeSeconds: Int
    let steps: [PathfindingStep]
    let floorTransitions: [FloorTransition]
    // TODO(서버답): routeMetadata 자유 스키마 — 필요 시 [String: AnyCodable] 추가
}

// MARK: - 3. Feature Points Lookup

struct LookupQuery: Codable {
    let floorLevel: Int
    let x: Double
    let y: Double
    let z: Double
    let viewDirection: [Double]?  // 가정: [x, y, z]. TODO(서버답) — swagger example 은 [0] 단일 element
}

struct LookupOptions: Codable {
    let radiusM: Double?
    let maxKeyframesPerQuery: Int?
    let viewConeDeg: Double?
    let format: String?           // 기본 "json_b64"
}

struct LookupRequest: Codable {
    let queries: [LookupQuery]
    let options: LookupOptions?
}

struct KeyframeIntrinsics: Codable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let width: Int
    let height: Int
}

struct LookupKeyframe: Codable {
    let kfId: String
    let scanId: String
    let floorLevel: Int
    let rtabmapNodeId: Int
    let pose: [[Double]]              // 4×4. 마지막 열 = 카메라 위치, 3번째 열 = forward
    let intrinsics: KeyframeIntrinsics
    let matchedQueryIndices: [Int]
    let distancesM: [Double]
    let keypointCount: Int
    let keypoints: String              // base64 (N,2) f32
    let descriptors: String            // base64 (N,256) f16
    let world3d: String                // base64 (N,3) f32 — NaN 행 포함 가능
    let globalDescriptor: String       // base64 (384,) f16 — DINOv2
}

struct LookupModel: Codable {
    let extractor: String              // "superpoint_v1"
    let matcher: String                // "superpoint_lightglue"
    let descriptorDim: Int             // 256
    let maxKeypoints: Int              // 1024
    let descriptorDtype: String        // "float16"
    let globalDescriptorDim: Int       // 384
    let globalDescriptorExtractor: String  // "dinov2"
}

struct LookupStats: Codable {
    let queryCount: Int
    let keyframeCount: Int
    let totalKeypoints: Int
    let byteSize: Int
}

struct LookupResponse: Codable {
    let buildingId: String
    let keyframes: [LookupKeyframe]
    let model: LookupModel
    let stats: LookupStats
}

// MARK: - LocalizeV3Pose helpers

extension LocalizeV3Pose {
    /// pose 를 4×4 변환 행렬로 변환. matrix 우선, 없으면 (x/y/z 또는 tx/ty/tz) + 쿼터니언 조합.
    /// 둘 다 없으면 nil.
    func toMatrix4x4() -> simd_float4x4? {
        if let m = matrix, m.count == 4, m.allSatisfy({ $0.count == 4 }) {
            return simd_float4x4(rows: [
                SIMD4<Float>(Float(m[0][0]), Float(m[0][1]), Float(m[0][2]), Float(m[0][3])),
                SIMD4<Float>(Float(m[1][0]), Float(m[1][1]), Float(m[1][2]), Float(m[1][3])),
                SIMD4<Float>(Float(m[2][0]), Float(m[2][1]), Float(m[2][2]), Float(m[2][3])),
                SIMD4<Float>(Float(m[3][0]), Float(m[3][1]), Float(m[3][2]), Float(m[3][3])),
            ])
        }
        // x/y/z (실측 형식) 우선, 없으면 tx/ty/tz fallback
        let px = x ?? tx
        let py = y ?? ty
        let pz = z ?? tz
        if let px, let py, let pz, let qx, let qy, let qz, let qw {
            let q = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
            var m = simd_float4x4(q)
            m.columns.3 = SIMD4<Float>(Float(px), Float(py), Float(pz), 1)
            return m
        }
        return nil
    }

    /// translation 추출. x/y/z (실측 형식) 우선, 없으면 tx/ty/tz, 마지막으로 matrix 마지막 열.
    var translation: simd_float3? {
        if let x, let y, let z {
            return simd_float3(Float(x), Float(y), Float(z))
        }
        if let tx, let ty, let tz {
            return simd_float3(Float(tx), Float(ty), Float(tz))
        }
        if let m = matrix, m.count == 4, m[0].count == 4 {
            return simd_float3(Float(m[0][3]), Float(m[1][3]), Float(m[2][3]))
        }
        return nil
    }

    /// rotation 만 별도 추출 (qx/qy/qz/qw 우선, 없으면 matrix 의 좌측 3×3 블록에서 변환).
    var rotationQuaternion: simd_quatf? {
        if let qx, let qy, let qz, let qw {
            return simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
        }
        if let m = toMatrix4x4() {
            // 좌측 3×3 블록에서 quaternion 추출
            let r = simd_float3x3(
                simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            )
            return simd_quatf(r)
        }
        return nil
    }
}

// MARK: - Pathfinding helpers

extension PathfindingResponse {
    /// PathfindingResponse.steps[] → 기존 PathStep 모델 변환.
    /// floorTransitions[] 는 detectFloorTransition 이 step 변화로 자동 처리.
    func toPathSteps() -> [PathStep] {
        return steps.map { s in
            PathStep(
                stepNumber: s.stepNumber,
                floorLevel: s.floorLevel,
                position: Position(x: s.position.x, y: s.position.y, z: s.position.z),
                instruction: s.instruction
            )
        }
    }
}

// MARK: - Lookup → LocalizationBundle 어댑터

/// `LookupResponse → LocalizationBundle` 변환 중 발생하는 어댑팅 오류.
/// NetworkBundleProvider 가 fetch 결과를 검증·매핑할 때 throw.
enum LookupAdaptationError: Error, CustomStringConvertible {
    case adaptationFailed(reason: String)

    var description: String {
        switch self {
        case .adaptationFailed(let reason):
            return "lookup → bundle 변환 실패: \(reason)"
        }
    }
}

extension LookupResponse {

    /// `LookupResponse` 를 기존 `LocalizationBundle` (mock 디코딩 구조와 동일) 로 어댑팅.
    /// - Parameters:
    ///   - scanIdOverride: nil 이면 첫 keyframe.scanId 사용
    ///   - floorIdOverride: nil 이면 빈 문자열 (TODO 서버답)
    ///   - destination: manifest.destination 에 주입
    /// - Throws: `LookupAdaptationError.adaptationFailed`
    func toLocalizationBundle(
        scanIdOverride: String? = nil,
        floorIdOverride: String? = nil,
        destination: String = ""
    ) throws -> LocalizationBundle {
        guard let firstKf = keyframes.first else {
            throw LookupAdaptationError.adaptationFailed(reason: "empty keyframes")
        }

        // intrinsics 동질성 가드 — 모든 keyframe 이 동일 intrinsics 라고 가정
        // TODO(서버답): keyframe 별 intrinsics 다를 가능성 시 schema 협의
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
            // TODO(서버답): floorId 매핑 (lookup 응답에는 floorId 없음 — floorLevel 만)
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
            // TODO(서버답): lookup 응답에 local_transform 추가 시 교체. 현재는 mock 값 hardcode.
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
    /// byte 길이 == count*2*4 가 아니면 throw.
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
    /// byte 길이 == count*3*4 가 아니면 throw.
    /// TODO(서버답): NaN 인코딩 형식 확인 — 현재 row 의 모든 컴포넌트가 NaN 이면 nil 처리
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
