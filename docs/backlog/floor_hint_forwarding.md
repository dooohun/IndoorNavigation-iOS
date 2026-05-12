# Floor hint forwarding to V3 localize

## 배경

네이버 지도 → 목적지 선택 사이에 "현재 본인이 있는 층" 선택 단계를 추가하기로 결정 (2026-05-12).

- 사용자가 본인 층을 명시하면 서버가 해당 floor 의 keyframe 만 매칭 후보로 좁혀 측위 속도/정확도 향상 기대
- 다른 floor 오인식으로 인한 측위 실패 케이스 감소

## 확정된 설계

1. **"모르겠음" 옵션 포함** — 외부 방문자가 본인 층을 모르는 경우 대응. 미지정 시 기존 동작(전 floor keyframe 매칭) 유지.
2. **Floor list 데이터 소스**: `GET /api/v1/buildings/{buildingId}` 응답의 `floors` 배열.
   - 사용 필드: `floorId`, `level`, `name`, `hasPath`
   - 응답 예시: `floors[]` 의 `level` 로 사용자 노출용 라벨(1F, 2F, B1 등) 표시, 선택 시 `floorId` 보유.

## 미정 (추후 논의)

3. **Floor hint 를 V3 localize 에 어떻게 전달할지**.
   - 후보 1: `POST /api/slam/v3/localize` 요청 body 에 옵션 필드 `floorId` 또는 `floorLevel` 추가
   - 후보 2: 별도 query param `?floorHint=`
   - 후보 3: 클라이언트 측에서 keyframe candidate 필터만 적용 (서버 변경 X)
   - **결정 필요**: 백엔드 API 스펙 확정 후 클라이언트 적용. 현재 측위 정책: V3 only.

## 영향 범위 (구현 시점)

- 신규 ViewController: FloorSelectionViewController (네이버 지도 다음 step)
- NetworkManager: `GET /api/v1/buildings/{buildingId}` 호출 추가
- DTO: BuildingResponse, FloorResponse 정의
- ARNavigationViewController 진입 시점에 선택된 floorId (nullable) 전달
- V3 localize 호출 시점에 hint 적용 (위 후보 3 중 결정 후)

## 상태

- **2026-05-12**: 백로그 등록. UI/flow 구현은 별도 phase 로 처리 예정. floor hint forwarding 메커니즘은 백엔드 협의 후 후속.
