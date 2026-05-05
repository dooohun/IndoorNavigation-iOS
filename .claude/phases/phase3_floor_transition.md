# Phase 3: 층 이동 인터렉션

## 상태

**구현됨** (2026-05-05)

## 목표

경로 중 계단이나 엘리베이터에 도착했을 때 AR 내비게이션을 일시 중단하고, 사용자가 층을 이동한 뒤 원하는 층에서 다시 스캔할 수 있도록 안내한다.

## 기능 목록

### 3-1. 계단/엘리베이터 도착 감지

- [ ] `PathStep.instruction` 값으로 층 이동 시점 판별
  - 예: `"TAKE_STAIRS"`, `"TAKE_ELEVATOR"`, `"FLOOR_CHANGE"` 등 서버 스펙 확인 필요
  - 또는 `PathStep.floorLevel`이 현재 층과 달라지는 시점
- [ ] 해당 waypoint 도달 (거리 임계값 통과) 시 층 이동 모드 진입

**구현 위치**: `ARNavigationLogic` — waypoint 도달 판정 로직에서 `floorLevel` 변화 감지

---

### 3-2. 층 이동 안내 UI

- [ ] AR 화면 위에 모달/오버레이 형태로 전체화면 안내 카드 표시
  - **제목**: "계단을 이용해주세요" 또는 "엘리베이터를 이용해주세요" (instruction 기반)
  - **본문**: "원하는 층에 도착하면 다시 스캔해야 합니다."
  - **목표 층 표시**: "목표: N층으로 이동" (다음 PathStep의 floorLevel)
  - **버튼**: "도착했습니다 — 다시 스캔하기"
- [ ] 이 화면에서는 AR 렌더링 일시 중단 (셰브론, 경로선 숨김)
- [ ] ARKit 세션은 유지 (일시정지 없이, 단순히 노드만 숨김)

---

### 3-3. 재스캔 플로우

- [ ] "도착했습니다 — 다시 스캔하기" 버튼 탭 → Phase 2-1 스캔 안내 UI로 복귀
- [ ] 새 스캔 성공 후 localize → 현재 층 업데이트
- [ ] 잔여 경로(현재 층 이후 steps)로 새로운 경로 렌더링
- [ ] 기존 AR 노드(이전 경로)는 제거하고 새 경로 노드 추가

**구현 위치**: `ARNavigationViewController` — 층 이동 완료 후 `ARNavigationLogic.restartLocalization()`

---

## 완료 기준 (Definition of Done)

1. 경로 중 계단/엘리베이터 waypoint에 도달하면 층 이동 안내 카드가 표시된다.
2. 안내 카드에 "원하는 층에 도착하면 다시 스캔해야 합니다" 문구가 표시된다.
3. "다시 스캔하기" 탭 → 스캔 화면으로 돌아가 재로컬라이즈가 진행된다.
4. 재로컬라이즈 성공 후 잔여 경로가 AR에 다시 렌더링된다.

## 의존성

- Phase 2: waypoint 도달 판정, 경로 노드 관리 로직
- 서버: `PathStep.instruction` 또는 `floorLevel` 변화로 층 이동 시점 확인 가능해야 함

## 관련 파일

- `IndoorNavigation-iOS/ARNavigationViewController.swift` — 층 이동 모달 표시, 재스캔 트리거
- `IndoorNavigation-iOS/ARNavigationLogic.swift` — waypoint 도달 + floorLevel 변화 감지
