# Phase 8 서버 API 사양

서버에서 제공하는 3개 endpoint. Phase 8 클라이언트 구현은 본 사양을 기반으로 한다.

미해결 항목은 ⚠️ 로 표시 — 서버 팀 답을 받아 채워야 함.

---

## 1. Localize V3 — 첫 위치 추정

**용도**: AR 진입 시 사용자 카메라 이미지로 빌딩·층·6DoF pose 결정.

**경로**: ⚠️ `POST /api/v1/buildings/{buildingId}/localize/v3` (추정 — 정확한 path 확인 필요)

**Content-Type**: `multipart/form-data`

### Request

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `images` | File[] | ✅ | 위치 추정용 이미지 파일 목록. ⚠️ 권장 개수 / 형식 / 해상도 미정 |
| `building_id` | string | ⚠️ | 건물 ID. 활성 floor map 조회용 |
| `map_id` | string | — | 기존 클라이언트 호환용 (`building_id` 와 동일 처리) |

### Response (200)

```json
{
  "pose": { ⚠️ },        // 형식 미정 — additionalProp1 in swagger
  "confidence": 0.0,
  "mapId": "...",        // 응답으로 받음 → pathfinding 의 startScanId 로 사용
  "numMatches": 0,
  "matchedImageIndex": 0,
  "floorId": "...",
  "floorLevel": 0
}
```

### 에러
- `422 Validation Error`

### 동작 정의
- 활성 floor map 전체에 SuperPoint + LightGlue 매칭
- confidence 가 가장 높은 층 결과 반환

### ⚠️ 미해결 질문
1. **endpoint 정확한 URL** (path/v3 위치)
2. **`pose` 응답 형식** — `tx/ty/tz + qx/qy/qz/qw` ? `4×4 행렬`? `R + t` 별도?
3. **이미지 권장 개수** (1 / 4 / 5 / 그 외) + JPEG vs PNG + 해상도 (raw 1920×1440 그대로?)
4. **confidence 임계값** (이하면 재시도 권장하는 기준)
5. **첫 호출 cache build 영향** (lookup 의 30s~1분과 동일 영향 받는지)
6. **building_id vs map_id** — 둘 다 받는데 우선순위? 같이 보내면?

---

## 2. Pathfinding — 길찾기 (멀티층, 엘베/계단)

**용도**: 첫 로컬라이즈 결과에서 도착 POI 까지 최단 경로 계산. 한 번 호출.

**경로**: `POST /api/v1/buildings/{buildingId}/pathfinding`

**Content-Type**: `application/json`

### Request

```json
{
  "startScanId": "...",            // localize 응답의 mapId
  "startFloorLevel": 0,            // 선택 — startScanId 만 보내면 자동 결정
  "startX": 0, "startY": 0, "startZ": 0,    // localize 응답의 pose.tx/ty/tz
  "destinationName": "301호",
  "preference": "SHORTEST",
  "verticalPreference": "ELEVATOR"  // ELEVATOR | STAIRS (기본 ELEVATOR)
}
```

### Response (200)

```json
{
  "buildingId": "...",
  "totalDistance": 0.0,
  "estimatedTimeSeconds": 0,
  "steps": [
    {
      "stepNumber": 0,
      "floorLevel": 0,
      "position": { "x": 0, "y": 0, "z": 0, "floorLevel": 0 },
      "instruction": "...",
      "nodeId": "..."
    }
  ],
  "floorTransitions": [
    {
      "fromFloorLevel": 0,
      "toFloorLevel": 0,
      "connectorType": "...",
      "connectorKey": "..."
    }
  ],
  "routeMetadata": {
    // verticalPreference, startScanId, startFloorLevel echo
  }
}
```

### 에러
- `404 ACTIVE_SCAN_NOT_FOUND` — 빌딩에 active scan 없음
- `404 START_SCAN_NOT_FOUND` — startScanId 가 active scan 아님
- `404 START_FLOOR_NOT_FOUND` — startFloorLevel 에 active scan 없음
- `422 START_NOT_SPECIFIED` — startScanId / startFloorLevel 둘 다 없음
- `422 SNAP_DISTANCE_EXCEEDED` — 시작 좌표가 그래프에서 5m 초과
- `422 PATH_NOT_FOUND` — 경로 없음. STAIRS 인데 계단 없으면. 클라는 ELEVATOR 로 fallback

### 동작 정의
- 멀티층 자동 라우팅: 같은 connector key 끼리 cross-floor edge
- `verticalPreference` 로 사용자 선호 반영
- `startScanId` 만 있으면 floor 자동 — 클라가 floor_level 직접 관리 X

### ⚠️ 미해결 질문
1. **`steps[].position`** 좌표계 — ARKit world 와 일치하는 단위(m)인지, 별도 변환 필요한지
2. **`floorTransitions[].connectorType`** 가능한 값 (`"elevator"` / `"stairs"` / `"escalator"`?)
3. **빌딩 좌표 원점 vs ARKit 원점** — pathfinding steps 좌표를 ARKit anchor 로 그릴 때 정렬 방식 (이전 npz manifest 의 `local_transform_3x4` 와 동일?)

---

## 3. Feature Points Lookup — keyframe SuperPoint 묶음

**용도**: 좌표 배열 → 각 좌표 주변 keyframe 의 SuperPoint feature pack 반환.
- 패턴 A (route bundle): 길찾기 직후 경로 위 좌표 모두 보내 영역의 keyframe 다운로드
- 패턴 B (실시간): 현재 위치 1개만 보내 1~3 keyframe 받음

**경로**: `POST /api/v1/buildings/{buildingId}/feature-points/lookup`

**Content-Type**: `application/json`

### Request

```json
{
  "queries": [
    {
      "floorLevel": 0,
      "x": 0.0, "y": 0.0, "z": 0.0,
      "viewDirection": [0.0, 0.0, -1.0]   // ⚠️ swagger example 에 [0] 으로 표시 — 실제는 [x, y, z] 추정
    }
  ],
  "options": {
    "radiusM": 2.5,
    "maxKeyframesPerQuery": 5,
    "viewConeDeg": 60,
    "format": "json_b64"
  }
}
```

### Response (200)

```json
{
  "buildingId": "...",
  "keyframes": [
    {
      "kfId": "...",
      "scanId": "...",
      "floorLevel": 0,
      "rtabmapNodeId": 0,
      "pose": [[..4×4..]],
      "intrinsics": { "fx", "fy", "cx", "cy", "width", "height" },
      "matchedQueryIndices": [0],
      "distancesM": [0.0],
      "keypointCount": 0,
      "keypoints": "<base64 (N,2) f32>",
      "descriptors": "<base64 (N,256) f16>",
      "world3d": "<base64 (N,3) f32>",
      "globalDescriptor": "<base64 (384,) f16>"
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
    "queryCount": 0,
    "keyframeCount": 0,
    "totalKeypoints": 0,
    "byteSize": 0
  }
}
```

### 가드레일
- `queries` 최대 64개
- `maxKeyframesPerQuery` 최대 16
- dedup 후 keyframe 총합 128 초과 시 422 — radiusM 줄이거나 query 분할

### 에러
- `422 EMPTY_QUERIES` / `TOO_MANY_QUERIES` / `TOO_MANY_KEYFRAMES`
- `404 ACTIVE_SCAN_NOT_FOUND` / `FLOOR_NOT_FOUND` / `RTABMAP_DB_NOT_FOUND`

### 성능
- **첫 호출 시 floor 별 SuperPoint cache build 30s~1분** (300+ keyframes 기준)
- 이후 cache hit 으로 즉시
- `/admin/superpoint/warmup` 으로 사전 warm-up 가능 (admin 전용 — 클라 호출 X)

### 응답 해석 메모
- `keypoints` (N, 2) f32 / `descriptors` (N, 256) f16 / `world3d` (N, 3) f32 — base64.
  - dtype 정확히 맞춰 디코드 (`model.descriptorDtype` 참조)
- `world3d` NaN 행 다수 — 3D 추정 실패 keypoint. PnP 전 NaN 필터 (현재 우리 클라 이미 처리)
- `pose` 4×4 — **마지막 열 = 카메라 위치 world meter, 3번째 열 = forward direction**
  - ⚠️ camera→world 변환. 우리 PoseEstimate 는 world→camera (PnP 표준) — 매칭 시 inverse 변환 필요
- `globalDescriptor` (DINOv2 384 f16) — retrieval 단계 (top-k 후보 선정) 용
  - ⚠️ 클라는 DINOv2 모델 없음 — 일단 사용 안 함. 후속 검토

### ⚠️ 미해결 질문
1. **`viewDirection` 형식** — swagger example `[0]` 단일 element. 실제 `[x, y, z]` 3 element 가정 맞는지
2. **`format` 옵션** 가능한 값 (`json_b64` 외 binary 옵션 있는지)
3. **다운로드 사이즈 추정** — 패턴 A에서 19 nodes × 5 kf/query → dedup 후 ~64MB 가능. 클라 처리 권장 사항 (스트리밍? 한 번에?)
4. **cache warmup 알림** — 클라가 첫 호출 시 30s~1분 spinner 표시. 진행률 polling 가능한 endpoint 있는지
