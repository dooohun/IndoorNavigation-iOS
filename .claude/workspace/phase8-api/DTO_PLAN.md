# Phase 8 DTO 계획

서버 3 endpoint 의 요청·응답을 Swift `Codable` struct 로 정의. ⚠️ 항목은 서버 답 받기 전이라 잠정.

---

## 공용 타입

```swift
/// 매핑 좌표계의 위치 (m).
struct WorldPosition: Codable {
    let x: Double
    let y: Double
    let z: Double
    let floorLevel: Int
}
```

---

## 1. Localize V3

### Request

multipart/form-data 라 `Codable` 직접 매핑 X. `URLRequest` 수동 구성 (`NetworkManager` 측).

| 필드 | 타입 | 비고 |
|------|------|------|
| `images` | `[Data]` | JPEG. ⚠️ 권장 개수 / 해상도 미정 |
| `building_id` | `String` | UUID 문자열 |

### Response

⚠️ `pose` 형식 미정. swagger 의 `additionalProp1: {}` — 추정 후보:

```swift
// 추정 A: tx/ty/tz + 쿼터니언
struct LocalizeV3Pose: Codable {
    let tx: Double
    let ty: Double
    let tz: Double
    let qx: Double?  // ⚠️ 회전 표현이 quat 인지 4x4 인지 불확실
    let qy: Double?
    let qz: Double?
    let qw: Double?
    let matrix4x4: [[Double]]?  // ⚠️ 또는 4x4 행렬 형태
}

// 추정 B: 4x4 행렬만
typealias LocalizeV3Pose = [[Double]]
```

```swift
struct LocalizeV3Response: Codable {
    let pose: LocalizeV3Pose       // ⚠️ 형식 확정 필요
    let confidence: Double
    let mapId: String              // pathfinding startScanId 로 사용
    let numMatches: Int
    let matchedImageIndex: Int
    let floorId: String
    let floorLevel: Int
}
```

---

## 2. Pathfinding

### Request

```swift
enum VerticalPreference: String, Codable {
    case elevator = "ELEVATOR"
    case stairs = "STAIRS"
}

enum RoutePreference: String, Codable {
    case shortest = "SHORTEST"
    // ⚠️ 다른 값 가능한지 (예: FASTEST, ACCESSIBLE) — 사양 확인
}

struct PathfindingRequest: Codable {
    let startScanId: String              // localize 응답 mapId
    let startFloorLevel: Int?            // 선택 — 보내면 명시 floor
    let startX: Double
    let startY: Double
    let startZ: Double
    let destinationName: String          // POI 이름
    let preference: RoutePreference?
    let verticalPreference: VerticalPreference?
}
```

### Response

```swift
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
    let connectorType: String   // ⚠️ enum 후보값 미정 ("elevator"/"stairs"/"escalator")
    let connectorKey: String
}

struct PathfindingResponse: Codable {
    let buildingId: String
    let totalDistance: Double
    let estimatedTimeSeconds: Int
    let steps: [PathfindingStep]
    let floorTransitions: [FloorTransition]
    let routeMetadata: [String: AnyCodable]?  // ⚠️ schema 자유. AnyCodable 또는 무시
}
```

---

## 3. Feature Points Lookup

### Request

```swift
struct LookupQuery: Codable {
    let floorLevel: Int
    let x: Double
    let y: Double
    let z: Double
    let viewDirection: [Double]?   // ⚠️ swagger [0] 표시 — 실제 [x, y, z] 추정
}

struct LookupOptions: Codable {
    let radiusM: Double?           // 기본 2.5
    let maxKeyframesPerQuery: Int? // 최대 16
    let viewConeDeg: Double?       // 기본 60
    let format: String?            // "json_b64"
}

struct LookupRequest: Codable {
    let queries: [LookupQuery]     // 최대 64
    let options: LookupOptions?
}
```

### Response

```swift
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
    let pose: [[Double]]                    // 4×4. 마지막 열 = 카메라 위치, 3번째 열 = forward
    let intrinsics: KeyframeIntrinsics
    let matchedQueryIndices: [Int]
    let distancesM: [Double]
    let keypointCount: Int
    let keypoints: String                   // base64 (N, 2) f32
    let descriptors: String                 // base64 (N, 256) f16
    let world3d: String                     // base64 (N, 3) f32 — NaN 행 포함
    let globalDescriptor: String            // base64 (384,) f16 — DINOv2

    // 디코드 헬퍼는 별도 extension 으로 분리 (e.g. decodedKeypoints() -> [SIMD2<Float>])
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
```

---

## 기존 모델과의 매핑

현재 mock 인프라(`LocalizationBundle`)는 npz manifest 기반인데, 운영 endpoint(`LookupResponse`)는 manifest 없이 `keyframes[]` 만 반환. 차이 정리:

| 정보 | mock `LocalizationBundle` | 운영 `LookupResponse` | 처리 |
|------|--------------------------|---------------------|------|
| 빌딩·층·destination | `manifest` 안 | localize/pathfinding 응답에 분산 | 컨텍스트로 보관 |
| intrinsics | `manifest.intrinsics` (단일) | `keyframes[].intrinsics` (per-keyframe) | 클라가 keyframe별 사용 |
| local_transform_3x4 | `manifest.localTransform3x4` | ⚠️ 없음 | 별도 endpoint 또는 manifest 캐싱? |
| keyframe pose | `keyframes[].pose4x4` | `keyframes[].pose` | 그대로 (단 컨벤션 일치 확인) |
| keypoints / descriptors / world_3d | 동일 | 동일 (필드 이름만 다름) | 디코딩 로직 재사용 |

→ **`LocalizationBundle` 은 mock 전용으로 유지하고, 운영 응답은 별도 `LookupResponse` DTO** 로 정의. `MockBundleProvider` → `NetworkBundleProvider` 교체 시점에 둘 사이 변환 layer 만들거나, 매칭 인프라가 양쪽 형식 모두 받도록 조정.

---

## ⚠️ 미해결 질문 → 답 받으면 정확화

| 항목 | 현재 가정 | 서버 답 | 확정 |
|------|---------|---------|------|
| localize/v3 endpoint URL | `/api/v1/buildings/{id}/localize/v3` | ⚠️ | |
| pose 응답 형식 | `tx/ty/tz + qx/qy/qz/qw` | ⚠️ | |
| 권장 이미지 개수 | 4장 (yaw 분산) | ⚠️ | |
| 이미지 형식·해상도 | JPEG, 1920×1440 raw 또는 다운스케일 | ⚠️ | |
| confidence 임계 | (미정) | ⚠️ | |
| building_id vs map_id | building_id 사용, map_id 호환용 | ⚠️ | |
| pathfinding `connectorType` 값 | `"elevator" / "stairs" / "escalator"` 추정 | ⚠️ | |
| pathfinding 좌표계 | ARKit world 와 동일 m 단위 | ⚠️ | |
| lookup `viewDirection` | `[x, y, z]` 3 element | ⚠️ | |
| lookup 첫 호출 cache build 진행률 | (정보 없음 — spinner 만) | ⚠️ | |
| pose 4×4 변환 방향 | camera→world (lookup), world→camera (PnP) | ⚠️ | |
| local_transform_3x4 endpoint | (lookup 응답에 없음 — 별도 endpoint?) | ⚠️ | |

---

## 다음 작업 순서

1. ⚠️ 미해결 질문 답 받기 → 본 문서 ⚠️ 영역 채움
2. **B1**: 위 DTO struct 들 Swift 파일로 작성 + Codable 단위 테스트 (mock JSON 인코딩/디코딩)
3. **B2**: NetworkManager 3 endpoint 메서드 + 모킹 응답
4. **B3~B7**: 단계별 통합 (CLIENT_FLOW.md 의 단계별 PR 분리 참조)
