# Phase 1: 네이버 지도 - 건물 마커 & 탐색

## 상태

**구현됨** — 핵심 기능 동작 중. 아래 항목들은 검증·개선 대상.

## 목표

네이버 지도 위에 서버에서 받아온 건물들을 마커로 표시하고, 사용자가 건물을 탐색·선택해 실내 내비게이션으로 진입할 수 있도록 한다.

## 기능 목록

### 1-1. 건물 마커 표시
- [ ] `/buildings?status=ACTIVE` API 호출 → `BuildingResponse` 배열 파싱
- [ ] `latitude` / `longitude` 있는 건물만 `NMFMarker`로 지도에 핀 표시
- [ ] 마커 캡션: 건물명
- [ ] 건물들의 평균 좌표로 지도 초기 센터 이동 (zoom 16)

**현재 구현**: `MapViewController.placeMarkers(for:)`, `centerMapOnBuildings(_:)`
**주의**: `BuildingResponse.latitude/longitude`가 서버에서 null로 오면 마커가 아무것도 표시 안 됨 → 백엔드 확인 필요 (memory: project_backend_latlong.md)

---

### 1-2. 건물 검색
- [ ] 상단 검색바 (`UISearchBar`) — 건물명 로컬 필터링
- [ ] 검색 결과 드롭다운 테이블뷰 (최대 높이 240pt)
- [ ] 검색 결과 탭 → 해당 건물 마커로 지도 이동 + InfoCard 표시
- [ ] 취소 버튼으로 검색 해제

**현재 구현**: `MapViewController.updateSearchResults(query:)`, `UISearchBarDelegate`

---

### 1-3. 건물 InfoCard
- [ ] 마커 또는 검색 결과 탭 시 하단에서 카드 슬라이드 업 (spring 애니메이션)
- [ ] 건물명 + 설명 + 층수 표시
- [ ] "목적지 선택" 버튼 → `POISelectionViewController` push
- [ ] 지도 빈 곳 탭 → 카드 슬라이드 다운

**현재 구현**: `MapViewController.showInfoCard(for:)`, `hideInfoCard()`

---

### 1-4. POI 선택
- [ ] `POISelectionViewController` — 건물 내 POI 목록 표시
- [ ] POI 검색 기능 (`/buildings/{id}/pois/search`)
- [ ] POI 선택 → AR 내비게이션 진입

**현재 구현**: `POISelectionViewController.swift`

---

## 완료 기준 (Definition of Done)

1. 서버에서 `latitude/longitude` 있는 건물이 지도 위에 마커로 표시된다.
2. 건물명 검색 후 탭하면 해당 위치로 지도가 이동하고 InfoCard가 나온다.
3. "목적지 선택" 탭 → POI 목록 화면으로 이동한다.
4. POI 선택 → AR 내비게이션 화면으로 이동한다.

## 의존성

- 서버: `/buildings` API에 `latitude`, `longitude` 필드 포함 필요
- Phase 2: POI 선택 후 AR 화면 진입 연결

## 관련 파일

- `IndoorNavigation-iOS/MapViewController.swift`
- `IndoorNavigation-iOS/POISelectionViewController.swift`
- `IndoorNavigation-iOS/NetworkManager.swift` — `fetchBuildings`, `fetchPOIs`, `searchPOIs`
