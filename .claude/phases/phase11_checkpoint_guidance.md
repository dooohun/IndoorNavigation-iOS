# Phase 11: 체크포인트 엔진 + 안내 통합 + 복구

## 상태

**미구현** — [Phase 6 개요](phase6_superpoint_overview.md) 참조.

## 목표

경로 폴리라인을 사용자 인지 단위(체크포인트)로 분해하고, Phase 10 의 pose 결과를 `GuidanceDirector` (Phase 5) 입력으로 연결한다. 길 잃음 복구 전이도 본 Phase 에서 책임진다.

마일스톤: M5 (체크포인트 + UX wiring), M6 (복구 + Phase 3·4 통합 + 측위 코드 폐기).

---

## 기능 목록

### 11-1. 체크포인트 종류

| 종류 | 트리거 |
|------|--------|
| `turnLeft` | RDP(ε=0.7m) 단순화 후 인접 두 세그먼트 yaw delta ≤ -25° |
| `turnRight` | yaw delta ≥ +25° |
| `uTurn` | \|yaw delta\| ≥ 150° |
| `straightProgress` | 직진 구간이 D_straight (8m) 이상 이어질 때, D_straight 마다 1개 |
| `floorTransition` | `floorLevel` 변화 지점 (Phase 3 인터렉션 트리거) |
| `arrival` | 경로 마지막 노드 (Phase 4 도착 UX 트리거) |

#### `straightProgress` 의 존재 이유

- ARKit world pose 적분 + SuperPoint 보정이 잘 들어맞아도, 직진 구간이 길면 사용자가 "지금 잘 가는 게 맞나?" 라는 인지적 공백을 경험.
- D_straight 마다 작은 직진 확인 표시 (HUD 하단 "약 N m 더 직진") 또는 무음 바닥 띠 강조.
- 8m 초기값 근거: ARKit 직선 거리 오차(약 1~2%)가 사람이 무시할 수 있는 ±0.2m 이내에 머무르는 경험적 임계.

### 11-2. CheckpointEngine

```swift
struct Checkpoint {
    let id: UUID
    let kind: CheckpointKind
    let worldPosition: SIMD3<Float>
    let yawDeltaDeg: Double?
    let segmentIndex: Int
}

enum CheckpointKind {
    case turnLeft, turnRight, uTurn
    case straightProgress
    case floorTransition(direction: FloorChange)
    case arrival
}

protocol CheckpointEngineProtocol {
    func ingest(routeCoordinates: [SIMD3<Float>], floorTransitions: [FloorTransition])
    func update(currentPose: PoseEstimate) -> [CheckpointEvent]
}

enum CheckpointEvent {
    case approached(Checkpoint, distanceM: Double)
    case passed(Checkpoint)
    case missed(Checkpoint)   // 통과 없이 다음 체크포인트로 점프
}
```

### 11-3. 사전 분해

- [ ] 경로 수신 직후 RDP(ε=`path.rdpEpsilonM`=0.7m, Phase 5와 공유) 단순화.
- [ ] 인접 두 세그먼트의 yaw delta 계산 → 임계 분류 → `turn*` 체크포인트.
- [ ] 인접 turn 사이 거리가 D_straight(8m) 초과 시 중간에 `straightProgress` 균등 분포 삽입.
- [ ] `floorLevel` 변경 지점 → `floorTransition` 삽입.
- [ ] 마지막 노드 → `arrival` 삽입.

### 11-4. 진행 추적 + GuidanceDirector wiring

- [ ] PoseTracker 가 갱신한 world pose 기준으로 다음 체크포인트까지 거리·진행도 계산.
- [ ] 사용자가 체크포인트로부터 `checkpoint.passRadiusM`(0.8m) 이내로 들어오면 통과 → 다음으로 전진.
- [ ] 통과 시점에 `GuidanceDirector` (Phase 5) 에 이벤트 전달:
  - `turn*` → 턴 카드 / 풀스크린 회전 안내
  - `straightProgress` → 가벼운 진행 피드백 (HUD)
  - `floorTransition` → Phase 3 인터렉션
  - `arrival` → Phase 4 도착 UX

### 11-5. 길 잃음 복구

조건:
- Phase 10 PoseTracker 신뢰도 NG 5초 (Phase 8 트리거)
- 다음 체크포인트 방향 ↔ 사용자 헤딩 ±90° 5초 지속

동작:
- [ ] Phase 8 재로컬라이즈 흐름 위임.
- [ ] 복구 성공 후 가장 가까운 체크포인트부터 안내 재개 (이미 통과 처리된 체크포인트는 skip).

### 11-6. NavigationCoordinator 통합 + 측위 코드 폐기 (M6)

- [ ] 상태 머신([Phase 6 개요](phase6_superpoint_overview.md) 참조) 의 `tracking ↔ relocalizing ↔ floorTransitionInteraction ↔ arrived` 전이 구현.
- [ ] 기존 `ARNavigationLogic` 의 단발 로컬라이즈 + ARKit pose 적분 측위 로직 제거.
- [ ] 시각 경로 렌더링(리본·쉐브론) 은 SceneKit 헬퍼로 추출 보존, 입력만 신규 pose 시스템에서 받게 정리.

---

## 파라미터

| 이름 | 초기값 | 의미 |
|------|--------|------|
| `checkpoint.turnAngleDeg` | 25 | 턴 체크포인트 각도 임계 |
| `checkpoint.uTurnAngleDeg` | 150 | 유턴 각도 임계 |
| `checkpoint.straightStrideM` | 8 | 직진 체크포인트 간격 |
| `checkpoint.passRadiusM` | 0.8 | 체크포인트 통과 판정 거리 |
| `path.rdpEpsilonM` | 0.7 | 경로 단순화 임계 (Phase 5와 공유) |

---

## 완료 기준 (Definition of Done)

### M5
1. 경로 수신 직후 RDP + 각도 분석으로 체크포인트 배열이 산출되고, 직진 구간은 8m 간격으로 잘게 쪼개진다.
2. 체크포인트 통과 시점에 `GuidanceDirector` 가 Phase 5 UX (턴 카드 / 풀스크린 회전 안내) 를 적시에 표시한다.
3. 시각 경로 렌더링 입력이 PoseTracker 결과로 교체되었다.

### M6
4. PoseTracker NG 5초 또는 헤딩 이탈 90°·5초 → 자동 재로컬라이즈 → 가장 가까운 체크포인트부터 안내 재개.
5. 층 전환 도달 시 Phase 3 인터렉션, 도착 시 Phase 4 UX 정상 동작.
6. 기존 `ARNavigationLogic` 측위 로직 제거 완료. 빌드·런타임 회귀 없음.

---

## 의존성

- 선행: Phase 10 (PoseEstimate), Phase 5 (UX 컴포넌트)
- 통합: Phase 3 (층 전환), Phase 4 (도착)
- 트리거: Phase 8 (재로컬라이즈)

---

## 미해결 이슈

- [ ] **체크포인트 임계 튜닝**: turnAngleDeg(25°) / uTurnAngleDeg(150°) / passRadiusM(0.8m) / straightStrideM(8m) 단말 실측 검증 필요.
- [ ] **계단/엘리베이터 직전 턴 겹침**: Phase 3 인터렉션과 턴 카드 우선순위 (현재는 Phase 3 우선 가정).
- [ ] **`missed` 이벤트 처리 UX**: 체크포인트를 통과하지 못하고 지나친 경우의 안내 (현재 플로우는 가장 가까운 다음 체크포인트로 점프).
- [ ] **`straightProgress` UX 강도**: 단순 HUD 텍스트 vs 음성 안내 vs 무시 — 사용성 테스트 필요.
