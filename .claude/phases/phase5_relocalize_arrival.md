# Phase 5: 재 lookup + 도착 처리

## 상태

**구현됨 (M2 마무리)** — 후보 소진 시 다음 query 좌표로 자동 재 lookup + 모든 query 소비 + 카메라 도달 시 도착 판정 동작. 중복 호출 가드·실패 retry·층 전환 분기 등 정책 미정.

## 목표

추적 영역 끝까지 사용자가 진행했을 때 (= 후보열 거의 비어감) 다음 영역의 keyframe pack 을 받아 추적을 잇는 메커니즘 + 모든 영역을 통과해 목적지 keyframe 까지 가까이 도달했을 때 도착 처리. Phase 4 의 매 tick 후속 분기 두 개를 책임진다.

---

## 흐름

```
[handleTrackingMatchResult]   (Phase 4 후속)
   │ (prefix drop · localizedPose · checkpointNode 갱신 완료)
   │
   ├─ if trackingKeyframeCandidates.count ≤ 1
   │      ▼
   │   [triggerNewLookup]
   │      │ consumedQueryPointIndex += 1
   │      │ nextQueryPoint =
   │      │     pathQueryPoints[consumedQueryPointIndex]   (있으면)
   │      │     else QueryPoint(floorLevel=localizedFloorLevel, x/y/z = goal)   (모든 query 소비 후 fallback)
   │      │
   │      ▼
   │   [NetworkBundleProvider(queries=[nextQueryPoint], radius=5m, max=5).fetch]
   │      │ POST /feature-points/lookup (단일 query)
   │      ▼
   │   [완료]
   │      success: localizationBundle 교체 + keyframeDescriptorCache 갱신 + setupTrackingCandidates(bundle)
   │      failure: print 만 — 기존 후보 유지
   │
   └─ if trackingKeyframeCandidates.count ≤ 1
        AND consumedQueryPointIndex ≥ max(pathQueryPoints.count - 1, 0)
        AND 카메라 ↔ checkpointNode XZ 거리 < trackingArrivalThresholdM (1.0m)
        AND !hasNotifiedArrival
           ▼
        [도착 처리]
           │ hasNotifiedArrival = true
           │ stopTracking()  ← trackingTimer invalidate
           │ delegate?.showArrivalNotification()
```

---

## 재 lookup (`triggerNewLookup`)

| 항목 | 동작 |
|------|------|
| 트리거 | `handleTrackingMatchResult` 의 prefix drop 직후, `candidates.count ≤ 1` |
| 다음 query 좌표 | `pathQueryPoints[consumedQueryPointIndex]` (Phase 3 가 보관한 pathfinding step 좌표 시퀀스) |
| pathQueryPoints 소진 시 | goal 좌표로 fallback (`floorLevel = localizedFloorLevel ?? 1`, `x/y/z = self.goal`) |
| lookup 파라미터 | `queries=[1점]`, `radiusM=5.0`, `maxKeyframesPerQuery=5` (Phase 3 와 동일) |
| 성공 | `localizationBundle` 통째로 교체 → `setupTrackingCandidates(bundle)` 재호출 → 후보열 재정렬 |
| 실패 | `print` 만. 기존 `trackingKeyframeCandidates` 유지 — 다음 tick 에서 다시 매칭 시도하면서 다시 ≤1 → 재호출 (사실상 무한 retry) |

⚠️ **매 tick 중복 호출 가드 없음** — `candidates.count ≤ 1` 인 동안 fetch 비동기 완료 전까지 매 tick `triggerNewLookup` 이 다시 트리거됨. 현재는 `networkBundleProvider` 가 매번 새 인스턴스로 덮여서 재시도 효과가 나지만, 진행 중 fetch 결과가 늦게 도착하면 후순위 fetch 의 결과로 덮일 수 있음 (race).

## 도착 판정

| 조건 | 의미 |
|------|------|
| `trackingKeyframeCandidates.count ≤ 1` | 추적 영역 거의 끝까지 통과 |
| `consumedQueryPointIndex ≥ max(pathQueryPoints.count - 1, 0)` | pathfinding 의 모든 step 좌표를 query 로 소비 완료 |
| 카메라 transform XZ ↔ `checkpointNode.position` XZ < `trackingArrivalThresholdM` (1.0 m) | 마지막 체크포인트 1m 이내 도달 |
| `!hasNotifiedArrival` | 1회 한정 (재진입 차단) |

만족 시:
- `hasNotifiedArrival = true`
- `stopTracking()` (`trackingTimer.invalidate`)
- `delegate?.showArrivalNotification()` → ViewController 가 도착 UI 띄움

⚠️ Y 축 거리 무시 — XZ 평면 거리만. 층이 다른 keyframe 이 마지막일 경우 잘못된 도착 판정 가능 (다층 경로 시 Phase 5+ 에서 정책 필요).

---

## 파라미터

| 이름 | 현재값 | 출처 |
|------|--------|------|
| 후보 소진 임계 | ≤ 1 | `handleTrackingMatchResult:1535,1540` |
| 도착 거리 임계 | 1.0 m (XZ) | `trackingArrivalThresholdM` |
| 재 lookup `radiusM` | 5.0 m | `triggerNewLookup:1681` |
| 재 lookup `maxKeyframesPerQuery` | 5 | `:1682` |
| 재 lookup `queries` 개수 | 1 (다음 query 좌표 또는 goal) | `:1680` |

---

## 현재 구현 (코드 위치)

| 함수 / 분기 | 파일:라인 | 책임 |
|-------------|----------|------|
| `triggerNewLookup` | `ARNavigationLogic.swift:1665` | 후보 소진 시 다음 좌표로 lookup → 후보 재정렬 |
| 도착 판정 분기 | `:1540` | 후보·query·거리 3조건 + `showArrivalNotification` |
| `pathQueryPoints` / `consumedQueryPointIndex` | `:189` / `:191` | Phase 3 적재 데이터 — 본 phase 의 진행도 인덱스 |
| `hasNotifiedArrival` | `:86` | 1회 도착 알림 가드 |
| `stopTracking` | `:1420` | trackingTimer 종료 |

---

## 미해결·향후 작업

- [ ] **재 lookup 중복 호출 가드** — 진행 중 fetch flag 도입 (`isReluekupInFlight`) 로 `candidates ≤ 1` 동안 매 tick 트리거 차단. 현재는 새 인스턴스로 덮여 race 가능.
- [ ] **재 lookup 실패 정책** — 현재 `print` 후 무한 retry. (a) N회 실패 시 V3 강제 재측위 트리거, (b) 사용자 수동 "다시 인식" 버튼 노출, (c) 임계 시간 후 fallback goal 좌표 lookup 등 정책 결정 필요.
- [ ] **도착 거리 Y 축 포함 여부** — 현재 XZ 평면. 다층 경로의 마지막 keyframe 이 다른 층일 때 오판 가능.
- [ ] **층 전환 분기 통합** — 기존 Phase 3 (계단·엘리베이터 인터렉션) 폐기 결정. 다층 경로 시 중간 층 전환 keyframe 도달 시점에 별도 인터렉션 (UX 정지 + 사용자 액션 + 새 층 재 lookup) 필요할 가능성. 본 phase 도착 처리와 동형 — 향후 통합 검토.
- [ ] **goal 좌표 fallback 무한 루프 위험** — `pathQueryPoints` 소진 후 goal 좌표로 매 tick 새 lookup 가능. 도착 판정 전까지 동일 좌표 반복 호출 방지 가드.
- [ ] **`pathQueryPoints` 가 빈 fallback (Phase 3 의 single-point fallback)** 흐름 시 — `consumedQueryPointIndex >= max(0-1, 0) = 0` 이라 처음부터 도착 조건에 진입 가능. 현재는 후보 소진까지 감으로 사실상 동작하지만 가드 명시 필요.
- [ ] **`showArrivalNotification` 후속 UX** — ViewController 위임. 완료 화면 디자인·수동 종료 흐름·재시작(loopForeverTrial) 흐름 미정.
- [ ] **재 lookup 시 query 좌표 dedup** — 다음 query 좌표가 직전 후보 영역과 큰 차이 없으면 응답 keyframe 도 거의 동일 — 진행 stuck. step 좌표 간 최소 거리 임계 검토.

---

## 의존성

- 선행: Phase 4 (`trackingKeyframeCandidates`, `localizedPose`, `checkpointNode` 매 tick 갱신).
- Phase 3 인계 사용: `pathQueryPoints`, `consumedQueryPointIndex`, `localizedFloorLevel`, `goal`, `buildingId`.
- 외부: `delegate.showArrivalNotification()` (ViewController), `NetworkManager.featurePointsLookup` (Phase 3 와 동일 엔드포인트).
