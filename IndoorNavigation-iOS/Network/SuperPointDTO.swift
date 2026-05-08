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

/// Localize V3 응답의 pose. swagger 의 `additionalProp1: {}` 형식 미정 — 두 후보 모두 디코딩 가능하도록 모든 필드 Optional 처리.
struct LocalizeV3Pose: Codable {
    // 추정 A: tx/ty/tz + 쿼터니언 (qx/qy/qz/qw)
    let tx: Double?
    let ty: Double?
    let tz: Double?
    let qx: Double?
    let qy: Double?
    let qz: Double?
    let qw: Double?
    // TODO(서버답): 4×4 행렬로 오면 아래 fallback
    let matrix: [[Double]]?
}

struct LocalizeV3Response: Codable {
    let pose: LocalizeV3Pose
    let confidence: Double
    let mapId: String              // pathfinding startScanId 로 사용
    let numMatches: Int
    let matchedImageIndex: Int
    let floorId: String
    let floorLevel: Int
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
    let startScanId: String              // localize 응답 mapId
    let startFloorLevel: Int?            // 선택 — 없으면 startScanId 로 자동
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
    /// pose 를 4×4 변환 행렬로 변환. matrix 우선, 없으면 tx/ty/tz + 쿼터니언 조합으로 합성.
    /// 둘 다 없으면 nil.
    // TODO(서버답): matrix row-major 가정 — 서버 답 받으면 수정
    func toMatrix4x4() -> simd_float4x4? {
        if let m = matrix, m.count == 4, m.allSatisfy({ $0.count == 4 }) {
            return simd_float4x4(rows: [
                SIMD4<Float>(Float(m[0][0]), Float(m[0][1]), Float(m[0][2]), Float(m[0][3])),
                SIMD4<Float>(Float(m[1][0]), Float(m[1][1]), Float(m[1][2]), Float(m[1][3])),
                SIMD4<Float>(Float(m[2][0]), Float(m[2][1]), Float(m[2][2]), Float(m[2][3])),
                SIMD4<Float>(Float(m[3][0]), Float(m[3][1]), Float(m[3][2]), Float(m[3][3])),
            ])
        }
        if let tx, let ty, let tz, let qx, let qy, let qz, let qw {
            let q = simd_quatf(ix: Float(qx), iy: Float(qy), iz: Float(qz), r: Float(qw))
            var m = simd_float4x4(q)
            m.columns.3 = SIMD4<Float>(Float(tx), Float(ty), Float(tz), 1)
            return m
        }
        return nil
    }

    /// translation 만 별도 추출 (tx/ty/tz 우선, 없으면 matrix 의 마지막 열).
    var translation: simd_float3? {
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
