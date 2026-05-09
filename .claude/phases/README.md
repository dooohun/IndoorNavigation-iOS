# 서비스 전체 Phase 구성

## 서비스 흐름 요약

```
네이버 지도 (건물 마커 + 검색)
    → 건물 클릭 → POI(목적지) 선택
        → AR 실내 내비게이션 시작
            → 카메라 스캔 → V3 측위 → pathfinding → multi-query lookup
            → keyframe pack 메모리 적재
            → tick 마다 LightGlue 매칭 + prefix drop
            → 후보열 끝 keyframe 위치에 체크포인트 표시
            → 후보 소진 → 다음 query 좌표로 재 lookup → 후보 갱신
            → 모든 query 소비 + 카메라 도달 → 도착 처리
```

## Phase 목록

| Phase | 제목 | 상태 | 핵심 목표 |
|-------|------|------|----------|
| [Phase 1](phase1_map_building_markers.md) | 네이버 지도 - 건물 마커 & 탐색 | 구현됨 (개선 여지) | 지도 마커, 검색, InfoCard |
| [Phase 2](phase2_extractor_infra.md) | 온디바이스 SuperPoint + LightGlue 추출 인프라 | 구현됨 (M1) | Core ML 추론 레이어 — 모든 후속 phase 의 입력원 |
| [Phase 3](phase3_initial_localize_route.md) | 초기 측위 + 경로 데이터 확보 | 부분 구현 (M2 진행 중) | V3 localize → pathfinding → multi-query lookup → keyframe pack 적재 |
| [Phase 4](phase4_keyframe_tracking.md) | keyframe 추적 + 체크포인트 표시 | 구현됨 (M2 핵심부) | tick 마다 LightGlue 매칭 + prefix drop + checkpointNode UI |
| [Phase 5](phase5_relocalize_arrival.md) | 재 lookup + 도착 처리 | 구현됨 (M2 마무리) | 후보 소진 시 재 lookup + 모든 query 소비 + 카메라 도달 시 도착 |

## 측위 정책

**측위 호출은 항상 V3** — `POST /api/slam/v3/localize`. legacy `/api/slam/localize`, `/api/slam/v2/localize`, `/api/v1/buildings/{id}/localize` 사용 X.

## 기술 스택

- **지도**: NMapsMap (Naver Map SDK)
- **AR**: ARKit + SceneKit
- **측위**: 서버 V3 localize (multipart) + 온디바이스 SuperPoint + Core ML LightGlue 매칭
- **네트워크**: URLSession, Completion handler, `Result<T, Error>`
- **API Base**: `http://218.150.183.198:8080/api/v1` (+ `/api/slam/v3` for localize)

## 주요 파일 → Phase 매핑

| 파일 | 관련 Phase |
|------|-----------|
| `MapViewController.swift`, `POISelectionViewController.swift` | Phase 1 |
| `Tracking/SuperPointExtractor.swift`, `Tracking/Matching/LightGlueMatcherEngine.swift` | Phase 2 |
| `NetworkManager.swift`, `Network/SuperPointDTO.swift`, `Tracking/NetworkBundleProvider.swift` | Phase 3 |
| `ARNavigationLogic.swift` (`runTrackingTick` / `handleTrackingMatchResult` / `setupTrackingCandidates` / `updateCheckpointNode`) | Phase 4 |
| `ARNavigationLogic.swift` (`triggerNewLookup` / 도착 판정 분기) | Phase 5 |
| `ARNavigationViewController.swift` | Phase 1, 3, 4, 5 (UI 호스팅) |
| `CoordinateTransformer.swift` | Phase 4 (server↔AR 좌표 변환) |
