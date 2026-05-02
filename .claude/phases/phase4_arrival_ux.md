# Phase 4: 도착 UX

## 상태

**미구현**

## 목표

사용자가 목적지에 도착했을 때 적절한 완료 화면을 표시하고 내비게이션을 종료한다.

## 기능 목록

### 4-1. 도착 감지

- [ ] 마지막 `PathStep` waypoint 도달 (거리 임계값 통과) 시 도착 판정
  - 임계값: 1.0m (최종 목적지는 스탑 포인트이므로 일반 waypoint보다 넓게)
- [ ] 또는 `PathStep.instruction == "ARRIVED"` 등 서버 스펙 확인 후 적용

**구현 위치**: `ARNavigationLogic` — 마지막 step 도달 판정 → delegate로 `ARNavigationViewController`에 알림

---

### 4-2. 도착 완료 UI

- [ ] AR 화면 위에 전체화면 오버레이 카드 표시
  - **아이콘**: 체크마크 (SF Symbol: `checkmark.circle.fill`, 초록)
  - **제목**: "도착했습니다!"
  - **본문**: 목적지 이름 (예: "304호에 도착했습니다")
  - **버튼**: "확인" → 지도 화면(MapViewController)으로 pop
- [ ] 도착 시 모든 AR 경로 노드 제거
- [ ] ARKit 세션 종료

---

### 4-3. 부가 UX (선택)

- [ ] 도착 시 간단한 햅틱 피드백 (`UINotificationFeedbackGenerator.success`)
- [ ] 도착 카드가 나타날 때 스케일 애니메이션 (0.8 → 1.0, spring)

---

## 완료 기준 (Definition of Done)

1. 마지막 waypoint에 충분히 가까워지면 "도착했습니다!" 카드가 표시된다.
2. 목적지 이름이 카드에 표시된다.
3. "확인" 탭 → 지도 화면으로 돌아간다.
4. AR 세션이 정상 종료된다.

## 의존성

- Phase 2: 마지막 waypoint 도달 판정 로직
- Phase 3: 다층 경로의 경우 최종 층의 마지막 step이 도착 waypoint

## 관련 파일

- `IndoorNavigation-iOS/ARNavigationViewController.swift` — 도착 오버레이 표시, ARKit 세션 종료
- `IndoorNavigation-iOS/ARNavigationLogic.swift` — 마지막 step 도달 감지 + delegate 호출
