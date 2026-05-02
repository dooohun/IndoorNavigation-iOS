# IndoorNavigation-iOS

iOS ARKit 기반 실내 내비게이션 앱.

## 하네스: iOS 개발

**목표:** ios-planner → ios-implementer → ios-reviewer 파이프라인으로 기능 개발과 버그 수정을 안전하게 처리한다.

**트리거:** iOS 코드 변경(기능 추가, 버그 수정, UI 수정, AR 개선, API 연동 등) 요청 시 `ios-dev` 스킬을 사용하라. 단순 코드 설명이나 질문은 직접 응답 가능.

## 서비스 Phase 구성

구현 목표는 `.claude/phases/`에 Phase별로 문서화되어 있다. 기능 개발 요청 시 해당 Phase 문서를 참조한다.

| Phase | 파일 | 상태 |
|-------|------|------|
| Phase 1 | `phases/phase1_map_building_markers.md` | 구현됨 (개선 여지) |
| Phase 2 | `phases/phase2_ar_navigation_core.md` | 부분 구현 |
| Phase 3 | `phases/phase3_floor_transition.md` | 미구현 |
| Phase 4 | `phases/phase4_arrival_ux.md` | 미구현 |

Phase 문서의 `## 상태` 필드는 구현 완료 시 업데이트한다.

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-04-20 | 초기 구성 | 전체 | - |
| 2026-04-29 | 에이전트·스킬 파일 생성 | agents/, skills/ | 신규 구축 (파일 없던 상태) |
| 2026-05-02 | Phase 문서 추가 | .claude/phases/ | 서비스 전체 흐름 목표 정의 |
