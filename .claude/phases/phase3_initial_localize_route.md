# Phase 3: 초기 측위 + 경로 데이터 확보 + 주기 재측위

## 상태

**부분 구현 (M2 진행 중) + 주기 재측위 활성** — V3 측위 → pathfinding → multi-query lookup → keyframe pack 메모리 적재 흐름 동작. LightGlue 추적 정지(2026-05-10) 이후 ARKit pose drift 보정을 위해 **주기 V3 재측위(2026-05-12)** 도입. lookup 흐름은 본문 보존 + early return.

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

## 주기 재측위 (2026-05-12 추가)

LightGlue 추적이 비활성된 상태에서 ARKit pose 누적 drift 를 보정하기 위해 초기 V3 측위 성공 직후 cadence 마다 V3 호출.

### 흐름

```
[handleLocalizeV3Success]  ← 초기 측위 성공
   │ startV3Pathfinding 호출 직후
   ▼
[startPeriodicRelocalize]
   │ periodicRelocalizeTimer = Timer (interval=10s, repeat=true)
   │
   ▼ (매 10초)
[runPeriodicRelocalizeTick]
   │ guard !isPeriodicRelocalizeInFlight (중복 호출 차단)
   │ guard !hasActiveFloorTransition (층 전환 중 skip)
   │ guard !hasNotifiedArrival (도착 후 skip)
   │ guard arSession.currentFrame != nil (AR 미준비 skip)
   │ guard 이동 거리 (cam XZ) >= 2.0m (정지 상태 skip — 첫 cadence 는 강제 통과)
   │ lastPeriodicRelocalizeCameraPos = curCamPos (다음 cadence 비교용)
   │ periodicCapturedImages = [] / periodicCapturedARPoses = []
   │ periodicCaptureStartTime = now (timeout 기준)
   │ periodicRelocalizeCaptureTimer = Timer (interval=0.4s) → capturePeriodicFrame() × 3
   │       └─ limited tracking 이 5s 이상 지속되면 abort + in-flight 락 해제
   ▼
[sendPeriodicRelocalize]
   │ NetworkManager.localizeV3(buildingId:images:)
   ▼
[handlePeriodicRelocalizeSuccess]
   │ confidence < 0.3 → 무시
   │ response.pose.floorLevel ≠ localizedFloorLevel → 무시 (다른 층 가드)
   │ localizedPose = blend(prev, response, alpha=0.3)
   │      translation: simd_mix
   │      quaternion : simd_slerp
   │ matchedARPose = hard-set (캡처 시점 ARFrame transform — blend X, 좌표 변환식 정합성)
   │ drawPathFromSteps(lastPathSteps) + refreshFloorNavigationMap (재렌더)
```

### 정지 지점

| 지점 | 호출 |
|------|------|
| `resetForNewTrial` | 새 trial 시작 시 — 모든 타이머·in-flight 플래그 초기화 |
| `triggerFloorTransition` | 층 전환 모달 표시 시 — 다른 층 응답 방어 |
| `checkArrival` 도착 성공 | 더 이상 보정 불필요 |
| `ARNavigationViewController.viewWillDisappear` | 화면 dismiss 시 |

### 파라미터

| 이름 | 현재값 | 비고 |
|------|--------|------|
| `periodicRelocalizeIntervalSec` | 10.0 | cadence — 발열·배터리 vs drift 보정 균형 |
| `periodicRelocalizeImageCount` | 3 | 주기 보정용 경량화 (초기 측위 5장 대비 60%) — 발열·트래픽 절감 |
| `periodicRelocalizeCaptureInterval` | 0.4 | 3장 캡처에 ~1.2초 |
| `periodicRelocalizeBlendAlpha` | 0.3 | 신 측위 가중치. 1.0 = hard-set, 0.0 = 무시 |
| `periodicRelocalizeMinTravelM` | 2.0 | 직전 발사 시점 카메라 위치 대비 XZ 이동 거리 가드. 정지 상태 V3 호출 회피 |
| `periodicRelocalizeCaptureTimeoutSec` | 5.0 | 캡처 시작 후 N장 도달 timeout. limited tracking 무한 대기 → 데드락 방지 |
| `confidence 임계` | 0.3 | 초기 측위와 동일 |

### 정책

- **matchedARPose**: hard-set 유지 (`blendAlpha=0.3` 적용 X). 좌표 변환식 정합성 — 측위 응답 pose 와 짝지을 AR frame 은 캡처 시점의 그것 그대로여야 함.
- **다른 층 응답 가드**: `response.pose.floorLevel` 이 현재 `localizedFloorLevel` 과 다르면 결과 무시 + 로그 출력. 잘못된 층 측위로 인한 path 재렌더 오류 방어.
- **lookup 비활성화**: `fetchBundleForPath` / `triggerNewLookup` 본문은 보존하되 `Self.useLightGlueMatcher` 가 false 면 early return. LightGlue 재활성화 시 본문 그대로 복귀 가능.
- **이동 거리 2m 가드**: cadence 진입 시 직전 발사 시점 카메라 위치(XZ) 와의 거리가 2m 미만이면 skip. 정지 상태에서 매 10초 V3 호출되는 발열·트래픽 낭비 회피. 첫 cadence 는 캐시 nil 이라면 강제 통과 (단, `handleLocalizeV3Success` 에서 초기 측위 시점의 카메라 위치를 미리 캐시하므로 정지 상태에선 첫 cadence 도 skip 됨).
- **캡처 timeout 5s**: ARKit `trackingState == .limited` 가 0.4s tick 마다 영속되면 3장에 도달 못 해 in-flight 락이 영구 점유될 위험. 캡처 시작 후 5s 초과 시 abort 하고 `isPeriodicRelocalizeInFlight = false` 로 락 해제 → 다음 cadence 에서 재시도.

### 미해결

- [ ] cadence 사용자/환경별 튜닝 (배터리 vs drift 균형)
- [ ] blend alpha 동적 조정 (drift 크기에 따라 강한 보정 / 약한 보정)
- [ ] 다른 층 응답 N회 연속 시 강제 재측위 트리거 (현재는 무한 무시)
- [ ] confidence 추세 로깅 (반복 측위 confidence 변화 추적)

#### 시각적 점프 / 깜빡임 (사용자 경험)

주기 측위는 silent 정책 + blend α=0.3 + 2m 가드로 진폭·빈도를 줄였지만, 다음 세 가지가 사용자 시야에 그대로 노출됨. 보정 시점에 chevron / 미니맵 / step card 가 깜빡인다는 보고가 있을 때 우선 검토할 항목.

- [ ] **chevron 통째 재생성**: `PathChevronController.setRoute` 가 기존 entries 를 전부 `removeFromParentNode` 후 새 좌표로 spawn — 보간/페이드 전환 없음. blend 로 좌표 차이가 작아도 노드는 사라졌다 다시 나타남. **대응안**: setRoute 가 직전 좌표와 비교해 차이 < threshold 면 노드 재사용 + 위치만 보간 트윈 (SCNAction.move(to:duration:)). 신규 경로는 기존처럼 통째 재생성.
- [ ] **`drawPathFromSteps` 의 진행 상태 리셋**: 보정 시에도 `currentStepIndex = 0` + `updateTurnArrow(nil)` + `updateMarkers([])` 가 실행되어 turn arrow / marker 가 빈 상태로 갔다가 다음 1Hz tick 에서 재산정됨 → 짧은 깜빡임. **대응안**: `drawPathFromSteps` 가 "신규 경로" 와 "주기 측위 보정 재렌더" 를 구분하는 모드 인자 추가. 보정 모드면 `currentStepIndex` / turn arrow / marker 유지.
- [ ] **미니맵 마커 점프**: `refreshFloorNavigationMap` 도 보정마다 호출되어 현재 위치 마커가 blend 차이만큼 점프. **대응안**: 미니맵 마커 위치를 직전값과 보간 (NavigationMapView 측 트윈 도입).

휴리스틱 옵션 (위 세 가지와 별도/보완):
- [ ] 카메라 yaw 가 chevron 정면을 향하지 않을 때만 보정 적용 — 사용자 시야 밖에서 처리해 점프 자체를 안 보이게.

---

## 의존성

- 선행: Phase 2 (`SuperPointExtractor` 는 본 phase 에선 미사용 — V3 는 multipart 이미지 업로드. extractor 는 Phase 4 추적 매 tick 에서만 호출).
- 후속: Phase 4 (`localizationBundle` + `pathQueryPoints` + `consumedQueryPointIndex` 인계).
- 클라 단독 측위 (S3 트랙, `runClientLocalize`) 도 후속 흐름은 V3-style — `handleClientLocalizeSuccess` → `startV3Pathfinding` 동일 경로.
