---
name: ar-rendering
description: IndoorNavigation iOS 앱의 ARNavigationLogic.swift, ARNavigationViewController.swift 수정, SceneKit 노드 추가·변경, ARKit 로컬라이제이션·경로 렌더링·층 전환 흐름 수정 작업 시 참조하는 전문 스킬. ios-implementer 에이전트가 AR 관련 코드 변경 시 이 스킬을 읽고 패턴을 따른다.
---

# AR 렌더링 가이드

## 구조 이해

```
ARNavigationLogic (로직: ARKit · API 호출 · SceneKit 노드 생성 · 경로 진행 추적)
    ↕ delegate (ARNavigationLogicDelegate)
ARNavigationViewController (뷰: 오버레이/HUD/모달 UI)
```

이 책임 분리를 반드시 유지한다:
- Logic 쪽에 UIKit 컴포넌트(레이아웃, 버튼)를 넣지 않는다
- ViewController 쪽에 ARKit/SceneKit 처리(노드 생성, 좌표 계산)를 넣지 않는다
- Logic은 SceneKit `scene` 참조를 weak로 받아 노드를 직접 추가/제거한다

## ARNavigationLogicDelegate (현재 정의)

Logic → ViewController 단방향 통신 채널. 현재 정의된 메서드 전체:

| 메서드 | 호출 시점 |
|-------|---------|
| `updateStatus(_:color:)` | 상태 텍스트 일반 갱신 |
| `setLoading(_:)` | 로딩 인디케이터 |
| `setCaptureProgress(text:isHidden:)` | "N/5" 캡처 카운터 |
| `setScanningOverlay(visible:)` | 스캔 안내 오버레이 |
| `showScanComplete()` | 로컬라이즈 성공 직후 (성공 토스트/애니메이션) |
| `showScanFailed(message:)` | 캡처/로컬라이즈/경로 탐색 실패 |
| `showArrivalNotification()` | 도착 임계 진입 |
| `updateHUD(destinationName:remainingDistance:instruction:)` | 매 0.1초 진행 추적 틱 |
| `setHUDVisible(_:)` | HUD 표시/숨김 |
| `setLocateButtonVisible(_:)` | 재시도 버튼 표시/숨김 |
| `showRouteCalculating(_:)` | 경로 탐색 API 호출 중 표시 |
| `showFloorTransition(transitionType:targetFloor:currentFloor:)` | 층 이동 모달 표시 |
| `hideFloorTransition()` | 층 이동 모달 닫기 |

**새 UI 트리거가 필요하면**: 프로토콜에 메서드 추가 → ViewController extension에서 구현 → Logic에서 호출. 메서드명은 동사로 시작 (`show*`, `update*`, `set*`, `hide*`).

```swift
extension ARNavigationViewController: ARNavigationLogicDelegate {
    func {newMethod}({params}) {
        DispatchQueue.main.async { [weak self] in
            // UI 변경
        }
    }
}
```

Logic 내부에서 delegate를 호출할 때는 이미 메인 스레드인 경우(예: 캡처 타이머 콜백, 네트워크 응답의 `DispatchQueue.main.async` 블록)도 있고, 백그라운드일 수도 있다. 따라서 **ViewController 측에서 `DispatchQueue.main.async`로 한 번 더 감싸는 것이 안전**하다.

## ARNavigationLogic 핵심 흐름

```
startLocalizationFlow()
  → 직전 상태 정리 (노드/타이머/플래그 모두 reset)
  → captureTimer (0.8초 간격) → captureOneFrame() × maxImages (5)
  → stopCapture() → sendToServer()
  → NetworkManager.localize(...) → handleLocalizeSuccess(response:)
      → matchedARPose, localizedPose, localizedFloorId, localizedFloorLevel 캐싱
      → showScanComplete()
      → (정상) startCoordinateRoute(pose:floorId:)
        → NetworkManager.findRouteByCoordinates(...) → adaptRouteResponseToSteps(...)
        → drawPathNodes(steps:)
      → (층 전환 재시작) drawPathNodes(steps: pendingRemainingSteps)

drawPathNodes(steps:)
  → CoordinateTransformer로 서버 좌표 → AR 좌표 변환
  → simplifyPathPoints (collinear sweep + 인접 거리 병합으로 양자화 노이즈 제거)
  → catmullRomSpline (subdivisions = 20) → smoothedPoints
  → placeChevronArrows (회전 구간 + 25m 정규 간격)
  → createDestinationPin (마지막 점)
  → updateSlidingWindow (30m 윈도우 첫 적용)
  → startPathProgressTracking (0.1초 타이머)

tickPathProgress(cameraPos:)
  → waypoint dot-product 전환 체크 (currentTargetWaypointIndex 증가)
  → detectFloorTransition + 거리 1.0m 이내면 triggerFloorTransition
  → 1m 이동마다 updateSlidingWindow
  → updateHUD (남은 거리 + instruction)
```

## SceneKit 노드 구조

```
scene.rootNode
└── pathRootNode               (name: "pathRootNode", renderingOrder: -1)
    ├── ribbonContainer        (name: "ribbonContainer") — 슬라이딩 윈도우마다 동적 재생성
    │   ├── ribbonNode         (연속 흰 띠 geometry)
    │   └── triangle nodes...  (SCNPyramid, 0.6m 간격)
    ├── chevron nodes...       (name: "chevronArrow", renderingOrder: 10)
    └── destinationPin         (name: "pathNode") — 빨간 핀 (구 + 원뿔)
```

`pathRootNode`를 항상 부모로 사용하여 일괄 제거를 가능하게 한다. 새 흐름 시작 시 `pathRootNode?.removeFromParentNode()` 한 줄로 정리.

## 바닥 경로 Ribbon

연속 메시(`SCNGeometry`)로 구현 — 더 이상 SCNBox 세그먼트를 개별 배치하지 않는다.

- **재질**: `UIColor.white.withAlphaComponent(0.55)`, `lightingModel = .constant`, `writesToDepthBuffer = false`, `readsFromDepthBuffer = true`, `isDoubleSided = true`
- **폭**: 0.8m (`stripWidth`), 바닥에서 0.003m 위(`yOffset`)
- **vertex 생성**: 각 point에서 진행 방향 단위 벡터 `t̂` 계산 → 수직 `(-tz, tx)`로 폭의 절반만큼 좌우 vertex 두 개 생성. triangle list indices: `[base, base+2, base+1, base+1, base+2, base+3]`.
- **방향 삼각형**: arc-length 0.6m 간격으로 `SCNPyramid(width: 0.25, height: 0.01, length: 0.35)` 배치. 흰색, `lightingModel = .constant`. y축 회전: `simd_quatf(angle: atan2(dx/segLen, dz/segLen), axis: (0,1,0))`.

`buildRibbonNode(points:)`가 ribbonContainer 노드를 반환한다. 슬라이딩 윈도우 갱신 시 기존 컨테이너 제거 후 새로 추가.

## 더블 쉐브론 화살표

V자(`>`) 두 개를 진행 방향으로 in-line 배치한 형태(`>>`). 모든 팔은 `SCNBox` 기반.

- **위치**: 다음 waypoint 직전 `0.6m`(`edgeOffsetFromNext`), 경로 우측 가장자리 `0.55m`(`edgeLateralOffset`), 바닥에서 `1.0m`(`chevronHeight`) 높이
- **재질**: 파란색 `UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)`, `lightingModel = .constant`, `isDoubleSided = true`
- **회전**:
  - Yaw: `atan2(-dz, dx) * .pi + offset`로 V자 꼭짓점이 진행 방향을 향하도록 (V자 꼭짓점은 모델 local -X에 있음 — 180° 보정 필요)
  - Pitch: 진행 방향에 수직인 수평축(`rHat`) 기준 (기본값 0)
  - 합성: `pitchQ * yawQ` (왼쪽이 후속 적용)
- **bobbing**: `bobNode`에 `SCNAction.repeatForever`로 ±0.08m, 0.8초 ease-in-out
- **배치 규칙**: `placeChevronArrows`에서 (1) 회전 instruction(`"회전"` 포함) 우선 배치, (2) 25m arc-length 정규 간격으로 추가 배치
- **renderingOrder**: 10 (ribbon보다 위)

## 30m 슬라이딩 윈도우

`updateSlidingWindow(cameraPos:)`이 ribbon · 쉐브론 · 핀의 가시성을 일괄 갱신한다.

- 카메라 XZ 위치와 가장 가까운 smooth point가 `startIdx`
- `startIdx`부터 누적 거리 30m(`renderWindowDistance`)까지가 `endIdx`
- **ribbon**: `ribbonContainer` 제거 후 windowPoints로 재생성
- **쉐브론**: `pointIndex < startIdx || pointIndex > endIdx`이면 `isHidden = true`
- **목적지 핀**: 카메라와의 XZ 평면 거리 > 30m면 hidden
- **갱신 빈도**: `windowUpdateMoveDelta = 1.0m` 이동마다 (`tickPathProgress` 내에서 비교)

## 경로 진행 추적 (`tickPathProgress`)

- **타이머**: 0.1초 간격 (`pathProgressTimer`), `[weak self]` 캡처
- **waypoint 전환**: dot-product 기반. `pathDir = (wp+1) - wp`, `toCam = cam - wp`. `simd_dot(pathDir, toCam) > 0`이면 통과로 판정해 인덱스 증가 (while 루프로 한 번에 여러 개 통과 가능)
- **층 전환 감지**: `detectFloorTransition(currentStepIdx:)`이 `(type, targetFloor)?` 반환. 트리거 거리 1.0m(`floorTransitionTriggerDistance`)
- **HUD**: `computeRemainingDistance`로 현재 waypoint까지 + 이후 누적 거리 계산. instruction은 `allSteps[stepIdx].instruction`

## 좌표 변환

서버 좌표(서버 맵 frame) ↔ AR 좌표(ARKit world frame) 변환은 `CoordinateTransformer.swift` 사용:

```swift
let input = CoordinateTransformer.Input(
    serverPosition: serverPos,        // SLAMLocalizeResponse.pose (x,y,z)
    serverQuaternion: quat,           // (qx,qy,qz,qw) — 회전 정렬용
    arCameraPose: arPose              // matchedImageIndex로 선택된 ARFrame transform
)
let arPos = CoordinateTransformer.transform(serverPoint: serverPoint, input: input)
```

**Y(높이) 처리**: 변환 후 Y는 신뢰하지 않고, 카메라 Y - 1.7m로 바닥 레벨을 추정해 모든 경로 점에 동일하게 적용한다 (스마트폰을 들고 있는 평균 높이 기준).

## 양자화 노이즈 제거 + 스플라인 보간

서버 voxel 양자화로 경로 control point가 거칠게 들어올 때:

1. **`simplifyPathPoints`**: collinear sweep (XZ 평면 수직거리 < 0.15m면 중간점 제거) + 인접 거리 병합 (0.30m 미만 점 제거). 시작/끝점은 항상 보존.
2. **`catmullRomSpline(points:subdivisions: 20)`**: 부드러운 곡선 보간. Y는 입력 그대로 유지(바닥 레벨 고정).

새 경로 렌더링 함수가 들어와도 이 두 단계는 거치는 것이 일관된 결과를 보장한다.

## 층 이동 인터렉션

| 단계 | 함수 / 콜백 | 동작 |
|------|------------|------|
| 감지 | `detectFloorTransition(currentStepIdx:)` | floorLevel 변화 OR instruction 키워드(`STAIRS`/`ELEVATOR`/`계단`/`엘리베이터`) 매칭 |
| 트리거 | `triggerFloorTransition(type:targetFloor:currentStepIdx:)` | 타이머 정지, `pathRootNode.isHidden = true`, `pendingRemainingSteps` 캐싱 |
| UI 표시 | delegate `showFloorTransition(transitionType:targetFloor:currentFloor:)` | 모달 |
| 사용자 액션 | `restartFromFloorTransition()` | 노드 정리, `isFloorTransitionRestart = true`, 캡처 재시작 |
| 재 localize | `handleLocalizeSuccess` | `isFloorTransitionRestart`면 `startCoordinateRoute` 생략, `pendingRemainingSteps`로 즉시 `drawPathNodes` |

ARKit 세션은 일시정지하지 않는다 — 노드만 숨김/제거하고 다음 캡처에 재사용.

## 도착 감지

- 별도 타이머 `arrivalCheckTimer` (0.5초 간격), `startArrivalCheck()`에서 시작
- XZ 평면 거리만 비교 (Y 무시), 임계 `arrivalThreshold = 2.0`m
- 진입 시 `hasNotifiedArrival = true`로 중복 방지, 타이머 정지 후 `delegate?.showArrivalNotification()`
- `tickPathProgress`에서도 `currentTargetWaypointIndex >= smoothedPoints.count` 시 도착 처리 (이중 안전망)

## 빨간 3D 핀 (목적지 마커)

`createDestinationPin(at:)`이 `SCNNode` 반환:
- 빨간 구(`SCNSphere`, radius 0.25, PBR 재질) — 핀 머리
- 빨간 원뿔(`SCNCone(topRadius: 0.18, bottomRadius: 0.005, height: 0.45)`) — 꼬리
- 내부 어두운 빨간 구(radius 0.12) — 깊이감
- 모든 재질에 `emission` 설정으로 어두운 환경에서도 시인성 확보
- bobbing: ±0.15m, 0.8초 ease-in-out, repeatForever

## Mock Mode

`ARNavigationLogic.useMockData: Bool = false` static flag로 토글. 서버 미가용 시 UI/렌더링 점검용.

- `startLocalizationFlow()` 진입 시 `useMockData == true`면 `runMockFlow()`로 분기
- 실제 캡처/네트워크 호출을 건너뛰고 mock pose + 합성 steps로 `drawPathNodes` 호출
- 신규 흐름을 추가할 때 mock 분기 갱신을 잊지 않을 것 (재진입 안전성을 위해 잔여 상태 정리 코드는 실제 흐름과 동일해야 함)

## 타이머 처리 주의사항

ARNavigationLogic은 4개 타이머를 사용한다: `captureTimer`, `arrivalCheckTimer`, `pathProgressTimer`, (Mock에서) 별도 합성 타이머. 새 타이머 추가 시:

```swift
private var {name}Timer: Timer?

{name}Timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
    self?.{method}()
}

// 정지 (반드시 짝지어 호출)
{name}Timer?.invalidate()
{name}Timer = nil
```

`[weak self]` 캡처를 빠뜨리면 retain cycle. 새 흐름 진입 시 `startLocalizationFlow()`나 `triggerFloorTransition` 같은 함수에서 **모든 타이머를 명시적으로 invalidate**한 뒤 시작하라 — 재진입 시 중복 발화로 인한 상태 꼬임 방지.

## ARSCNViewDelegate / ARSessionDelegate

`ARNavigationViewController`에서 구현. 새 delegate 메서드 추가 시:

```swift
// ARSCNViewDelegate (SCNScene 업데이트 — 메인 스레드 아님)
func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    // UI 업데이트 시 DispatchQueue.main.async 필요
}

// ARSessionDelegate (매 프레임 — 무거운 작업 금지)
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // 빠르게 처리 가능한 코드만
}
```

매 프레임 처리가 필요하면 가능한 한 Logic 쪽 0.1초 타이머(`pathProgressTimer`)를 활용하고, ARSession delegate는 가벼운 상태 캐싱만 한다.
