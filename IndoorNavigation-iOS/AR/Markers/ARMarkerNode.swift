import Foundation
import simd

// MARK: - Marker 종류
// 사양 §2 / §3 (AR_MARKER_3D.md). distance 의 meters 는 5..50 범위(50+ 는 호출 측에서 50 으로 clamp).
// hidden 은 controller 가 desiredState 계산 결과로 사용 — 외부 발신용으로도 허용.
// passed 는 0.8m 이내 통과 시 일시적으로 사용 — fade-out 트리거 후 controller 가 자체 정리.

enum MarkerKind: Equatable {
    case distance(meters: Int)
    case nextTurn(direction: TurnDirection)
    case hidden
    case passed
}

// MARK: - Marker 데이터 모델 (Logic → ViewController 발신용)
/// Logic 이 매 1Hz tick 마다 ARMarkerController 로 보내는 단일 마커 모델.
/// id 는 worldPosition 기반 stable 키 (예: stepIndex/keyframeId) — 같은 id 의 kind 만 바뀌면 controller 가 크로스페이드.

struct ARMarkerNode {
    let id: String
    let worldPosition: simd_float3
    let kind: MarkerKind
}
