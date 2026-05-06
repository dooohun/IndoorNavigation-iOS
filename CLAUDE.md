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
| Phase 3 | `phases/phase3_floor_transition.md` | 구현됨 |
| Phase 4 | `phases/phase4_arrival_ux.md` | 미구현 |
| Phase 5 | `phases/phase5_directional_guidance_ux.md` | 미구현 |
| Phase 6 | `phases/phase6_superpoint_overview.md` | 미구현 (신규 아키텍처 — 개요) |
| Phase 7 | `phases/phase7_superpoint_extractor.md` | 미구현 (M1) |
| Phase 8 | `phases/phase8_superpoint_localize.md` | 미구현 (M2) |
| Phase 9 | `phases/phase9_feature_chunk_store.md` | 미구현 (M3) |
| Phase 10 | `phases/phase10_pose_tracker.md` | 미구현 (M4) |
| Phase 11 | `phases/phase11_checkpoint_guidance.md` | 미구현 (M5/M6) |

Phase 문서의 `## 상태` 필드는 구현 완료 시 업데이트한다.

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-04-20 | 초기 구성 | 전체 | - |
| 2026-04-29 | 에이전트·스킬 파일 생성 | agents/, skills/ | 신규 구축 (파일 없던 상태) |
| 2026-05-02 | Phase 문서 추가 | .claude/phases/ | 서비스 전체 흐름 목표 정의 |
| 2026-05-06 | Phase 3 상태 갱신 | CLAUDE.md, phases/README.md | 층 전환 인터렉션 구현 완료 반영 |
| 2026-05-06 | `_workspace/` 제거, 스킬·에이전트 동기화 | agents/, skills/ | 코드 진화(SLAM 로컬라이즈, 좌표 기반 경로, ribbon+쉐브론, 층 전환)에 맞춰 문서 갱신 / 파이프라인 데이터 전달을 메시지 본문 기반으로 단순화 |
| 2026-05-06 | Phase 5 신규 추가 | .claude/phases/ | 사용자 친화 방향 안내 UX(턴 카드, 풀스크린 회전 안내) 기획 |
| 2026-05-06 | Phase 6 신규 추가 | .claude/phases/ | 측위 엔진 전면 재설계 — 클라이언트·서버 SuperPoint + 온보드 PnP 추적 + 청크 프리페치 + 체크포인트 안내 |
| 2026-05-06 | Phase 6 단일 문서를 6(overview) + 7~11(모듈별) 로 분리 | .claude/phases/ | 단일 문서 비대화 → 토큰 효율 + ios-planner 가 모듈별로 로드 가능하도록 |
