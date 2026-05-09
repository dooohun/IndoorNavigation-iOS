# Phase 4: keyframe 추적 + 체크포인트 표시

## 상태

**구현됨 (M2 핵심부)** — Phase 3 이 적재한 `localizationBundle` 을 입력으로 받아 매 tick LightGlue 매칭 + prefix drop + 단일 흰색 원형 `checkpointNode` 표시까지 동작. PnP 는 폐기 (커밋 `c1546ef`). 신뢰도 임계·회전 사용·prefilter 등 미완.

## 목표

추적 메인 루프. cadence 마다 ARFrame 1장 → SuperPoint 추출 → 후보 keyframe 들과 LightGlue 매칭 → best keyframe 까지 후보열 prefix drop ("지워나감") → 목적지쪽 끝 keyframe 위치에 체크포인트 UI 갱신. 사용자 위치 추정은 best keyframe 의 server 좌표 그대로 사용.

---

## 흐름 (매 tick)

```
[trackingTimer fire (cadence 2s)]
   │
   ▼
[runTrackingTick]
   │ guard: 직전 tick 완료 + bundle/extractor/matcher/후보 존재
   │ snapshot: candidates, intrinsics, ARFrame(pixelBuffer, intrinsics, timestamp, transform), orientation
   │ isTrackingTickInFlight = true
   ▼
[trackingQueue (userInitiated, background)]
   │ extractor.extract(image, intrinsics, timestamp, orientation) → SuperPointFrame (queryFrame)
   │ for kf in candidatesSnapshot:
   │     engine.match(query: queryFrame, targetKeyframe: kf, targetIntrinsics: bundle.manifest.intrinsics)
   │     → (idx, matched count)
   │ best = argmax(matched count)   [best 없으면 후보 유지 + skip]
   ▼
[handleTrackingMatchResult — main]
   │ guard bestIdx < trackingKeyframeCandidates.count  (race 가드 — count 만)
   │ trackingKeyframeCandidates = candidates[bestIdx...]   ← prefix drop
   │ localizedPose.x/y/z ← best keyframe pose4x4 마지막 열 (translation)
   │ localizedPose.q*    ← 기존 값 유지 (회전 미적용 TODO)
   │ matchedARPose ← arPoseAtCapture
   ▼
[updateCheckpointNode]
   │ targetKf = trackingKeyframeCandidates.last   ← 후보열 끝 = goal 쪽 가장 가까운 미통과 keyframe
   │ CoordinateTransformer.transform(serverPoint: targetKf 위치, input: serverPose+arCameraPose)
   │ floorY = arPose.columns.3.y - 1.7   (카메라 높이 → 바닥)
   │ node 없으면 createCheckpointNode + scene 추가, 있으면 position 갱신
   ▼
[Phase 5 트리거 분기]
   │ if candidates.count ≤ 1 → triggerNewLookup() (Phase 5)
   │ if candidates.count ≤ 1 + consumedQueryPointIndex 끝 + 카메라↔checkpoint XZ < 1.0m → 도착 (Phase 5)
```

---

## 후보열 정렬 (`setupTrackingCandidates`)

`bundle.keyframes` 를 **goal 까지 3D 거리 내림차순** 으로 정렬:

```
trackingKeyframeCandidates = bundle.keyframes.sorted { distanceToGoal(a) > distanceToGoal(b) }
```

| 인덱스 | 의미 |
|--------|------|
| 0 | goal 에서 가장 **먼** keyframe (= 사용자 시작 위치 근처) |
| 마지막 | goal 에서 가장 **가까운** keyframe (= 다음 행동 지점) |

→ 사용자 진행 → best 매칭이 더 뒤쪽(목적지쪽) 인덱스로 이동 → prefix drop 으로 앞쪽(이미 통과한 시작쪽) 잘라냄.

→ **체크포인트 = `candidates.last`** = 추적 영역 내 goal 쪽 가장 가까운 미통과 keyframe.
(사용자 표현 "현재 위치에서 가장 먼 superpoint" 는 정확히는 "**후보열 끝 = goal 방향 다음 keyframe**". 일반적으로 사용자 기준 가장 멀지만, prefix drop 결과라 완벽 보장은 아님.)

---

## checkpointNode UI

| 요소 | 사양 |
|------|------|
| 형태 | torus (테두리) + cylinder (얇은 원판) |
| 테두리 | `SCNTorus(ringRadius: 0.45, pipeRadius: 0.04)`, 흰색 |
| 채움 | `SCNCylinder(radius: 0.45, height: 0.005)`, 흰색 alpha 0.6 |
| 머티리얼 | `lightingModel = .constant`, `writesToDepthBuffer = false`, `isDoubleSided = true` |
| 배치 | server 좌표 → `CoordinateTransformer.transform(serverPoint, input)` → AR world. y 는 카메라 높이 - 1.7 (바닥 추정) |
| 갱신 | 노드 없으면 신규 생성 + `scene.rootNode.addChildNode`, 있으면 `position` 만 갱신 |

---

## 파라미터

| 이름 | 현재값 | 출처 |
|------|--------|------|
| `trackingCadenceSec` | 2.0 s | `ARNavigationLogic.swift:170` |
| `trackingQueue` | `userInitiated` DispatchQueue | `:174` |
| `trackingArrivalThresholdM` | 1.0 m (Phase 5 도착 판정) | `:178` |
| 카메라 → 바닥 오프셋 | -1.7 m | `updateCheckpointNode` |
| best 매칭 신뢰도 임계 | **없음** | — |

---

## 현재 구현 (코드 위치)

| 함수 | 파일:라인 | 책임 |
|------|----------|------|
| `setupTrackingCandidates` | `ARNavigationLogic.swift:1559` | bundle.keyframes 를 goal 까지 거리 내림차순 정렬 |
| `distanceToGoal` | `:1577` | keyframe pose translation ↔ goal 3D 거리 |
| `startTracking` / `stopTracking` | `:1396` / `:1420` | trackingTimer 시작·중지 |
| `runTrackingTick` | `:1426` | snapshot + background extractor/matcher 호출 |
| `handleTrackingMatchResult` | `:1489` | prefix drop + pose 갱신 + checkpoint 갱신 |
| `updateCheckpointNode` | `:1589` | 후보 마지막 → AR 좌표 변환 → 노드 갱신 |
| `createCheckpointNode` | `:1634` | torus + cylinder 노드 생성 |

---

## 미해결·향후 작업

- [ ] **회전 (R → quat) 사용** — best keyframe pose4x4 의 회전부 추출해 `localizedPose.q*` 갱신. 현재는 V3 측위 시점 회전 유지 → 사용자 자세 정확도 한계 (`handleTrackingMatchResult:1518` TODO).
- [ ] **best 매칭 신뢰도 임계** — `bestMatched` 가 너무 낮을 때 prefix drop 차단 (false positive 방지). 현재 매칭 0 만 아니면 무조건 drop.
- [ ] **`globalDescriptor` cosine prefilter** — keyframe 100+ 시 매 tick 전체 매칭 비용 폭증. lookup 응답 `globalDescriptor` 로 후보 축소.
- [ ] **keyframe 별 intrinsics 사용** — 현재 `bundle.manifest.intrinsics` 단일 값. 응답 `keyframes[].intrinsics` 활용 여지.
- [ ] **race 가드 강화** — 현재 `bestIdx < count` 만. `lastBestKeyframeIndex` 비교로 stale snapshot 명시 처리.
- [ ] **`world3d` NaN 행 필터** — Phase 3 에서 keyframe 단위 가드만 있고, 행 단위 필터는 매칭 입력 시점에 미적용. PnP 부활 시 필수.
- [ ] **여러 ARFrame 평균** — 현재 tick 마다 1장. 5장 평균 또는 inlier 최대 선택으로 안정화 (`sendToServer:748` TODO 와 동일 맥락).
- [ ] **추적 실패 카운터** — 매칭 0 연속 N회 시 Phase 5 재 lookup 외 강제 재측위(V3) 트리거 정책 미정.

---

## 의존성

- 선행: Phase 2 (extractor / matcher), Phase 3 (`localizationBundle`, `pathQueryPoints`, `consumedQueryPointIndex` 인계).
- 후속: Phase 5 (재 lookup, 도착 판정 — `triggerNewLookup` + `trackingArrivalThresholdM` 판정 분기는 Phase 5 책임).
