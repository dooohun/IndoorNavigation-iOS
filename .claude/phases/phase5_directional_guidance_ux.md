# Phase 5: 방향 안내 UX (Directional Guidance UX)

## 상태

**미구현**

## 목표

사용자가 AR 내비게이션 중 "어디로 향해야 하는지"를 시각적·언어적으로 즉시 이해할 수 있도록 2D HUD 안내를 강화한다. 자동차 내비게이션의 턴-바이-턴(Turn-by-Turn) UX를 차용해, AR 공간의 3D 시각화만으로 부족한 **방향 의사결정 순간**을 보조한다.

핵심 의도:
- 로컬라이즈 직후 사용자가 잘못된 방향을 보고 있을 때 즉시 회전을 유도한다.
- 다음 턴(좌/우/유턴)이 가까워지면 우상단 카드로 미리 알린다.
- 큰 회전(±60° 이상)은 전체 화면 오버레이로 강력하게 안내한다.

**레퍼런스 UX**: 카카오내비/티맵 우상단 턴 카드, Google Maps "U-turn" 풀스크린 알림.

---

## 기능 목록

### 5-1. 초기 방향 정렬 가이드 (Initial Heading Alignment)

**언제**: 로컬라이즈 성공 직후, 첫 waypoint를 향하는 방향과 카메라 헤딩이 ±30° 이상 어긋난 경우.

**무엇을**:
- [ ] 화면 전체를 덮는 반투명 오버레이 (검정 0.55 alpha)
- [ ] 중앙: 큰 회전 화살표 아이콘 (좌/우 결정은 yaw delta 부호 기준)
  - SF Symbol: `arrow.turn.up.left` / `arrow.turn.up.right` / `arrow.uturn.up`
  - 크기: 120pt, 색상: 흰색
- [ ] 아이콘 아래 안내 문구
  - 예: "오른쪽으로 90° 회전하세요"
  - "회전 후 정면을 바라보면 안내가 시작됩니다"
- [ ] 사용자가 회전하여 헤딩 차이가 ±15° 이하로 들어오면 오버레이를 0.3초 fade-out 후 dismiss
- [ ] 오버레이가 떠 있는 동안에도 ARSession은 계속 동작 (헤딩만 모니터링)

**판정 기준**:
- `yawDelta = angle(cameraForward, vectorToFirstWaypoint)` (XZ 평면 투영)
- `|yawDelta| > 30°` → 표시
- `|yawDelta| ≤ 15°` → 해제 (히스테리시스)

**텍스트 결정 로직**:
| yawDelta 범위 | 문구 | 아이콘 |
|----------|------|--------|
| 30° ~ 60° | "오른쪽으로 살짝 돌아보세요" | `arrow.turn.up.right` |
| 60° ~ 120° | "오른쪽으로 90° 회전하세요" | `arrow.turn.up.right` |
| 120° ~ 180° | "뒤를 돌아보세요" | `arrow.uturn.up` |
| -30° ~ -60° | "왼쪽으로 살짝 돌아보세요" | `arrow.turn.up.left` |
| -60° ~ -120° | "왼쪽으로 90° 회전하세요" | `arrow.turn.up.left` |
| -120° ~ -180° | "뒤를 돌아보세요" | `arrow.uturn.up` |

---

### 5-2. 턴 카드 (Turn-by-Turn Card, 우상단)

**언제**: 다음 waypoint가 "방향 전환 지점"이고, 현재 위치로부터 **15m 이내**일 때.

**방향 전환 지점 정의**: 인접한 두 세그먼트(waypoint i-1 → i, i → i+1) 사이 각도 변화가 ±25° 이상인 지점.
- 서버 `PathStep.instruction` 필드에 의존하지 않고 `PathStep.position` 좌표만으로 클라이언트가 자체 산출한다.
- 경로 수신 직후 한 번 전체를 스캔해 `[turnIndex: angleDelta]` 룩업 테이블을 만들어 두면 매 프레임 재계산 불필요.

**사전 경로 단순화 (RDP, ε=0.7m)**:
- 서버 경로는 0.25m 격자로 양자화되어 같은 직선 위 중간점·0.125m 미세 단차가 다수 포함된다.
  이를 그대로 두면 인접 세그먼트 각도 계산 시 노이즈가 코너로 오인된다 (실측 25점 → 의미 있는 코너 약 8개).
- ε=0.7m로 상향하면 0.5m 미만의 짧은 단차도 흡수.
- `ARNavigationLogic.drawPathNodes`에서 Catmull-Rom spline 보간 직전에 XZ 2D RDP 알고리즘을 임계값 ε = 0.7m로 적용한다. 단순화 결과를 spline 입력으로 사용하므로 시각 경로(리본·쉐브론)·GuidanceDirector turn 판정 모두 동일 점열 기반.
- **시각 경로(리본·쉐브론)도 단순화된 점 기준으로 그려짐** — `ARNavigationLogic.drawPathNodes`에서 spline 입력 단계에 RDP 적용. GuidanceDirector는 단순화된 결과를 받아 turn 빌드만 수행.
- ε는 `ARNavigationLogic.pathSimplificationEpsilonM` 상수로 노출 (디바이스 튜닝 가능).

**무엇을**:
- [ ] 화면 우상단 모서리에서 16pt 안쪽으로 띄운 카드 (safeArea 기준)
- [ ] 카드 크기: 폭 160pt, 높이 80pt, 둥근 모서리 12pt
- [ ] 배경: 흰색 0.95 alpha, 그림자 (offset 0,2 / radius 6 / opacity 0.15)
- [ ] 좌측: 회전 화살표 아이콘 (40pt, 검정)
  - 좌회전 / 우회전 / 유턴
- [ ] 우측 상단: 거리 큰 폰트 (22pt bold)
  - 예: "8 m"
- [ ] 우측 하단: 액션 텍스트 (13pt regular)
  - 예: "후 좌회전", "후 우회전", "후 유턴"
- [ ] **거리 업데이트**: 매 ARFrame마다 카메라 → 턴 지점 거리 재계산해 카드 텍스트 갱신
- [ ] **등장**: 우측에서 슬라이드 인 (0.25초, ease-out)
- [ ] **퇴장**: 사용자가 턴 지점을 0.8m 이내로 통과하면 슬라이드 아웃 (0.2초)

**다중 턴 처리**: 한 번에 한 카드만 표시. 현재 턴이 사라진 후 다음 턴이 15m 이내라면 즉시 새 카드 표시.

---

### 5-3. 풀스크린 회전 안내 (Major Reorientation Overlay)

**언제**: 내비게이션 진행 중 사용자 헤딩이 다음 waypoint 방향과 ±60° 이상 어긋난 채 **2초 이상 지속**된 경우. (5-1과 달리, 로컬라이즈 직후가 아니라 경로 이탈/방향 상실 상황을 잡는다.)

**무엇을**:
- [ ] 5-1과 동일한 풀스크린 오버레이 패턴 재사용
- [ ] 단, 헤더 문구를 강화: "방향이 잘못되었습니다"
- [ ] 본문: "시계방향 90°로 회전하여 정면을 바라봐 주세요" (회전 방향·각도 동적 산출)
- [ ] 아이콘: 5-1과 동일 매핑 (좌/우/유턴)
- [ ] 하단에 작은 보조 텍스트: "AR 안내가 다시 시작됩니다"
- [ ] 헤딩 차이 ±20° 이하로 들어오면 dismiss

**중요**: 5-1과 5-3은 동일한 `HeadingAlignmentOverlayView` 컴포넌트를 재사용한다. 문구·트리거 조건만 다르게 설정.

---

## 데이터 소스 (추가 API 불필요)

본 Phase는 **추가 서버 API 없이 클라이언트 로직만으로** 구현한다. 사용하는 입력은 기존 응답값과 ARKit 프레임뿐이다.

| 필요 데이터 | 출처 | 비고 |
|-------------|------|------|
| 카메라 위치 | `ARFrame.camera.transform.columns.3` (xyz) | 0.1초 타이머에서 이미 접근 중 (`ARNavigationLogic.swift:605-617`) |
| 카메라 헤딩(forward) | `ARFrame.camera.transform.columns.2` (-z 정면) 1줄 추가 | XZ 평면 투영 후 정규화 |
| 다음 waypoint 위치 | `PathStep.position(x,y,z)` → `CoordinateTransformer`로 ARKit world 변환 | 변환은 이미 yaw 포함 완전 적용 |
| 현재 진행 인덱스 | 기존 `currentTargetWaypointIndex` | 그대로 사용 |
| 턴 지점 판정 | RDP(ε=0.7m) 단순화 후 인접 두 세그먼트 벡터 각도 차 | `PathStep.instruction` 미사용. 단순화는 시각 경로·turn 판정 공통 적용 (drawPathNodes 단계) |

따라서 서버 스펙 변경·추가 호출 없이 5-1·5-2·5-3 모두 구현 가능하다.

---

## UI 컴포넌트 설계

### `HeadingAlignmentOverlayView` (5-1, 5-3 공통)

```
UIView (full-screen, backgroundColor: black 0.55 alpha)
├── UIImageView (회전 아이콘, 120pt, tintColor: white)
├── UILabel (메인 문구, 24pt bold, white, center)
└── UILabel (보조 문구, 15pt regular, white 0.8 alpha, center)
```

API:
```swift
func show(direction: TurnDirection, angleDeg: Double, mode: AlignmentMode)
func dismiss(animated: Bool)

enum TurnDirection { case left, right, uTurn }
enum AlignmentMode { case initial, reorient }   // 문구 차이용
```

### `TurnCardView` (5-2)

```
UIView (160×80, white 0.95, cornerRadius 12, shadow)
├── UIImageView (40pt, leading 12pt, vertical center)
└── UIStackView (vertical, trailing 12pt)
    ├── UILabel ("8 m", 22pt bold)
    └── UILabel ("후 좌회전", 13pt regular)
```

API:
```swift
func update(direction: TurnDirection, distanceMeters: Double)
func showSlideIn()
func hideSlideOut()
```

---

## 로직 통합 지점

`ARNavigationLogic` (또는 신규 `GuidanceDirector`)에서 매 ARFrame마다 다음을 계산:

1. **카메라 헤딩 벡터**: `simd_make_float3(-cameraTransform.columns.2.x, 0, -cameraTransform.columns.2.z)` 정규화
2. **다음 waypoint 방향 벡터**: `(nextWaypointWorldPos - cameraWorldPos)` 의 XZ 평면 투영 정규화
3. **yawDelta**: `atan2(cross.y, dot)` (radian) → degree 변환, 좌(-) / 우(+)
4. **다음 턴 지점 탐색**: `activeSteps`를 순회하며 인접 세그먼트 각도 차 ≥25° 인 첫 지점 → 거리 계산
5. **상태 머신**:
   - `initialAlignment` (로컬라이즈 직후 1회) → `navigating` (정상 진행) ↔ `majorReorient` (방향 상실)
   - `navigating` 상태에서만 `TurnCardView` 트리거 평가

**Delegate 콜백 (예시)**:
```swift
protocol GuidanceDirectorDelegate: AnyObject {
    func guidance(_ director: GuidanceDirector, showInitialAlignment direction: TurnDirection, angle: Double)
    func guidance(_ director: GuidanceDirector, showReorient direction: TurnDirection, angle: Double)
    func guidanceDismissAlignmentOverlay()
    func guidance(_ director: GuidanceDirector, showTurnCard direction: TurnDirection, distance: Double)
    func guidance(_ director: GuidanceDirector, updateTurnCardDistance distance: Double)
    func guidanceHideTurnCard()
}
```

---

## 완료 기준 (Definition of Done)

1. 로컬라이즈 성공 직후 카메라 헤딩이 첫 waypoint와 30° 이상 어긋나면 풀스크린 오버레이가 떠서 회전을 유도한다.
2. 사용자가 회전하여 헤딩 차이가 15° 이하로 들어오면 오버레이가 자동으로 사라지고 AR 안내가 시작된다.
3. 진행 중 다음 턴 지점(각도 변화 ≥25°)이 15m 이내가 되면 우상단에 턴 카드가 슬라이드 인 되고, 거리가 실시간으로 갱신된다.
4. 사용자가 턴 지점을 통과(0.8m 이내) 하면 카드가 슬라이드 아웃 되고, 다음 턴이 있으면 새 카드가 표시된다.
5. 진행 중 사용자가 60° 이상 어긋난 채 2초 이상 머무르면 풀스크린 재정렬 오버레이가 표시되고, 20° 이내로 정렬되면 사라진다.
6. 모든 안내 표시는 AR 렌더링과 충돌하지 않으며, ARSession은 중단되지 않는다.

---

## 의존성

- **Phase 2**: 로컬라이즈 결과 pose, `activeSteps` 윈도우, 카메라 위치/자세 접근 필요. `ARNavigationLogic` 의 ARFrame 콜백에 hook 추가.
- **Phase 3**: 층 전환 인터렉션이 표시되는 동안에는 본 Phase의 오버레이/카드를 일시 숨김 처리 (우선순위 충돌 방지).
- **Phase 4**: 도착 카드 표시 시점에 본 Phase의 모든 안내 UI를 제거.

---

## 관련 파일 (예상)

- 신규: `IndoorNavigation-iOS/Guidance/GuidanceDirector.swift` — 방향 판정·상태 머신
- 신규: `IndoorNavigation-iOS/Guidance/HeadingAlignmentOverlayView.swift`
- 신규: `IndoorNavigation-iOS/Guidance/TurnCardView.swift`
- 수정: `IndoorNavigation-iOS/ARNavigationViewController.swift` — 오버레이/카드 호스팅 + delegate 구현
- 수정: `IndoorNavigation-iOS/ARNavigationLogic.swift` — `GuidanceDirector` 인스턴스 보유, ARFrame 시 헤딩 계산 위임

---

## 미해결 이슈 / 결정 필요

- [ ] 턴 지점 각도 임계값(25°)·풀스크린 트리거(60°·2초)·히스테리시스(15°/20°) 수치를 실제 단말 테스트로 튜닝 필요
- [ ] "거리" 표시 단위: 10m 미만은 m 단위 정수, 10m 이상은 5m 단위 반올림(예: 12 → 10, 13 → 15) 적용 여부
- [ ] 계단/엘리베이터 진입 직전 턴이 겹치는 경우, Phase 3 인터렉션과 카드 우선순위 (현재는 Phase 3 우선 가정)
- [ ] RDP ε(`ARNavigationLogic.pathSimplificationEpsilonM = 0.7m`) 튜닝 — 너무 크면 실제 코너 누락(특히 90° 미만 완만한 회전), 너무 작으면 0.25m 격자 노이즈가 chevron 오배치를 유발. 단말 실측으로 0.5~1.0m 범위 검증 권장.
