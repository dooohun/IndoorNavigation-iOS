# Phase 2: AR 실내 내비게이션 - 핵심 플로우

## 상태

**부분 구현** — ARKit 세션, 로컬라이즈 호출, SceneKit 경로 렌더링 기본 틀 존재. 아래 항목들 완성 필요.

## 목표

사용자가 스마트폰을 들고 주변을 스캔하면 VPS(Visual Positioning System)로 현재 위치를 파악하고, AR 화면에 목적지까지의 경로를 시각화한다.

**레퍼런스 UI**: Naver Labs 실내 내비게이션 (https://www.youtube.com/watch?v=VQ2PtfHPdKc)

---

## 기능 목록

### 2-1. 주변 스캔 → 로컬라이즈

**흐름**: AR 세션 시작 → 사용자에게 "주변을 천천히 둘러보세요" 안내 → 일정 프레임 수집 후 서버 localize API 호출

- [ ] `ARNavigationViewController` 진입 시 스캔 안내 오버레이 표시
  - 텍스트: "주변을 천천히 둘러보세요"
  - 진행 표시: 원형 프로그레스 or 애니메이션 (캡처 진행 상태)
- [ ] `ARNavigationLogic.startLocalization()` — ARFrame 캡처 (최소 3장, 최대 10장)
- [ ] 수집된 이미지 → `NetworkManager.localize(buildingId:images:)` 호출
- [ ] 성공: `LocalizeResponse` (pose x/y/z + 쿼터니언) 수신 → 2-2로 진행
- [ ] 실패: 재시도 안내 ("인식에 실패했습니다. 다시 시도해주세요")

**API**: `POST /buildings/{buildingId}/localize` — multipart/form-data, images 배열

**현재 구현**: `ARNavigationLogic.startLocalization()`, `ARNavigationViewController` 기본 구조

---

### 2-2. 경로 요청 → 경로 데이터 파싱

- [ ] 로컬라이즈 성공 후 즉시 `NetworkManager.findPath(buildingId:requestDto:)` 호출
  - `startFloorLevel`: 현재 층
  - `startX/Y/Z`: 로컬라이즈 pose 좌표
  - `destinationName`: 선택한 POI 이름
  - `preference`: `"SHORTEST"` (기본값)
- [ ] `PathfindingResponse` → `steps: [PathStep]` 배열 파싱
- [ ] 각 `PathStep`의 `position(x,y,z)` + `floorLevel` + `instruction` 추출

**API**: `POST /buildings/{buildingId}/pathfinding`

---

### 2-3. 경로 AR 렌더링 (Naver Labs 스타일)

**목표**: 사용자가 직관적으로 경로를 따라갈 수 있도록 바닥 도로 + 공중 화살표를 조합한 시각화.

#### A. 바닥 경로 띠 (Ground Path Strip)

- [ ] **재질**: 흰색 반투명 (`SCNMaterial`, `diffuse.contents = UIColor.white.withAlphaComponent(0.55)`, `isDoubleSided = true`)
  - `lightingModel = .constant` — 조명 영향 없이 항상 동일한 밝기 유지
  - `writesToDepthBuffer = false` — 실제 바닥 위에 자연스럽게 겹침
- [ ] **형태**: 연속된 `SCNBox` 세그먼트를 waypoint 간 연결. 폭 0.8m, 높이 0.005m (바닥에 붙어있는 느낌)
  - 각 세그먼트: 두 waypoint 사이의 중점에 위치, 두 점 사이 각도로 회전
- [ ] **방향 삼각형 패턴**: 띠 위에 일정 간격(0.6m)으로 작은 삼각형 노드 배치
  - 재질: 흰색, `diffuse.contents = UIColor.white` (띠보다 선명하게)
  - 형태: `SCNPyramid` or 커스텀 `SCNGeometry` (얇고 납작한 삼각형, 높이 0.01m)
  - 크기: 밑변 0.25m, 깊이 0.35m
  - 방향: 각 삼각형이 다음 waypoint 방향을 가리키도록 y축 회전
  - 높이: 바닥에서 0.005m 위 (띠 표면 위에 살짝 뜬 형태)

#### B. 공중 3D 방향 화살표 (Floating Arrow)

- [ ] **위치**: 바닥 경로 띠의 **가장자리 끝** (중앙이 아닌 경계선 위)에서 바닥으로부터 **0.8m 위**
  - x 오프셋: 경로 진행 방향의 왼쪽 or 오른쪽 가장자리 (`±0.4m`)
  - 한쪽 가장자리에 고정 (좌측 또는 우측, 벽이 없는 쪽 우선)
- [ ] **형태**: 파란색 3D 화살표
  - `SCNBox` (몸통) + `SCNPyramid` (화살 머리) 조합
  - 색상: `UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)` (선명한 파란색)
  - 몸통 크기: 0.1m × 0.4m × 0.1m
  - 화살 머리: 밑변 0.22m, 높이 0.2m
  - `lightingModel = .constant`
- [ ] **방향**: 항상 다음 waypoint를 향하도록 y축 회전 (카메라 위치에 따라 프레임마다 업데이트)
- [ ] **애니메이션**: 위아래로 천천히 부유 (0.0~0.12m, 주기 1.5초, `SCNAction.repeatForever`)

#### C. 점진적 렌더링 (Progressive Rendering, 30m 윈도우)

- [ ] **렌더링 범위**: 현재 사용자 위치로부터 **전방 30m** 이내의 waypoint만 렌더링
  - 전체 경로 steps를 한 번에 SceneKit에 올리지 않음
  - `activeSteps`: 현재 위치 기준 30m 이내 steps만 포함하는 슬라이딩 윈도우
- [ ] **윈도우 업데이트**: 사용자가 이동하면서 30m 범위를 벗어난 뒤쪽 세그먼트는 `node.removeFromParentNode()` 제거, 새로 30m 안에 들어오는 앞쪽 세그먼트를 추가
  - 업데이트 빈도: 매 1.0m 이동마다 재계산 (ARKit camera position delta 기준)
- [ ] **페이드 효과**: 새 세그먼트 추가 시 `SCNAction` opacity 0 → 1 (0.4초 fade-in)
  - 뒤쪽 세그먼트 제거 시 1 → 0 fade-out 후 remove
- [ ] **거리 계산**: `simd_distance(cameraWorldPos, stepWorldPos)` 로 각 step까지의 유클리디언 거리

#### D. 경로 진행 추적

- [ ] ARKit 카메라 위치 기준으로 현재 목표 waypoint까지의 거리 계산 (매 ARFrame)
- [ ] 거리 0.8m 이하 진입 시 다음 waypoint로 전환
  - 이전 waypoint의 바닥 띠·삼각형 노드는 즉시 제거 (fade-out 없이)
  - 공중 화살표는 새 방향으로 즉시 회전
- [ ] `floorLevel` 변화 감지 → Phase 3 층 이동 인터렉션 트리거

---

### 2-4. HUD 오버레이 UI

- [ ] **목적지 이름**: 화면 상단 중앙, 흰색 텍스트 + 반투명 다크 배경 pill
  - 예: "304호"
- [ ] **남은 거리**: 목적지 이름 아래, 큰 폰트 (28pt bold)
  - 예: "약 47m"
  - 사용자 이동에 따라 실시간 업데이트 (매 waypoint 전환마다 재계산)
- [ ] **현재 안내**: 화면 하단 중앙 카드
  - 예: "직진하세요", "우회전하세요" — `PathStep.instruction` 텍스트
  - 배경: 흰색 pill, 그림자, 둥근 모서리

---

## 완료 기준 (Definition of Done)

1. AR 화면 진입 → 스캔 안내 UI가 표시된다.
2. 스캔 후 서버 로컬라이즈 성공 → "경로를 계산 중입니다" 로딩 → 바닥 경로 띠 + 공중 화살표가 AR 공간에 렌더링된다.
3. 바닥 띠가 0.8m 폭의 흰색 반투명으로 표시되고, 그 위에 방향 삼각형들이 일정 간격으로 표시된다.
4. 파란 3D 화살표가 경로 가장자리에서 0.8m 위에 떠서 진행 방향을 가리키며 부유 애니메이션이 적용된다.
5. 전방 30m 이내 구간만 렌더링되고, 사용자 이동 시 페이드 인/아웃으로 구간이 갱신된다.
6. 화면 HUD에 목적지명, 남은 거리, 현재 안내 텍스트가 표시된다.
7. 로컬라이즈 실패 시 재시도 UI가 표시된다.

## 의존성

- Phase 1: `buildingId`, `destinationName` (POI 이름) 전달받아 진입
- Phase 3: `PathStep.floorLevel` 변화 감지 → 층 이동 인터렉션 트리거

## 관련 파일

- `IndoorNavigation-iOS/ARNavigationViewController.swift`
- `IndoorNavigation-iOS/ARNavigationLogic.swift`
- `IndoorNavigation-iOS/CoordinateTransformer.swift`
- `IndoorNavigation-iOS/NetworkManager.swift` — `localize`, `findPath`

## SceneKit 노드 구조 (참고)

```
rootNode
└── pathRootNode              ← 전체 경로 노드의 부모 (제거 편의)
    ├── segmentNode_0         ← 두 waypoint 간 바닥 띠 세그먼트
    │   ├── stripNode         ← SCNBox (흰색 반투명, 0.8m × 0.005m)
    │   └── arrowNode_0..N    ← SCNPyramid (방향 삼각형, 0.6m 간격)
    ├── segmentNode_1
    │   └── ...
    └── floatingArrowNode     ← 공중 3D 화살표 (단 하나, 항상 최전방 waypoint 기준)
```
