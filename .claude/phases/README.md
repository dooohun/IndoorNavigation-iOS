# 서비스 전체 Phase 구성

## 서비스 흐름 요약

```
네이버 지도 (건물 마커 + 검색)
    → 건물 클릭 → POI(목적지) 선택
        → AR 실내 내비게이션 시작
            → 주변 스캔 → 로컬라이즈
            → 경로 렌더링 (거리 + 화살표)
            → 계단/엘리베이터 도착 → 인터렉션 위임
            → 층 이동 후 재스캔
            → 목적지 도착 → 완료 UI
```

## Phase 목록

| Phase | 제목 | 상태 | 핵심 목표 |
|-------|------|------|----------|
| [Phase 1](phase1_map_building_markers.md) | 네이버 지도 - 건물 마커 & 탐색 | 구현됨 (개선 여지 있음) | 지도에 건물 마커 표시, 검색, InfoCard |
| [Phase 2](phase2_ar_navigation_core.md) | AR 실내 내비게이션 - 핵심 플로우 | 부분 구현 | 스캔 → 로컬라이즈 → 경로 렌더링 |
| [Phase 3](phase3_floor_transition.md) | 층 이동 인터렉션 | 구현됨 | 계단/엘리베이터 도착 감지 + 재스캔 |
| [Phase 4](phase4_arrival_ux.md) | 도착 UX | 미구현 | 목적지 도착 감지 + 완료 화면 |
| [Phase 5](phase5_directional_guidance_ux.md) | 방향 안내 UX (턴 카드 + 풀스크린 회전 안내) | 미구현 | 로컬라이즈 직후 헤딩 정렬, 턴-바이-턴 카드, 재정렬 오버레이 |
| [Phase 6](phase6_superpoint_overview.md) | SuperPoint 온보드 내비게이션 — 개요 (전면 재설계) | 미구현 (신규 아키텍처) | 동기·아키텍처·롤아웃. 모듈별 상세는 Phase 7~11 |
| [Phase 7](phase7_superpoint_extractor.md) | SuperPoint 추출 인프라 (Core ML) | 미구현 | 온디바이스 SuperPoint 추론, 추론 빈도 적응 |
| [Phase 8](phase8_superpoint_localize.md) | 서버 SuperPoint 로컬라이즈 | 미구현 | 신규 `localize-sp` 엔드포인트, 초기 스캔, 재로컬라이즈 |
| [Phase 9](phase9_feature_chunk_store.md) | 특징점 청크 저장소 + 프리페치 | 미구현 | `feature-chunks`, hot/cold 윈도우, LRU, 디스크 캐시 |
| [Phase 10](phase10_pose_tracker.md) | 온보드 Pose 추적 (PnP 6DoF) | 미구현 | PnP 매칭·신뢰도, ARKit drift 보정 |
| [Phase 11](phase11_checkpoint_guidance.md) | 체크포인트 엔진 + 안내 통합 + 복구 | 미구현 | 체크포인트 분해, GuidanceDirector wiring, 길 잃음 복구 |

## 기술 스택

- **지도**: NMapsMap (Naver Map SDK)
- **AR**: ARKit + SceneKit
- **측위**: Visual Positioning System (VPS) — 서버 localize API
- **네트워크**: URLSession, Completion handler, `Result<T, Error>`
- **API Base**: `http://218.150.183.198:8080/api/v1`

## 주요 파일 → Phase 매핑

| 파일 | 관련 Phase |
|------|-----------|
| `MapViewController.swift` | Phase 1 |
| `POISelectionViewController.swift` | Phase 1 |
| `NetworkManager.swift` | 공통 |
| `ARNavigationViewController.swift` | Phase 2, 3, 4 |
| `ARNavigationLogic.swift` | Phase 2, 3, 4 |
| `CoordinateTransformer.swift` | Phase 2 |
