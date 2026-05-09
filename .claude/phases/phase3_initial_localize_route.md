# Phase 3: 초기 측위 + 경로 데이터 확보

## 상태

**부분 구현 (M2 진행 중)** — V3 측위 → pathfinding → multi-query lookup → keyframe pack 메모리 적재 흐름 동작. 일부 fallback 분기·dtype·NaN 가드 정리 필요.

## 목표

서비스 진입 시점 한 번 실행되는 "초기 데이터 확보" 단계. 카메라 스캔 → **서버 V3 측위로 6DoF 시작 좌표 확보** → pathfinding 으로 경로 step 좌표 시퀀스 확보 → 그 좌표들을 multi-query 로 lookup 해 경로 전체 영역의 keyframe SuperPoint pack 을 한 번에 받아 메모리 적재. 이후 Phase 4 (추적) 로 인계.

> **측위는 V3 only.** `POST /api/slam/v3/localize` 가 유일한 운영 엔드포인트.
> legacy `/api/slam/localize`, `/api/slam/v2/localize`, `/api/v1/buildings/{id}/localize` **사용 X**.
> `useV3Localize` 토글은 항상 `true` 유지 — false 분기는 dead path.

---

## 흐름

```
[startLocalizationFlow]
   │ 카메라 maxImages 장 캡처 (captureInterval 마다, ARFrame transform 도 capturedARPoses 누적)
   ▼
[sendToServerV3]  POST /api/slam/v3/localize  (multipart images[])
   │ → SLAMLocalizeResponse { pose, confidence, mapId, numMatches,
   │                          matchedImageIndex, floorId, floorLevel }
   ▼
[handleLocalizeV3Success]
   │ confidence ≥ 0.3 게이팅
   │ pose → translation + quaternion 분리, localizedPose/FloorId/FloorLevel/ScanId 저장
   │ matchedARPose = capturedARPoses.last  ← V3 응답에 matchedImageIndex 있지만 미사용 (TODO)
   ▼
[startV3Pathfinding]  POST /api/v1/buildings/{id}/pathfinding
   │ request: { startFloorLevel, startX/Y/Z, destinationName,
   │            preference: SHORTEST (legacy/ignored),
   │            verticalPreference: ELEVATOR (default) }
   │ → PathfindingResponse { totalDistance, estimatedTimeSeconds,
   │                         steps[] (stepNumber, floorLevel, position{x,y,z}, instruction, nodeId),
   │                         floorTransitions[], routeMetadata }
   ▼
[fetchBundleForPath]
   │ steps[].position → NetworkBundleProvider.QueryPoint[]  (steps 비면 사용자 좌표 1점 fallback)
   │ pathQueryPoints 보관 + consumedQueryPointIndex = 0  (Phase 4 재 lookup 트리거 시 다음 query 결정용)
   ▼
[NetworkBundleProvider.fetch]  POST /api/v1/buildings/{id}/feature-points/lookup
   │ request: { queries[] (floorLevel, x, y, z, viewDirection?),
   │            options { radiusM=5.0, maxKeyframesPerQuery=5,
   │                      viewConeDeg?, format="json_b64" } }
   │ → FeatureLookupResponse { keyframes[], model, stats }
   ▼
[localizationBundle 저장 + setupTrackingCandidates → startTracking]   →  Phase 4
```

---

## API 스펙 (OpenAPI 검증)

### 3-1. `POST /api/slam/v3/localize` — V3 only

| 항목 | 값 |
|------|-----|
| 요청 | multipart `images: array<string>`, optional `building_id`, `map_id` |
| 응답 200 | `SLAMLocalizeResponse` |
| 필드 | `pose`*, `confidence`*, `mapId`, `numMatches`, `matchedImageIndex`, `floorId`, `floorLevel` |

`pose` 변환: `LocalizeV3Pose.toMatrix4x4()` / `translation` / `rotationQuaternion` (`x/y/z` 모두 Optional — fallback 0 처리, 커밋 `c5a10e3`).

### 3-2. `POST /api/v1/buildings/{buildingId}/pathfinding`

| 필드 | 타입 | 비고 |
|------|------|------|
| `startFloorLevel` | optional | 측위 응답 `pose.floorLevel` 그대로. 없으면 `START_NOT_SPECIFIED` |
| `startX/Y/Z` | number | server world frame meter, 측위 응답 pose translation 그대로 |
| `destinationName` | string | POI `name` 또는 `label` 과 정확히 일치해야 함 |
| `preference` | enum | **legacy/ignored**. metadata 에 echo 만. 신규 클라는 사용 X |
| `verticalPreference` | enum | `ELEVATOR` (기본) / `STAIRS`. 빌딩에 해당 수단 없으면 `PATH_NOT_FOUND` |

응답 `steps[]` 의 `position.x/y/z` 가 다음 단계 lookup 의 query 좌표가 됨.

### 3-3. `POST /api/v1/buildings/{buildingId}/feature-points/lookup`

**요청**:
```
queries: [{ floorLevel*, x*, y*, z, viewDirection? }]
options: {
  radiusM,                 // query 좌표 ± 반경 (m). 너무 크면 byteSize 폭증
  maxKeyframesPerQuery,    // 서버 한계 16
  viewConeDeg?,            // 미사용
  format: "json_b64"       // 현재 유일 지원. msgpack/npz 추후 예정
}
```

**응답 keyframe (FeatureLookupKeyframe)**:
| 필드 | 타입 | 비고 |
|------|------|------|
| `kfId` | string | `<scanId>:<rtabmapNodeId>` 형식 |
| `scanId` | uuid | 소속 scan |
| `floorLevel` | int | 소속 floor |
| `rtabmapNodeId` | int | RTABMap Node id (global_descriptor 와 동일 식별자) |
| `pose` | `array<array>` | **4×4 matrix** |
| `intrinsics` | object | fx, fy, cx, cy, width, height |
| `matchedQueryIndices` | int[] | 이 keyframe 이 어떤 query 에 매칭됐는지 — **Phase 4 prefix drop / 진행도 매핑 활용 여지** |
| `distancesM` | number[] | 각 query 와의 3D 거리 — **"가장 먼 keyframe = 체크포인트" 정공 결정 데이터** |
| `keypointCount` | int | 보통 1024 (모델 max, LightGlue 정적 한도와 일치) |
| `keypoints` | base64 | (N, 2) **float32**, 픽셀 좌표 [u, v] |
| `descriptors` | base64 | (N, 256) **float16** ← ⚠️ 클라에서 **float32 로 cast 필수** |
| `world3d` | base64 | (N, 3) **float32**, world meter. **일부 행 NaN** (3D 추정 실패) — PnP/매칭 전 NaN 필터 필수 |
| `globalDescriptor` | base64? | 옵션. cosine prefilter 용 |

**응답 stats**: `queryCount`, `keyframeCount` (dedup 후), `totalKeypoints`, `byteSize`.

---

## 클라 파라미터

| 이름 | 현재값 | 출처 | 비고 |
|------|--------|------|------|
| `maxImages` (캡처 장수) | 5 | `ARNavigationLogic.captureOneFrame` | V3 multipart 업로드 묶음 |
| `captureInterval` | (코드 확인) | 동일 | 큰 yaw delta 분산 미적용 — 시간 간격 기반 |
| `localize confidence 임계` | 0.3 | `handleLocalizeV3Success:900` | 미만 시 재스캔 안내 |
| lookup `radiusM` | 5.0 m | `fetchBundleForPath:1124` | multi-query 라 작게 |
| lookup `maxKeyframesPerQuery` | 5 | 동일 | 서버 한계 16 — 안전한 보수값 |
| `verticalPreference` | `.elevator` | `startV3Pathfinding:1061` | 사용자 설정 분리 미구현 (TODO) |

서버 hard limit (코드 주석 출처, OpenAPI 에는 명시 없음 — **서버 측 재확인 필요**):
- queries 64
- dedup 후 keyframes 128

---

## 현재 구현 (코드 위치)

| 함수 | 파일:라인 | 책임 |
|------|----------|------|
| `captureOneFrame` | `ARNavigationLogic.swift:655` | ARFrame → UIImage + transform 누적 |
| `sendToServerV3` | `ARNavigationLogic.swift:721` | multipart V3 호출 |
| `handleLocalizeV3Success` | `ARNavigationLogic.swift:893` | confidence 게이팅 + pose 분리 + scanId 저장 |
| `startV3Pathfinding` | `ARNavigationLogic.swift:1043` | pathfinding 호출 (실패 시 lookup fallback) |
| `fetchBundleForPath` | `ARNavigationLogic.swift:1096` | steps → QueryPoint[] + provider fetch |
| `NetworkBundleProvider.fetch` | `Tracking/NetworkBundleProvider.swift:82` | lookup 호출 + adaptation + 캐시 |

---

## 미해결·향후 작업

- [ ] **`matchedImageIndex` 사용** — V3 응답에 있으므로 `capturedARPoses.last` fallback (`918`) 대신 정확한 `capturedARPoses[matchedImageIndex]` 를 `matchedARPose` 로 채택. 좌표 정렬 정확도 향상.
- [ ] **descriptor dtype 변환** — `LookupResponse → LocalizationBundle` adapter 에서 float16 → float32 cast 명시 (Phase 4 LightGlue 입력은 float32).
- [ ] **`world3d` NaN 필터링** — keyframe 단위 NaN 전수 가드 (커밋 `90fcf1b`) 외에 행 단위 필터도 keyframe 적재 시점에 일관 적용.
- [ ] **legacy 측위 dead path 제거** — `sendToServerLegacy` (`:695`), `handleLocalizeSuccess` (legacy SLAMv3 응답 핸들러), `useV3Localize=false` 분기. **V3 only 정책**에 따라 함수 본체와 호출부 모두 정리 후보.
- [ ] **server hard limit 재확인** — queries 64, dedup 128 cap 이 실제로 서버에 박혀 있는지 OpenAPI 외 채널로 검증.
- [ ] **`verticalPreference` 사용자 설정 분리** — UI 토글 + 재요청 fallback (`.elevator` ↔ `.stairs`).
- [ ] **층 전환 잔여 경로 재시작** — `isFloorTransitionRestart=true` 분기에서 pathfinding 호출 생략 + 재 lookup 흐름 미구현 (`handleLocalizeV3Success:941~949` TODO).
- [ ] **`globalDescriptor` cosine prefilter** — keyframe 100+ 시 매칭 후보 축소용 (Phase 4 입력 정리). 응답에 이미 포함됨.
- [ ] **캡처 yaw 분산 정책** — 현재 `captureInterval` 시간 기반. yaw delta 임계 기반 샘플링으로 교체 시 V3 매칭 품질 개선 여지.

---

## 의존성

- 선행: Phase 2 (`SuperPointExtractor` 는 본 phase 에선 미사용 — V3 는 multipart 이미지 업로드. extractor 는 Phase 4 추적 매 tick 에서만 호출).
- 후속: Phase 4 (`localizationBundle` + `pathQueryPoints` + `consumedQueryPointIndex` 인계).
- 클라 단독 측위 (S3 트랙, `runClientLocalize`) 도 후속 흐름은 V3-style — `handleClientLocalizeSuccess` → `startV3Pathfinding` 동일 경로.
