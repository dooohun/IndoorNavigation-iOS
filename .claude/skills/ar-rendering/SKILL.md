---
name: ar-rendering
description: IndoorNavigation iOS 앱의 ARNavigationLogic.swift, ARNavigationViewController.swift 수정, SceneKit 노드 추가·변경, ARKit 로컬라이제이션 흐름 수정 작업 시 참조하는 전문 스킬. ios-implementer 에이전트가 AR 관련 코드 변경 시 이 스킬을 읽고 패턴을 따른다.
---

# AR 렌더링 가이드

## 구조 이해

```
ARNavigationLogic (로직)
    ↕ delegate
ARNavigationViewController (뷰)
```

- **ARNavigationLogic**: API 호출, ARKit 처리, 경로 계산, SceneKit 노드 생성 모두 여기서
- **ARNavigationViewController**: UI 컴포넌트 셋업, delegate 구현으로 Logic의 상태 업데이트를 받아 표시
- 이 책임 분리를 반드시 유지한다. Logic에 UIKit 코드 넣지 않기, ViewController에 ARKit 처리 넣지 않기

## ARNavigationLogicDelegate

Logic → ViewController 통신 채널. 새 UI 업데이트가 필요하면 delegate 메서드를 추가한다:

```swift
// 1. 프로토콜에 메서드 추가 (ARNavigationLogic.swift 상단)
protocol ARNavigationLogicDelegate: AnyObject {
    // ... 기존 메서드
    func {newMethod}({params})
}

// 2. ARNavigationViewController에서 구현
extension ARNavigationViewController: ARNavigationLogicDelegate {
    func {newMethod}({params}) {
        // 반드시 메인 스레드에서 UI 업데이트
        DispatchQueue.main.async {
            // UI 변경
        }
    }
}
```

## SceneKit 노드 추가 패턴

ARNavigationLogic 내 `renderPath` 또는 관련 함수에서:

```swift
let node = SCNNode()
node.geometry = {geometry}
node.geometry?.firstMaterial?.diffuse.contents = {color}
node.position = SCNVector3(x, y, z)
scene?.rootNode.addChildNode(node)
```

**노드 제거**: 기존 노드를 교체할 때는 먼저 제거한다:
```swift
scene?.rootNode.childNodes
    .filter { $0.name == "{노드이름}" }
    .forEach { $0.removeFromParentNode() }
```

## ARKit 좌표 변환

- AR 공간 좌표(ARKit) ↔ 서버 맵 좌표(NetworkManager LocalizeResponse.Pose) 변환은 `CoordinateTransformer.swift` 사용
- `ARNavigationLogic`에서 `matchedARPose` (simd_float4x4)와 `localizedPose` (Pose)로 기준점 보정

## 타이머 처리 주의사항

ARNavigationLogic은 `captureTimer`, `arrivalCheckTimer`를 사용한다. 새 타이머 추가 시:

```swift
private var {name}Timer: Timer?

// 시작
{name}Timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
    self?.{method}()
}

// 정지 (반드시 정리)
{name}Timer?.invalidate()
{name}Timer = nil
```

`[weak self]` 캡처를 빠뜨리면 retain cycle이 생긴다.

## ARSCNViewDelegate / ARSessionDelegate

`ARNavigationViewController`에서 구현. 새 delegate 메서드 추가 시:

```swift
// ARSCNViewDelegate
func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    // SCNScene 업데이트. 메인 스레드 아님 — UI 업데이트 시 DispatchQueue.main.async 필요
}

// ARSessionDelegate  
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // 매 프레임. 무거운 작업 하지 않기
}
```

## 도착 감지

`ARNavigationLogic.destinationARPosition` (simd_float3)과 현재 카메라 위치를 비교.
임계값: `arrivalThreshold = 2.0` (2m). 로직은 `arrivalCheckTimer` 내에서 처리.
